package de.flowboardx.flowboard_x

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.Collections
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Fully APK-bundled Latin handwriting/text-line recognizer.
 *
 * The official PaddleOCR PP-OCRv5 Mobile model is executed with ONNX Runtime
 * on the CPU. The engine performs no network or model-manager operation.
 */
class PaddleOcrHandwritingRecognizer(context: Context) : AutoCloseable {
    private val assets = context.applicationContext.assets
    // Loading ORT may throw a LinkageError on vendor images with restrictive
    // linker namespaces. Keep it out of MainActivity/FlutterEngine startup so
    // the independent bundled ML Kit fallback can still serve the app.
    private val environment by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        OrtEnvironment.getEnvironment()
    }
    private val lock = Any()

    @Volatile
    private var closed = false

    @Volatile
    private var state: EngineState? = null

    fun hasBundledAssets(): Boolean = runCatching {
        assets.open(MODEL_ASSET, android.content.res.AssetManager.ACCESS_STREAMING)
            .use { stream -> stream.read() >= 0 }
        assets.open(CONFIG_ASSET, android.content.res.AssetManager.ACCESS_STREAMING)
            .use { stream -> stream.read() >= 0 }
    }.getOrDefault(false)

    /**
     * Recognizes one tightly cropped text line. Calls are serialized by the
     * owning handwriting worker, so one reusable session is sufficient.
     */
    @Throws(OrtException::class)
    fun recognize(bitmap: Bitmap): PaddleOcrCtcDecoder.Result? {
        check(!closed) { "PP-OCRv5 recognizer is closed" }
        require(bitmap.width > 0 && bitmap.height > 0) {
            "PP-OCRv5 input bitmap is empty"
        }
        val localState = ensureState()
        val input = prepareInput(bitmap)
        OnnxTensor.createTensor(
            environment,
            input.values,
            longArrayOf(1, CHANNEL_COUNT.toLong(), INPUT_HEIGHT.toLong(), input.width.toLong()),
        ).use { tensor ->
            localState.session.run(
                Collections.singletonMap(localState.inputName, tensor),
            ).use { output ->
                val outputTensor = output[0] as? OnnxTensor
                    ?: throw OrtException("PP-OCRv5 returned no tensor")
                val shape = outputTensor.info.shape
                if (shape.size != 3 ||
                    shape[0] != 1L ||
                    shape[1] <= 0L ||
                    shape[2] <= 0L ||
                    shape[1] > Int.MAX_VALUE ||
                    shape[2] > Int.MAX_VALUE
                ) {
                    throw OrtException(
                        "Unexpected PP-OCRv5 output shape ${shape.contentToString()}",
                    )
                }
                val timeSteps = shape[1].toInt()
                val classCount = shape[2].toInt()
                val outputBuffer: FloatBuffer = outputTensor.floatBuffer
                val probabilities = FloatArray(outputBuffer.remaining())
                outputBuffer.get(probabilities)
                return PaddleOcrCtcDecoder.decode(
                    probabilities = probabilities,
                    timeSteps = timeSteps,
                    classCount = classCount,
                    characters = localState.characters,
                )
            }
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            state?.session?.close()
            state = null
        }
    }

    private fun ensureState(): EngineState {
        state?.let { return it }
        synchronized(lock) {
            check(!closed) { "PP-OCRv5 recognizer is closed" }
            state?.let { return it }
            val model = assets.open(
                MODEL_ASSET,
                android.content.res.AssetManager.ACCESS_STREAMING,
            ).use { it.readBytes() }
            val yaml = assets.open(
                CONFIG_ASSET,
                android.content.res.AssetManager.ACCESS_STREAMING,
            ).bufferedReader(Charsets.UTF_8).use { it.readText() }
            val characters = PaddleOcrCtcDecoder.parseCharacterDictionary(yaml)
            require(characters.size == EXPECTED_CHARACTER_COUNT) {
                "Unexpected PP-OCRv5 character count: ${characters.size}"
            }
            val options = OrtSession.SessionOptions().apply {
                setInterOpNumThreads(1)
                setIntraOpNumThreads(
                    min(MAX_INFERENCE_THREADS, max(1, Runtime.getRuntime().availableProcessors() / 2)),
                )
                setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            }
            val session = try {
                environment.createSession(model, options)
            } finally {
                options.close()
            }
            val inputName = session.inputNames.singleOrNull()
                ?: run {
                    session.close()
                    error("PP-OCRv5 must have exactly one input")
                }
            return EngineState(session, inputName, characters).also { state = it }
        }
    }

    /**
     * Mirrors PaddleOCR's `RecResizeImg(eval_mode=true)` preprocessing:
     * BGR, CHW, `(pixel / 255 - .5) / .5`, 48 px height, at least 320 px
     * width, and zero padding in normalized space.
     */
    private fun prepareInput(bitmap: Bitmap): PreparedInput {
        val aspectRatio = bitmap.width.toDouble() / bitmap.height
        val resizedWidth = ceil(INPUT_HEIGHT * aspectRatio)
            .toInt()
            .coerceIn(1, MAX_INPUT_WIDTH)
        val inputWidth = max(DEFAULT_INPUT_WIDTH, resizedWidth)
        val resized = Bitmap.createScaledBitmap(
            bitmap,
            resizedWidth,
            INPUT_HEIGHT,
            true,
        )
        try {
            val pixels = IntArray(resizedWidth * INPUT_HEIGHT)
            resized.getPixels(
                pixels,
                0,
                resizedWidth,
                0,
                0,
                resizedWidth,
                INPUT_HEIGHT,
            )
            val planeSize = INPUT_HEIGHT * inputWidth
            // ORT can use a direct native-order FloatBuffer without making
            // another complete JNI-side copy of the input tensor.
            val values = ByteBuffer
                .allocateDirect(CHANNEL_COUNT * planeSize * Float.SIZE_BYTES)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
            for (y in 0 until INPUT_HEIGHT) {
                val sourceRow = y * resizedWidth
                val destinationRow = y * inputWidth
                for (x in 0 until resizedWidth) {
                    val color = pixels[sourceRow + x]
                    // Bitmap is ARGB while Paddle expects BGR. Flowboard ink
                    // is grayscale, but retaining all channels also keeps this
                    // adapter correct for future colored raster inputs.
                    values.put(
                        destinationRow + x,
                        normalize(android.graphics.Color.blue(color)),
                    )
                    values.put(
                        planeSize + destinationRow + x,
                        normalize(android.graphics.Color.green(color)),
                    )
                    values.put(
                        planeSize * 2 + destinationRow + x,
                        normalize(android.graphics.Color.red(color)),
                    )
                }
            }
            return PreparedInput(values, inputWidth)
        } finally {
            if (resized !== bitmap) resized.recycle()
        }
    }

    private fun normalize(channel: Int): Float = channel / 127.5f - 1f

    private data class PreparedInput(
        val values: FloatBuffer,
        val width: Int,
    )

    private data class EngineState(
        val session: OrtSession,
        val inputName: String,
        val characters: List<String>,
    )

    private companion object {
        const val MODEL_ASSET =
            "handwriting/latin_PP-OCRv5_mobile_rec.onnx"
        const val CONFIG_ASSET =
            "handwriting/latin_PP-OCRv5_mobile_rec.yml"
        const val CHANNEL_COUNT = 3
        const val INPUT_HEIGHT = 48
        const val DEFAULT_INPUT_WIDTH = 320
        // Bounds one fp32 input below 1.2 MiB on low-power classroom panels.
        const val MAX_INPUT_WIDTH = 2_048
        const val MAX_INFERENCE_THREADS = 4
        const val EXPECTED_CHARACTER_COUNT = 836
    }
}
