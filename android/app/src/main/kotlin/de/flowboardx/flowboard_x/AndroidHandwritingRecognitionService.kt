package de.flowboardx.flowboard_x

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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
    private val activeNativeTasks = AtomicInteger(0)
    private val requestInFlight = AtomicBoolean(false)
    private val recognizerClosed = AtomicBoolean(false)
    private val recognizer: TextRecognizer? = runCatching {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }.onFailure { error ->
        Log.e(TAG, "Bundled handwriting recognizer could not be created", error)
    }.getOrNull()

    @Volatile
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
        // Force the bundled model through one tiny inference while the user is
        // still opening the document. Integrated classroom boards often have
        // slower storage than tablets; warming on our private worker prevents
        // the first real conversion from spending most of its deadline loading
        // model pages. A real request is queued behind this task and therefore
        // never races the warm-up.
        recognizer?.let { localRecognizer ->
            runCatching {
                rasterExecutor.execute { warmBundledRecognizer(localRecognizer) }
            }.onFailure { error ->
                Log.w(TAG, "Bundled handwriting recognizer could not be warmed", error)
            }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        rasterExecutor.shutdownNow()
        closeRecognizerWhenIdle()
    }

    private fun warmBundledRecognizer(recognizer: TextRecognizer) {
        if (disposed || Thread.currentThread().isInterrupted) return
        val bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        canvas.drawLine(
            24f,
            45f,
            72f,
            18f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.BLACK
                style = Paint.Style.STROKE
                strokeCap = Paint.Cap.ROUND
                strokeWidth = 4f
            },
        )
        val released = AtomicBoolean(false)
        val releaseBitmap = {
            if (released.compareAndSet(false, true)) {
                bitmap.recycle()
                releaseNativeTask()
            }
        }
        var completionOwnsBitmap = false
        try {
            activeNativeTasks.incrementAndGet()
            val task = recognizer.process(InputImage.fromBitmap(bitmap, 0))
            task.addOnCompleteListener(DIRECT_EXECUTOR) { releaseBitmap() }
            completionOwnsBitmap = true
            Tasks.await(task, MODEL_WARMUP_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        } catch (error: Throwable) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            Log.w(TAG, "Bundled handwriting warm-up did not complete", error)
        } finally {
            // ML Kit may continue after our wait budget. Once a completion
            // listener is registered it is the sole bitmap owner.
            if (!completionOwnsBitmap) releaseBitmap()
        }
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
        if (!requestInFlight.compareAndSet(false, true)) {
            result.success(
                mapOf(
                    "status" to "notRecognized",
                    "message" to
                        "Eine Handschrifterkennung läuft bereits. " +
                        "Bitte gleich erneut versuchen.",
                    "engine" to ENGINE_NAME,
                    "modelDelivery" to MODEL_DELIVERY,
                    "attempts" to 0,
                ),
            )
            return
        }
        try {
            rasterExecutor.execute {
                try {
                    val request = try {
                        parseRequest(arguments)
                    } catch (error: ChannelException) {
                        postError(result, error.code, error.message)
                        return@execute
                    } catch (error: Throwable) {
                        Log.e(TAG, "Could not prepare handwriting input", error)
                        postError(
                            result,
                            "invalid_ink",
                            "Die Handschriftdaten sind ungültig.",
                        )
                        return@execute
                    }
                    // A timed-out warm-up/recognition may still own its native
                    // bitmap. Never overlap another large inference with it.
                    if (activeNativeTasks.get() > 0) {
                        postSuccess(
                            result,
                            mapOf(
                                "status" to "notRecognized",
                                "message" to
                                    "Die vorherige Handschrifterkennung wird noch abgeschlossen. " +
                                    "Bitte gleich erneut versuchen.",
                                "engine" to ENGINE_NAME,
                                "modelDelivery" to MODEL_DELIVERY,
                                "attempts" to 0,
                            ),
                        )
                        return@execute
                    }
                    try {
                        val outcome = recognizeWithOfflineFallbacks(localRecognizer, request)
                        if (disposed) return@execute
                        if (outcome.candidate == null) {
                            postSuccess(
                                result,
                                mapOf(
                                    "status" to "notRecognized",
                                    "message" to
                                        "Die Handschrift wurde nicht sicher erkannt. " +
                                        "Bitte ein vollständiges Wort oder eine Zeile markieren.",
                                    "engine" to ENGINE_NAME,
                                    "modelDelivery" to MODEL_DELIVERY,
                                    "attempts" to outcome.attemptCount,
                                ),
                            )
                        } else {
                            postSuccess(
                                result,
                                mapOf(
                                    "status" to "recognized",
                                    "text" to outcome.candidate.text,
                                    "confidence" to outcome.candidate.confidence,
                                    "engine" to ENGINE_NAME,
                                    "modelDelivery" to MODEL_DELIVERY,
                                    "attempts" to outcome.attemptCount,
                                ),
                            )
                        }
                    } catch (error: Throwable) {
                        Log.e(TAG, "Offline handwriting recognition failed", error)
                        postError(
                            result,
                            "recognition_failed",
                            "Die lokale Handschrifterkennung ist fehlgeschlagen.",
                        )
                    }
                } finally {
                    requestInFlight.set(false)
                }
            }
        } catch (error: Throwable) {
            requestInFlight.set(false)
            Log.e(TAG, "Handwriting worker is unavailable", error)
            result.error(
                "service_closed",
                "Die Handschrifterkennung wurde beendet.",
                null,
            )
        }
    }

    /**
     * Printed-text OCR is less tolerant of raw pen geometry than Windows Ink.
     * Use several small, handwriting-sized rasterizations before declaring a
     * valid request unrecognized. All attempts use the Latin model linked into
     * the APK; this method never downloads or installs a model.
     */
    private fun recognizeWithOfflineFallbacks(
        recognizer: TextRecognizer,
        request: RecognitionRequest,
    ): RecognitionOutcome {
        val deadlineNanos = System.nanoTime() +
            TimeUnit.SECONDS.toNanos(RECOGNITION_TIMEOUT_SECONDS)
        var attempts = 0
        var completedAttempt = false
        var timedOut = false
        var lastFailure: Exception? = null
        val candidates = ArrayList<OcrCandidate>(RENDER_STYLES.size + 1)
        val lines = splitIntoLines(request.strokes)
        val lineCountHint = lines.size.coerceIn(1, MAX_LINE_FALLBACKS)
        for (style in RENDER_STYLES) {
            if (disposed || Thread.currentThread().isInterrupted) break
            attempts++
            val bitmap = renderInk(request, style, lineCountHint)
            try {
                val candidate = recognizeBitmap(recognizer, bitmap, deadlineNanos)
                completedAttempt = true
                if (candidate != null) candidates += candidate
            } catch (error: TimeoutException) {
                lastFailure = error
                timedOut = true
                Log.w(TAG, "Handwriting recognition reached its global deadline", error)
                break
            } catch (error: Exception) {
                if (error is InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw error
                }
                lastFailure = error
                Log.w(TAG, "Handwriting raster attempt $attempts failed", error)
            }
        }

        // A multi-line selection can still be ambiguous after normalization.
        // Retry spatially separated lines when the page pass missed one or
        // more expected lines. Preserve top-to-bottom order and never replace
        // all selected ink with only a partial transcription.
        val bestPageCandidate = chooseBestCandidate(
            candidates,
            expectedLineCount = lines.size,
        )
        val pageResultLooksIncomplete =
            bestPageCandidate == null ||
                bestPageCandidate.text.lines().size != lines.size ||
                bestPageCandidate.confidence == null ||
                bestPageCandidate.confidence < LINE_FALLBACK_CONFIDENCE
        if (!timedOut &&
            lines.size in 2..MAX_LINE_FALLBACKS &&
            pageResultLooksIncomplete &&
            !disposed &&
            !Thread.currentThread().isInterrupted
        ) {
            val recognizedLines = ArrayList<OcrCandidate>(lines.size)
            var completeLineResult = true
            for (line in lines) {
                attempts++
                val bitmap = renderInk(
                    RecognitionRequest(line),
                    LINE_RENDER_STYLE,
                    1,
                )
                try {
                    val candidate = recognizeBitmap(recognizer, bitmap, deadlineNanos)
                    completedAttempt = true
                    if (candidate == null) {
                        completeLineResult = false
                        break
                    }
                    recognizedLines += candidate
                } catch (error: TimeoutException) {
                    lastFailure = error
                    timedOut = true
                    completeLineResult = false
                    Log.w(TAG, "Handwriting line fallback reached its deadline", error)
                    break
                } catch (error: Exception) {
                    if (error is InterruptedException) {
                        Thread.currentThread().interrupt()
                        throw error
                    }
                    lastFailure = error
                    completeLineResult = false
                    Log.w(TAG, "Handwriting line attempt $attempts failed", error)
                    break
                }
            }
            // Never replace all selected ink with a partial transcription.
            if (completeLineResult && recognizedLines.size == lines.size) {
                candidates += combineLineCandidates(recognizedLines)
            }
        }

        // Printed-text OCR occasionally merges neighbouring handwritten words
        // on large panels because the natural space is small relative to a
        // long, thin line bitmap. Geometry still contains that information.
        // Retry clearly separated word groups and reassemble their spacing.
        // Cursive/single-stroke words stay intact and therefore continue to use
        // the whole-line profiles above.
        val wordsByLine = lines.map(::splitIntoWords)
        val expectedWordCount = wordsByLine.sumOf { it.size }
        val currentBest = chooseBestCandidate(
            candidates,
            expectedLineCount = lines.size,
        )
        val currentWordCount = currentBest?.text
            ?.split(WHITESPACE)
            ?.count { it.isNotBlank() } ?: 0
        val wordFallbackNeeded =
            expectedWordCount in 2..MAX_WORD_FALLBACKS &&
                (currentBest == null ||
                    currentWordCount != expectedWordCount ||
                    currentBest.confidence == null ||
                    currentBest.confidence < WORD_FALLBACK_CONFIDENCE)
        if (!timedOut &&
            wordFallbackNeeded &&
            !disposed &&
            !Thread.currentThread().isInterrupted
        ) {
            val recognizedLines = ArrayList<OcrCandidate>(wordsByLine.size)
            var completeWordResult = true
            wordLoop@ for (words in wordsByLine) {
                val recognizedWords = ArrayList<OcrCandidate>(words.size)
                for (word in words) {
                    attempts++
                    val bitmap = renderInk(
                        RecognitionRequest(word),
                        WORD_RENDER_STYLE,
                        1,
                    )
                    try {
                        val candidate = recognizeBitmap(recognizer, bitmap, deadlineNanos)
                        completedAttempt = true
                        if (candidate == null) {
                            completeWordResult = false
                            break@wordLoop
                        }
                        recognizedWords += candidate.copy(
                            text = candidate.text.replace(WHITESPACE, " ").trim(),
                        )
                    } catch (error: TimeoutException) {
                        lastFailure = error
                        timedOut = true
                        completeWordResult = false
                        Log.w(TAG, "Handwriting word fallback reached its deadline", error)
                        break@wordLoop
                    } catch (error: Exception) {
                        if (error is InterruptedException) {
                            Thread.currentThread().interrupt()
                            throw error
                        }
                        lastFailure = error
                        completeWordResult = false
                        Log.w(TAG, "Handwriting word attempt $attempts failed", error)
                        break@wordLoop
                    }
                }
                if (recognizedWords.size == words.size) {
                    recognizedLines += combineWordCandidates(recognizedWords)
                }
            }
            if (completeWordResult && recognizedLines.size == wordsByLine.size) {
                candidates += combineLineCandidates(recognizedLines)
            }
        }
        val candidate = chooseBestCandidate(
            candidates,
            expectedLineCount = lines.size,
            expectedWordCount = expectedWordCount,
        )
        if (candidate != null) return RecognitionOutcome(candidate, attempts)
        // A deadline on a slow first invocation is an ordinary absence of a
        // candidate, not malformed handwriting. Only propagate a real engine
        // error when not one native attempt completed successfully.
        if (!completedAttempt && lastFailure != null && lastFailure !is TimeoutException) {
            throw lastFailure
        }
        return RecognitionOutcome(null, attempts)
    }

    /**
     * Runs one ML Kit request within the shared recognition deadline.
     *
     * `InputImage.fromBitmap` may retain the bitmap until its asynchronous task
     * completes. The completion listener is therefore the sole owner that can
     * recycle it. In particular, a caller timeout does not release the bitmap
     * while native OCR may still be reading it.
     */
    private fun recognizeBitmap(
        recognizer: TextRecognizer,
        bitmap: Bitmap,
        deadlineNanos: Long,
    ): OcrCandidate? {
        val remainingNanos = deadlineNanos - System.nanoTime()
        if (remainingNanos <= 0L) {
            bitmap.recycle()
            throw TimeoutException("Handwriting recognition deadline elapsed")
        }

        val released = AtomicBoolean(false)
        val releaseBitmap = {
            if (released.compareAndSet(false, true)) {
                bitmap.recycle()
                releaseNativeTask()
            }
        }
        activeNativeTasks.incrementAndGet()
        val task = try {
            recognizer.process(InputImage.fromBitmap(bitmap, 0))
        } catch (error: Throwable) {
            releaseBitmap()
            throw error
        }
        task.addOnCompleteListener(DIRECT_EXECUTOR) { releaseBitmap() }
        return try {
            val recognition = Tasks.await(task, remainingNanos, TimeUnit.NANOSECONDS)
            candidateFromRecognition(recognition)
        } finally {
            // Normally the direct listener has already run before await
            // returns. This idempotent fallback closes any scheduling race.
            if (task.isComplete) releaseBitmap()
        }
    }

    private fun releaseNativeTask() {
        val remaining = activeNativeTasks.decrementAndGet()
        if (remaining < 0) {
            activeNativeTasks.set(0)
            Log.e(TAG, "Native handwriting task accounting became negative")
        }
        if (disposed) closeRecognizerWhenIdle()
    }

    private fun closeRecognizerWhenIdle() {
        if (activeNativeTasks.get() != 0 ||
            !recognizerClosed.compareAndSet(false, true)
        ) return
        runCatching { recognizer?.close() }
            .onFailure { Log.w(TAG, "Could not close handwriting recognizer", it) }
    }

    private fun candidateFromRecognition(recognition: Text): OcrCandidate? {
        val text = normalizeRecognizedText(recognition.text)
        if (text.isEmpty()) return null
        var confidenceWeight = 0
        var confidenceTotal = 0.0
        recognition.textBlocks.forEach { block ->
            block.lines.forEach { line ->
                val confidence = line.confidence
                if (confidence.isFinite() && confidence in 0f..1f) {
                    val weight = max(1, line.text.count { !it.isWhitespace() })
                    confidenceWeight += weight
                    confidenceTotal += confidence * weight
                }
            }
        }
        val confidence = if (confidenceWeight == 0) {
            null
        } else {
            (confidenceTotal / confidenceWeight).coerceIn(0.0, 1.0)
        }
        return OcrCandidate(
            text = text,
            confidence = confidence,
            quality = candidateTextQuality(text),
        )
    }

    private fun combineLineCandidates(lines: List<OcrCandidate>): OcrCandidate {
        var confidenceWeight = 0
        var confidenceTotal = 0.0
        lines.forEach { line ->
            line.confidence?.let { confidence ->
                val weight = max(1, line.text.count { !it.isWhitespace() })
                confidenceWeight += weight
                confidenceTotal += confidence * weight
            }
        }
        val text = lines.joinToString("\n") { it.text }
        return OcrCandidate(
            text = text,
            confidence = if (confidenceWeight == 0) {
                null
            } else {
                (confidenceTotal / confidenceWeight).coerceIn(0.0, 1.0)
            },
            quality = candidateTextQuality(text),
        )
    }

    private fun combineWordCandidates(words: List<OcrCandidate>): OcrCandidate {
        var confidenceWeight = 0
        var confidenceTotal = 0.0
        words.forEach { word ->
            word.confidence?.let { confidence ->
                val weight = max(1, word.text.count { !it.isWhitespace() })
                confidenceWeight += weight
                confidenceTotal += confidence * weight
            }
        }
        val text = words.joinToString(" ") { it.text.trim() }
        return OcrCandidate(
            text = text,
            confidence = if (confidenceWeight == 0) {
                null
            } else {
                (confidenceTotal / confidenceWeight).coerceIn(0.0, 1.0)
            },
            quality = candidateTextQuality(text),
        )
    }

    private fun chooseBestCandidate(
        candidates: List<OcrCandidate>,
        expectedLineCount: Int? = null,
        expectedWordCount: Int? = null,
    ): OcrCandidate? {
        if (candidates.isEmpty()) return null
        val agreement = candidates.groupingBy { canonicalCandidate(it.text) }.eachCount()
        return candidates.maxWithOrNull(
            compareBy<OcrCandidate> {
                val repetitions = agreement[canonicalCandidate(it.text)] ?: 1
                val confidence = it.confidence ?: UNKNOWN_CONFIDENCE
                val consensus = candidates
                    .asSequence()
                    .filter { other -> other !== it }
                    .map { other -> candidateSimilarity(it.text, other.text) }
                    .averageOrZero()
                val lineLayout = expectedLineCount?.let { expected ->
                    countSimilarity(it.text.lines().size, expected)
                } ?: 0.0
                val wordLayout = expectedWordCount?.let { expected ->
                    val actual = it.text
                        .split(WHITESPACE)
                        .count { word -> word.isNotBlank() }
                    countSimilarity(actual, expected)
                } ?: 0.0
                confidence * CONFIDENCE_WEIGHT +
                    it.quality * QUALITY_WEIGHT +
                    min(MAX_AGREEMENT_BONUS, (repetitions - 1) * AGREEMENT_BONUS) +
                    consensus * CONSENSUS_WEIGHT +
                    lineLayout * LINE_LAYOUT_WEIGHT +
                    wordLayout * WORD_LAYOUT_WEIGHT
            }.thenBy { it.confidence ?: UNKNOWN_CONFIDENCE }
                .thenBy { it.text.count(Char::isLetterOrDigit) },
        )
    }

    private fun Sequence<Double>.averageOrZero(): Double {
        var count = 0
        var total = 0.0
        for (value in this) {
            total += value
            count++
        }
        return if (count == 0) 0.0 else total / count
    }

    private fun countSimilarity(actual: Int, expected: Int): Double {
        if (expected <= 0) return if (actual <= 0) 1.0 else 0.0
        return (1.0 - abs(actual - expected).toDouble() / expected)
            .coerceIn(0.0, 1.0)
    }

    private fun candidateTextQuality(text: String): Double {
        val visible = text.count { !it.isWhitespace() }
        if (visible == 0) return 0.0
        val lettersAndDigits = text.count(Char::isLetterOrDigit)
        val controlCharacters = text.count { it.isISOControl() && it != '\n' }
        return ((lettersAndDigits - controlCharacters * 2).toDouble() / visible)
            .coerceIn(0.0, 1.0)
    }

    private fun canonicalCandidate(text: String): String = text
        .lowercase()
        .lines()
        .map { line -> line.replace(WHITESPACE, " ").trim() }
        .filter { line -> line.isNotEmpty() }
        .joinToString("\n")

    /**
     * OCR profiles often differ by only one ambiguous glyph. Approximate
     * agreement makes the shared spelling win even when no two full strings
     * are byte-identical, while confidence remains the dominant signal.
     */
    private fun candidateSimilarity(first: String, second: String): Double {
        val left = canonicalCandidate(first)
        val right = canonicalCandidate(second)
        if (left == right) return 1.0
        if (left.isEmpty() || right.isEmpty()) return 0.0
        val maximumLength = max(left.length, right.length)
        if (abs(left.length - right.length) > maximumLength * .55) return 0.0
        val previous = IntArray(right.length + 1) { it }
        val current = IntArray(right.length + 1)
        for (leftIndex in left.indices) {
            current[0] = leftIndex + 1
            for (rightIndex in right.indices) {
                val substitution = if (left[leftIndex] == right[rightIndex]) 0 else 1
                current[rightIndex + 1] = min(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                    ),
                    previous[rightIndex] + substitution,
                )
            }
            for (index in previous.indices) previous[index] = current[index]
        }
        return (1.0 - previous[right.length].toDouble() / maximumLength)
            .coerceIn(0.0, 1.0)
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
                    timestampMicros = optionalTimestamp(point["timestampMicros"]),
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

    private fun renderInk(
        request: RecognitionRequest,
        renderStyle: RenderStyle,
        lineCountHint: Int,
    ): Bitmap {
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
        if (right - left < MIN_INK_EXTENT) {
            val center = (left + right) * .5f
            left = center - MIN_INK_EXTENT * .5f
            right = center + MIN_INK_EXTENT * .5f
        }
        if (bottom - top < MIN_INK_EXTENT) {
            val center = (top + bottom) * .5f
            top = center - MIN_INK_EXTENT * .5f
            bottom = center + MIN_INK_EXTENT * .5f
        }
        val inkWidth = right - left
        val inkHeight = bottom - top
        // Keep a stable raster height per estimated line. A fixed total height
        // made multi-line SMART Board selections too small for the OCR model.
        val targetInkHeight =
            renderStyle.targetLineHeight * lineCountHint.coerceIn(1, MAX_LINE_FALLBACKS)
        var scale = targetInkHeight / inkHeight
        scale = min(scale, renderStyle.maximumInkWidth / inkWidth)
        scale = min(scale, MAX_INK_HEIGHT / inkHeight)
        scale = scale.coerceIn(MIN_SCALE, MAX_SCALE)

        val contentWidth = inkWidth * scale
        val contentHeight = inkHeight * scale
        val width = ceil(contentWidth + renderStyle.padding * 2).toInt()
            .coerceIn(MIN_BITMAP_SIZE, MAX_BITMAP_SIZE)
        val height = ceil(contentHeight + renderStyle.padding * 2).toInt()
            .coerceIn(MIN_BITMAP_SIZE, MAX_BITMAP_SIZE)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            val offsetX = (width - contentWidth) / 2f - left * scale
            val offsetY = (height - contentHeight) / 2f - top * scale
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.BLACK
                style = Paint.Style.STROKE
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
                strokeWidth = renderStyle.strokeWidth
            }
            val dotPaint = Paint(paint).apply {
                style = Paint.Style.FILL
            }
            request.strokes.forEach { stroke ->
                val points = rasterPoints(stroke, scale, offsetX, offsetY)
                val first = points.first()
                if (points.size == 1) {
                    // A one-point stroke represents a dot, not an outlined circle.
                    canvas.drawCircle(
                        first.x,
                        first.y,
                        renderStyle.strokeWidth / 2f,
                        dotPaint,
                    )
                    return@forEach
                }
                val path = Path().apply { moveTo(first.x, first.y) }
                if (renderStyle.smoothPath) {
                    // Midpoint interpolation suppresses sampling stair-steps
                    // without joining independent strokes.
                    for (index in 1 until points.lastIndex) {
                        val previous = points[index]
                        val next = points[index + 1]
                        path.quadTo(
                            previous.x,
                            previous.y,
                            (previous.x + next.x) * .5f,
                            (previous.y + next.y) * .5f,
                        )
                    }
                } else {
                    // Preserve sharp corners in one deliberately thin profile.
                    // This helps distinguish handwritten M/N, V/U and 1/7 on
                    // panels whose firmware already smooths stylus packets.
                    for (index in 1 until points.lastIndex) {
                        path.lineTo(points[index].x, points[index].y)
                    }
                }
                val point = points.last()
                path.lineTo(point.x, point.y)
                canvas.drawPath(path, paint)
            }
            return bitmap
        } catch (error: Throwable) {
            bitmap.recycle()
            throw error
        }
    }

    /**
     * Normalizes very dense SMART Board packets after world-to-raster scaling.
     * This makes OCR input independent of a panel's sampling rate and caps path
     * commands while retaining both endpoints and every meaningful turn.
     */
    private fun rasterPoints(
        source: List<InkPoint>,
        scale: Float,
        offsetX: Float,
        offsetY: Float,
    ): List<RasterPoint> {
        if (source.size == 1) {
            return listOf(
                RasterPoint(
                    source.first().x * scale + offsetX,
                    source.first().y * scale + offsetY,
                ),
            )
        }
        val indexStep = max(
            1,
            ceil(source.size.toDouble() / MAX_RASTER_POINTS_PER_STROKE).toInt(),
        )
        val result = ArrayList<RasterPoint>(
            min(source.size, MAX_RASTER_POINTS_PER_STROKE + 1),
        )
        var index = 0
        while (index < source.lastIndex) {
            val point = source[index]
            val rasterPoint = RasterPoint(
                point.x * scale + offsetX,
                point.y * scale + offsetY,
            )
            val previous = result.lastOrNull()
            if (previous == null ||
                squaredDistance(previous, rasterPoint) >=
                    MIN_RASTER_POINT_DISTANCE * MIN_RASTER_POINT_DISTANCE
            ) {
                result += rasterPoint
            }
            index += indexStep
        }
        val lastSource = source.last()
        val last = RasterPoint(
            lastSource.x * scale + offsetX,
            lastSource.y * scale + offsetY,
        )
        if (result.isEmpty() || result.last() != last) result += last
        return result
    }

    private fun squaredDistance(first: RasterPoint, second: RasterPoint): Float {
        val dx = first.x - second.x
        val dy = first.y - second.y
        return dx * dx + dy * dy
    }

    private fun splitIntoLines(strokes: List<List<InkPoint>>): List<List<List<InkPoint>>> {
        if (strokes.size < 2) return listOf(strokes)
        val positioned = strokes.map { stroke ->
            var left = Float.POSITIVE_INFINITY
            var top = Float.POSITIVE_INFINITY
            var right = Float.NEGATIVE_INFINITY
            var bottom = Float.NEGATIVE_INFINITY
            stroke.forEach { point ->
                left = min(left, point.x)
                top = min(top, point.y)
                right = max(right, point.x)
                bottom = max(bottom, point.y)
            }
            PositionedStroke(stroke, left, top, right, bottom)
        }.sortedWith(compareBy<PositionedStroke> { it.centerY }.thenBy { it.left })

        val lines = ArrayList<MutableInkLine>()
        for (positionedStroke in positioned) {
            val best = lines
                .filter { it.accepts(positionedStroke) }
                .minByOrNull { abs(it.centerY - positionedStroke.centerY) }
            if (best == null) {
                lines += MutableInkLine(positionedStroke)
            } else {
                best.add(positionedStroke)
            }
        }
        return lines
            .sortedBy { it.top }
            .map { line -> line.strokes.sortedBy { it.left }.map { it.points } }
    }

    /**
     * Splits only at unambiguous horizontal whitespace. The threshold scales
     * with the actual line height, so a word written very large on an
     * interactive panel behaves like the same word written on a tablet.
     * Overlapping letter strokes, detached dots and cursive words remain one
     * group.
     */
    private fun splitIntoWords(line: List<List<InkPoint>>): List<List<List<InkPoint>>> {
        if (line.size < 2) return listOf(line)
        val positioned = line.map { stroke ->
            var left = Float.POSITIVE_INFINITY
            var top = Float.POSITIVE_INFINITY
            var right = Float.NEGATIVE_INFINITY
            var bottom = Float.NEGATIVE_INFINITY
            stroke.forEach { point ->
                left = min(left, point.x)
                top = min(top, point.y)
                right = max(right, point.x)
                bottom = max(bottom, point.y)
            }
            PositionedStroke(stroke, left, top, right, bottom)
        }.sortedWith(compareBy<PositionedStroke> { it.left }.thenBy { it.top })

        val lineTop = positioned.minOf { it.top }
        val lineBottom = positioned.maxOf { it.bottom }
        val lineHeight = max(1f, lineBottom - lineTop)
        val minimumWordGap = max(MIN_WORD_GAP_WORLD, lineHeight * WORD_GAP_HEIGHT_RATIO)
        val temporalWordGap = max(
            MIN_TEMPORAL_WORD_GAP_WORLD,
            lineHeight * TEMPORAL_WORD_GAP_HEIGHT_RATIO,
        )
        val words = ArrayList<MutableList<PositionedStroke>>()
        var current = arrayListOf(positioned.first())
        var occupiedRight = positioned.first().right
        var latestTimestamp = positioned.first().endMicros
        for (index in 1 until positioned.size) {
            val stroke = positioned[index]
            val gap = stroke.left - occupiedRight
            val pause = if (stroke.startMicros != null && latestTimestamp != null) {
                stroke.startMicros - latestTimestamp
            } else {
                0L
            }
            val startsNewWord =
                gap > minimumWordGap ||
                    (gap > temporalWordGap && pause >= WORD_PAUSE_MICROS)
            if (startsNewWord) {
                words += current
                current = arrayListOf(stroke)
                occupiedRight = stroke.right
                latestTimestamp = stroke.endMicros
            } else {
                current += stroke
                occupiedRight = max(occupiedRight, stroke.right)
                val endMicros = stroke.endMicros
                if (endMicros != null &&
                    (latestTimestamp == null || endMicros > latestTimestamp)
                ) {
                    latestTimestamp = endMicros
                }
            }
        }
        words += current
        return words.map { word -> word.map { it.points } }
    }

    private fun normalizeRecognizedText(raw: String): String = raw
        .replace('\u0000', ' ')
        .lines()
        .map { line -> line.trim().replace(WHITESPACE, " ") }
        .filter { it.isNotEmpty() }
        .joinToString("\n")

    private fun isSupportedLanguageTag(rawTag: String): Boolean {
        val tag = rawTag.trim()
        if (tag.isEmpty() || tag.length > MAX_LANGUAGE_TAG_LENGTH) return false
        if (!LANGUAGE_TAG.matches(tag)) return false
        return tag.substringBefore('-').lowercase() in LATIN_LANGUAGE_CODES
    }

    private fun finiteCoordinate(value: Any?, axis: String): Float {
        val coordinate = (value as? Number)?.toDouble()
            ?: throw ChannelException("invalid_ink", "Koordinate $axis fehlt.")
        if (!coordinate.isFinite() || abs(coordinate) > MAX_ABSOLUTE_COORDINATE) {
            throw ChannelException("invalid_ink", "Koordinate $axis ist ungültig.")
        }
        return coordinate.toFloat()
    }

    private fun optionalTimestamp(value: Any?): Long? {
        val timestamp = (value as? Number)?.toDouble() ?: return null
        if (!timestamp.isFinite() ||
            timestamp <= 0 ||
            timestamp > MAX_TIMESTAMP_MICROS
        ) return null
        return timestamp.toLong()
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any) {
        mainHandler.post { if (!disposed) result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { if (!disposed) result.error(code, message, null) }
    }

    private data class InkPoint(
        val x: Float,
        val y: Float,
        val timestampMicros: Long?,
    )
    private data class RasterPoint(val x: Float, val y: Float)
    private data class RecognitionRequest(val strokes: List<List<InkPoint>>)
    private data class RecognitionOutcome(
        val candidate: OcrCandidate?,
        val attemptCount: Int,
    )
    private data class OcrCandidate(
        val text: String,
        val confidence: Double?,
        val quality: Double,
    )
    private data class RenderStyle(
        val targetLineHeight: Float,
        val maximumInkWidth: Float,
        val padding: Float,
        val strokeWidth: Float,
        val smoothPath: Boolean = true,
    )

    private data class PositionedStroke(
        val points: List<InkPoint>,
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
    ) {
        val centerY: Float get() = (top + bottom) * .5f
        val height: Float get() = max(1f, bottom - top)
        val startMicros: Long? = points.mapNotNull { it.timestampMicros }.minOrNull()
        val endMicros: Long? = points.mapNotNull { it.timestampMicros }.maxOrNull()
    }

    private class MutableInkLine(first: PositionedStroke) {
        val strokes = ArrayList<PositionedStroke>().apply { add(first) }
        var top = first.top
            private set
        private var bottom = first.bottom
        private var referenceStrokeHeight = first.height
        val centerY: Float get() = (top + bottom) * .5f

        fun accepts(stroke: PositionedStroke): Boolean {
            // Detached dots and umlauts must stay with their letter body.
            // Base the threshold on individual strokes, not the growing union
            // height: one accidental merge must not chain all following
            // baselines into the same line.
            val tolerance = max(
                12f,
                max(referenceStrokeHeight, stroke.height) *
                    LINE_CENTER_TOLERANCE_RATIO,
            )
            return abs(centerY - stroke.centerY) <= tolerance
        }

        fun add(stroke: PositionedStroke) {
            strokes += stroke
            top = min(top, stroke.top)
            bottom = max(bottom, stroke.bottom)
            referenceStrokeHeight = max(referenceStrokeHeight, stroke.height)
        }
    }

    private class ChannelException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/handwriting_recognition"
        const val DEFAULT_LANGUAGE_TAG = "de-DE"
        const val TAG = "FlowboardHandwriting"
        const val ENGINE_NAME = "bundledLatinOcr16"
        const val MODEL_DELIVERY = "bundled-apk"
        const val MAX_LANGUAGE_TAG_LENGTH = 64
        const val MAX_STROKES = 4_096
        const val MAX_POINTS = 250_000
        const val MAX_ABSOLUTE_COORDINATE = 10_000_000.0
        const val MAX_TIMESTAMP_MICROS = 9_000_000_000_000_000.0
        const val MAX_RASTER_POINTS_PER_STROKE = 12_000
        const val MIN_RASTER_POINT_DISTANCE = 0.35f
        const val MIN_INK_EXTENT = 1f
        const val MAX_INK_HEIGHT = 1_000f
        const val MIN_SCALE = 0.05f
        const val MAX_SCALE = 64f
        const val MIN_BITMAP_SIZE = 128
        const val MAX_BITMAP_SIZE = 2_048
        // Cold model initialization is noticeably slower on some integrated
        // classroom boards. Work remains off the UI thread and globally
        // bounded, so a longer first-call budget improves reliability without
        // affecting writing latency.
        const val MODEL_WARMUP_TIMEOUT_SECONDS = 8L
        const val RECOGNITION_TIMEOUT_SECONDS = 14L
        const val MAX_LINE_FALLBACKS = 6
        const val MAX_WORD_FALLBACKS = 16
        const val LINE_FALLBACK_CONFIDENCE = 0.58
        const val WORD_FALLBACK_CONFIDENCE = 0.62
        const val MIN_WORD_GAP_WORLD = 10f
        const val WORD_GAP_HEIGHT_RATIO = 0.42f
        const val MIN_TEMPORAL_WORD_GAP_WORLD = 4f
        const val TEMPORAL_WORD_GAP_HEIGHT_RATIO = 0.18f
        const val WORD_PAUSE_MICROS = 380_000L
        const val LINE_CENTER_TOLERANCE_RATIO = 0.86f
        const val UNKNOWN_CONFIDENCE = 0.42
        const val CONFIDENCE_WEIGHT = 0.62
        const val QUALITY_WEIGHT = 0.20
        const val CONSENSUS_WEIGHT = 0.12
        const val LINE_LAYOUT_WEIGHT = 0.05
        const val WORD_LAYOUT_WEIGHT = 0.03
        const val AGREEMENT_BONUS = 0.08
        const val MAX_AGREEMENT_BONUS = 0.16
        val DIRECT_EXECUTOR = Executor { command -> command.run() }
        val RENDER_STYLES = listOf(
            RenderStyle(112f, 1_900f, 30f, 7f),
            RenderStyle(96f, 1_900f, 28f, 3.25f, smoothPath = false),
            RenderStyle(76f, 1_900f, 24f, 5f),
            RenderStyle(176f, 1_900f, 40f, 10.5f),
        )
        val LINE_RENDER_STYLE = RenderStyle(128f, 1_900f, 32f, 8f)
        val WORD_RENDER_STYLE = RenderStyle(144f, 1_500f, 34f, 7f)
        val WHITESPACE = Regex("\\s+")
        val LANGUAGE_TAG = Regex("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
        val LATIN_LANGUAGE_CODES = setOf(
            "af",
            "ca",
            "cs",
            "cy",
            "da",
            "de",
            "en",
            "es",
            "et",
            "eu",
            "fi",
            "fr",
            "ga",
            "gl",
            "hr",
            "hu",
            "id",
            "is",
            "it",
            "la",
            "lt",
            "lv",
            "ms",
            "mt",
            "nl",
            "no",
            "pl",
            "pt",
            "ro",
            "sk",
            "sl",
            "sq",
            "sv",
            "sw",
            "tr",
            "vi",
        )
    }
}
