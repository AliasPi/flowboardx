package de.flowboardx.flowboard_x

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Offline handwriting adapter backed by ML Kit's *bundled* Latin recognizer.
 *
 * Flowboard keeps ink as vectors. For recognition only, this service renders a
 * tightly cropped, high-contrast bitmap off the Android main thread and feeds
 * it to the model packaged in the APK via `com.google.mlkit:text-recognition`.
 * No Play Services model installation and no runtime download are involved.
 */
internal class AndroidHandwritingRecognitionService(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val rasterExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "flowboard-handwriting-raster").apply { isDaemon = true }
    }
    private val recognizer: TextRecognizer? = runCatching {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }.onFailure { error ->
        Log.e(TAG, "Bundled handwriting recognizer could not be created", error)
    }.getOrNull()

    @Volatile
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        rasterExecutor.shutdownNow()
        runCatching { recognizer?.close() }
            .onFailure { Log.w(TAG, "Could not close handwriting recognizer", it) }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("service_closed", "Die Handschrifterkennung wurde beendet.", null)
            return
        }
        when (call.method) {
            "ensureModel", "isAvailable" -> {
                val languageTag = (call.arguments as? Map<*, *>)
                    ?.get("languageTag") as? String ?: DEFAULT_LANGUAGE_TAG
                result.success(recognizer != null && isSupportedLanguageTag(languageTag))
            }
            "recognize" -> recognize(call.arguments, result)
            else -> result.notImplemented()
        }
    }

    private fun recognize(arguments: Any?, result: MethodChannel.Result) {
        val localRecognizer = recognizer
        if (localRecognizer == null) {
            result.error(
                "recognizer_start_failed",
                "Die eingebettete Handschrifterkennung konnte nicht gestartet werden.",
                null,
            )
            return
        }
        try {
            rasterExecutor.execute {
                val bitmap = try {
                    renderInk(parseRequest(arguments))
                } catch (error: ChannelException) {
                    postError(result, error.code, error.message)
                    return@execute
                } catch (error: Throwable) {
                    Log.e(TAG, "Could not prepare handwriting input", error)
                    postError(result, "invalid_ink", "Die Handschriftdaten sind ungültig.")
                    return@execute
                }
                if (disposed) {
                    bitmap.recycle()
                    return@execute
                }
                try {
                    localRecognizer.process(InputImage.fromBitmap(bitmap, 0))
                        .addOnSuccessListener { recognition ->
                            bitmap.recycle()
                            if (disposed) return@addOnSuccessListener
                            val text = recognition.text.trim()
                            if (text.isEmpty()) {
                                postError(
                                    result,
                                    "no_candidate",
                                    "Die Handschrift wurde nicht erkannt.",
                                )
                            } else {
                                postSuccess(result, mapOf("text" to text))
                            }
                        }
                        .addOnFailureListener { error ->
                            bitmap.recycle()
                            Log.w(TAG, "Offline handwriting recognition failed", error)
                            postError(
                                result,
                                "recognition_failed",
                                "Die Handschrift konnte nicht erkannt werden.",
                            )
                        }
                } catch (error: Throwable) {
                    bitmap.recycle()
                    Log.e(TAG, "Could not submit handwriting recognition", error)
                    postError(
                        result,
                        "recognition_failed",
                        "Die Handschrift konnte nicht erkannt werden.",
                    )
                }
            }
        } catch (error: Throwable) {
            Log.e(TAG, "Handwriting worker is unavailable", error)
            result.error(
                "service_closed",
                "Die Handschrifterkennung wurde beendet.",
                null,
            )
        }
    }

    private fun parseRequest(arguments: Any?): RecognitionRequest {
        val request = arguments as? Map<*, *>
            ?: throw ChannelException("invalid_ink", "Handschriftdaten fehlen.")
        val languageTag = request["languageTag"] as? String ?: DEFAULT_LANGUAGE_TAG
        if (!isSupportedLanguageTag(languageTag)) {
            throw ChannelException(
                "invalid_language",
                "Die eingebettete Erkennung unterstützt lateinische Schrift.",
            )
        }
        val rawStrokes = request["strokes"] as? List<*>
            ?: throw ChannelException("invalid_ink", "Keine Striche übergeben.")
        if (rawStrokes.isEmpty() || rawStrokes.size > MAX_STROKES) {
            throw ChannelException("invalid_ink", "Ungültige Anzahl von Strichen.")
        }

        var totalPoints = 0
        val strokes = ArrayList<List<InkPoint>>(rawStrokes.size)
        rawStrokes.forEach { rawStroke ->
            val stroke = rawStroke as? Map<*, *>
                ?: throw ChannelException("invalid_ink", "Ein Strich ist ungültig.")
            val rawPoints = stroke["points"] as? List<*>
                ?: throw ChannelException("invalid_ink", "Strichpunkte fehlen.")
            if (rawPoints.isEmpty()) return@forEach
            if (totalPoints + rawPoints.size > MAX_POINTS) {
                throw ChannelException("invalid_ink", "Zu viele Handschriftpunkte.")
            }
            val points = rawPoints.map { rawPoint ->
                val point = rawPoint as? Map<*, *>
                    ?: throw ChannelException(
                        "invalid_ink",
                        "Ein Handschriftpunkt ist ungültig.",
                    )
                InkPoint(
                    x = finiteCoordinate(point["x"], "x"),
                    y = finiteCoordinate(point["y"], "y"),
                )
            }
            strokes += points
            totalPoints += points.size
        }
        if (strokes.isEmpty() || totalPoints == 0) {
            throw ChannelException("invalid_ink", "Keine Handschriftpunkte vorhanden.")
        }
        return RecognitionRequest(strokes)
    }

    private fun renderInk(request: RecognitionRequest): Bitmap {
        var left = Float.POSITIVE_INFINITY
        var top = Float.POSITIVE_INFINITY
        var right = Float.NEGATIVE_INFINITY
        var bottom = Float.NEGATIVE_INFINITY
        request.strokes.forEach { stroke ->
            stroke.forEach { point ->
                left = min(left, point.x)
                top = min(top, point.y)
                right = max(right, point.x)
                bottom = max(bottom, point.y)
            }
        }
        val inkWidth = max(right - left, 1f)
        val inkHeight = max(bottom - top, 1f)
        var scale = TARGET_INK_HEIGHT / inkHeight
        scale = min(scale, MAX_INK_WIDTH / inkWidth)
        scale = min(scale, MAX_INK_HEIGHT / inkHeight)
        scale = scale.coerceIn(MIN_SCALE, MAX_SCALE)

        val width = ceil(inkWidth * scale + PADDING * 2).toInt()
            .coerceIn(MIN_BITMAP_SIZE, MAX_BITMAP_SIZE)
        val height = ceil(inkHeight * scale + PADDING * 2).toInt()
            .coerceIn(MIN_BITMAP_SIZE, MAX_BITMAP_SIZE)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            strokeWidth = RASTER_STROKE_WIDTH
        }
        request.strokes.forEach { stroke ->
            val first = stroke.first()
            val startX = (first.x - left) * scale + PADDING
            val startY = (first.y - top) * scale + PADDING
            if (stroke.size == 1) {
                canvas.drawCircle(startX, startY, RASTER_STROKE_WIDTH / 2f, paint)
                return@forEach
            }
            val path = Path().apply { moveTo(startX, startY) }
            for (index in 1 until stroke.size) {
                val point = stroke[index]
                path.lineTo(
                    (point.x - left) * scale + PADDING,
                    (point.y - top) * scale + PADDING,
                )
            }
            canvas.drawPath(path, paint)
        }
        return bitmap
    }

    private fun isSupportedLanguageTag(rawTag: String): Boolean {
        val tag = rawTag.trim()
        if (tag.isEmpty() || tag.length > MAX_LANGUAGE_TAG_LENGTH) return false
        return LANGUAGE_TAG.matches(tag)
    }

    private fun finiteCoordinate(value: Any?, axis: String): Float {
        val coordinate = (value as? Number)?.toDouble()
            ?: throw ChannelException("invalid_ink", "Koordinate $axis fehlt.")
        if (!coordinate.isFinite() || abs(coordinate) > MAX_ABSOLUTE_COORDINATE) {
            throw ChannelException("invalid_ink", "Koordinate $axis ist ungültig.")
        }
        return coordinate.toFloat()
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any) {
        mainHandler.post { if (!disposed) result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { if (!disposed) result.error(code, message, null) }
    }

    private data class InkPoint(val x: Float, val y: Float)
    private data class RecognitionRequest(val strokes: List<List<InkPoint>>)

    private class ChannelException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/handwriting_recognition"
        const val DEFAULT_LANGUAGE_TAG = "de-DE"
        const val TAG = "FlowboardHandwriting"
        const val MAX_LANGUAGE_TAG_LENGTH = 64
        const val MAX_STROKES = 4_096
        const val MAX_POINTS = 250_000
        const val MAX_ABSOLUTE_COORDINATE = 10_000_000.0
        const val TARGET_INK_HEIGHT = 320f
        const val MAX_INK_WIDTH = 1_900f
        const val MAX_INK_HEIGHT = 1_000f
        const val PADDING = 48f
        const val RASTER_STROKE_WIDTH = 7f
        const val MIN_SCALE = 0.05f
        const val MAX_SCALE = 64f
        const val MIN_BITMAP_SIZE = 128
        const val MAX_BITMAP_SIZE = 2_048
        val LANGUAGE_TAG = Regex("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
    }
}
