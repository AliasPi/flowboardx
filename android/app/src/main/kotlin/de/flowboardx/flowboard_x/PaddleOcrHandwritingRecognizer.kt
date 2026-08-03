package de.flowboardx.flowboard_x

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Fully APK-bundled Latin handwriting/text-line recognizer.
 *
 * The official PaddleOCR PP-OCRv6 Small model is executed with ONNX Runtime
 * on the CPU. The engine performs no network or model-manager operation.
 */
class PaddleOcrHandwritingRecognizer(context: Context) : AutoCloseable {
    private val applicationContext = context.applicationContext
    private val assets = applicationContext.assets
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

    private var reusableInputBuffer: FloatBuffer? = null
    private val activeRunOptions = AtomicReference<OrtSession.RunOptions?>()
    private val activeRecognitions = AtomicInteger(0)

    fun hasBundledAssets(): Boolean = try {
        val hasModel =
            assets.open(MODEL_ASSET, android.content.res.AssetManager.ACCESS_STREAMING)
                .use { stream -> stream.read() >= 0 }
        val hasConfiguration =
            assets.open(CONFIG_ASSET, android.content.res.AssetManager.ACCESS_STREAMING)
                .use { stream -> stream.read() >= 0 }
        hasModel && hasConfiguration
    } catch (error: VirtualMachineError) {
        throw error
    } catch (_: Exception) {
        false
    }

    /**
     * Recognizes one tightly cropped text line. Calls are serialized by the
     * owning handwriting worker, so one reusable session is sufficient.
     */
    @Throws(OrtException::class)
    fun recognize(
        bitmap: Bitmap,
        deadlineNanos: Long,
    ): PaddleOcrCtcDecoder.Result? {
        check(!closed) { "PP-OCRv6 recognizer is closed" }
        require(bitmap.width > 0 && bitmap.height > 0) {
            "PP-OCRv6 input bitmap is empty"
        }
        check(deadlineNanos - System.nanoTime() > 0L) {
            "PP-OCRv6 recognition deadline elapsed"
        }
        activeRecognitions.incrementAndGet()
        try {
            val localState = ensureState()
            val input = prepareInput(bitmap)
            OnnxTensor.createTensor(
                environment,
                input.values,
                longArrayOf(
                    1,
                    CHANNEL_COUNT.toLong(),
                    INPUT_HEIGHT.toLong(),
                    input.width.toLong(),
                ),
            ).use { tensor ->
                OrtSession.RunOptions().use { runOptions ->
                    check(activeRunOptions.compareAndSet(null, runOptions)) {
                        "A PP-OCRv6 inference is already active"
                    }
                    var termination: ScheduledFuture<*>? = null
                    try {
                        val inferenceBudget = deadlineNanos - System.nanoTime()
                        check(inferenceBudget > 0L) {
                            "PP-OCRv6 recognition deadline elapsed"
                        }
                        termination = TERMINATION_EXECUTOR.schedule(
                            { terminateRun(runOptions) },
                            inferenceBudget,
                            TimeUnit.NANOSECONDS,
                        )
                        localState.session.run(
                            Collections.singletonMap(localState.inputName, tensor),
                            runOptions,
                        ).use { output ->
                            val outputTensor = output[0] as? OnnxTensor
                                ?: throw OrtException("PP-OCRv6 returned no tensor")
                            val shape = outputTensor.info.shape
                            if (shape.size != 3 ||
                                shape[0] != 1L ||
                                shape[1] <= 0L ||
                                shape[2] <= 0L ||
                                shape[1] > Int.MAX_VALUE ||
                                shape[2] > Int.MAX_VALUE
                            ) {
                                throw OrtException(
                                    "Unexpected PP-OCRv6 output shape ${shape.contentToString()}",
                                )
                            }
                            val timeSteps = shape[1].toInt()
                            val classCount = shape[2].toInt()
                            return PaddleOcrCtcDecoder.decode(
                                probabilities = outputTensor.floatBuffer,
                                timeSteps = timeSteps,
                                classCount = classCount,
                                characters = localState.characters,
                                allowedClassIndices = localState.allowedClassIndices,
                            )
                        }
                    } finally {
                        synchronized(runOptions) {
                            activeRunOptions.compareAndSet(runOptions, null)
                            termination?.cancel(false)
                        }
                    }
                }
            }
        } finally {
            activeRecognitions.decrementAndGet()
        }
    }

    /**
     * Requests termination in ONNX Runtime itself. Interrupting only the Java
     * worker cannot stop a synchronous native OrtSession.run call.
     */
    fun cancelActiveRun() {
        activeRunOptions.get()?.let(::terminateRun)
    }

    /**
     * Releases the large native ORT session after handwriting conversion has
     * been idle. The bundled model file remains installed and the recognizer
     * object remains reusable; [ensureState] recreates the session on the next
     * explicit conversion.
     *
     * This is intentionally a no-op while a request is between state lookup
     * and native inference. Closing in that narrow window can crash vendor ORT
     * builds even when no [RunOptions] has been published yet.
     */
    fun releaseIdleResources(): Boolean {
        synchronized(lock) {
            if (closed ||
                activeRecognitions.get() != 0 ||
                activeRunOptions.get() != null
            ) {
                return false
            }
            val idleState = state
            state = null
            reusableInputBuffer = null
            if (idleState != null) {
                try {
                    idleState.session.close()
                } finally {
                    idleState.options.close()
                }
            }
            return true
        }
    }

    override fun close() {
        cancelActiveRun()
        synchronized(lock) {
            if (closed) return
            closed = true
            state?.let { engine ->
                // ONNX Runtime requires SessionOptions to outlive every
                // OrtSession created from them. Closing the options directly
                // after createSession can release native state still used by
                // inference and manifests as an uncatchable SIGSEGV/SIGABRT
                // on some ARM vendor runtimes.
                try {
                    engine.session.close()
                } finally {
                    engine.options.close()
                }
            }
            state = null
            reusableInputBuffer = null
        }
    }

    private fun terminateRun(runOptions: OrtSession.RunOptions) {
        synchronized(runOptions) {
            if (activeRunOptions.get() !== runOptions) return
            try {
                runOptions.setTerminate(true)
            } catch (error: VirtualMachineError) {
                throw error
            } catch (error: Throwable) {
                Log.w(TAG, "Could not terminate PP-OCRv6 inference", error)
            }
        }
    }

    private fun ensureState(): EngineState {
        state?.let { return it }
        synchronized(lock) {
            check(!closed) { "PP-OCRv6 recognizer is closed" }
            state?.let { return it }
            val modelFile = materializeModel()
            val yaml = assets.open(
                CONFIG_ASSET,
                android.content.res.AssetManager.ACCESS_STREAMING,
            ).bufferedReader(Charsets.UTF_8).use { it.readText() }
            val characters = PaddleOcrCtcDecoder.parseCharacterDictionary(yaml)
            require(characters.size == EXPECTED_CHARACTER_COUNT) {
                "Unexpected PP-OCRv6 character count: ${characters.size}"
            }
            val allowedClassIndices =
                PaddleOcrCtcDecoder.latinClassIndices(characters)
            val options = OrtSession.SessionOptions().apply {
                setInterOpNumThreads(1)
                setIntraOpNumThreads(
                    min(MAX_INFERENCE_THREADS, max(1, Runtime.getRuntime().availableProcessors() / 2)),
                )
                setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            }
            val session = try {
                // Loading by file path avoids retaining both an 8 MiB Java
                // byte[] and ORT's native model representation at startup.
                environment.createSession(modelFile.absolutePath, options)
            } catch (error: Throwable) {
                try {
                    options.close()
                } catch (closeError: Throwable) {
                    error.addSuppressed(closeError)
                }
                throw error
            }
            val inputName = session.inputNames.singleOrNull()
                ?: run {
                    try {
                        session.close()
                    } finally {
                        options.close()
                    }
                    error("PP-OCRv6 must have exactly one input")
                }
            return EngineState(
                session,
                options,
                inputName,
                characters,
                allowedClassIndices,
            ).also {
                state = it
            }
        }
    }

    /**
     * Copies the immutable APK asset once into private app storage. The
     * versioned destination and atomic rename make cold-start recovery safe
     * even if Android kills the process while the model is being copied.
     */
    private fun materializeModel(): File {
        synchronized(MODEL_FILE_LOCK) {
            val directory = File(applicationContext.noBackupFilesDir, MODEL_DIRECTORY)
            check(directory.isDirectory || directory.mkdirs()) {
                "Could not create the PP-OCRv6 model directory"
            }
            val destination = File(directory, MATERIALIZED_MODEL_NAME)
            if (isExpectedModel(destination)) {
                return destination
            }
            directory.listFiles { file ->
                file.isFile &&
                    file.name.startsWith(MATERIALIZED_TEMPORARY_PREFIX) &&
                    file.name.endsWith(".tmp")
            }?.forEach { stale -> stale.delete() }
            val temporary = File.createTempFile("paddle-model-", ".tmp", directory)
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                assets.open(
                    MODEL_ASSET,
                    android.content.res.AssetManager.ACCESS_STREAMING,
                ).use { assetInput ->
                    DigestInputStream(assetInput, digest).use { input ->
                        FileOutputStream(temporary).use { fileOutput ->
                            val output = BufferedOutputStream(
                                fileOutput,
                                MODEL_COPY_BUFFER_SIZE,
                            )
                            input.copyTo(output, MODEL_COPY_BUFFER_SIZE)
                            output.flush()
                            fileOutput.fd.sync()
                        }
                    }
                }
                check(temporary.length() == EXPECTED_MODEL_SIZE &&
                    digest.digest().toHexString() == EXPECTED_MODEL_SHA256
                ) {
                    "Bundled PP-OCRv6 model failed its integrity check"
                }
                if (destination.exists() && !destination.delete()) {
                    error("Could not replace the PP-OCRv6 model")
                }
                check(temporary.renameTo(destination)) {
                    "Could not publish the PP-OCRv6 model"
                }
                check(isExpectedModel(destination)) {
                    "Published PP-OCRv6 model failed its integrity check"
                }
                return destination
            } finally {
                if (temporary.exists()) temporary.delete()
            }
        }
    }

    private fun isExpectedModel(file: File): Boolean {
        if (!file.isFile || file.length() != EXPECTED_MODEL_SIZE) return false
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buffer = ByteArray(MODEL_COPY_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > 0) digest.update(buffer, 0, count)
                }
            }
            digest.digest().toHexString() == EXPECTED_MODEL_SHA256
        } catch (error: VirtualMachineError) {
            throw error
        } catch (error: Exception) {
            Log.w(TAG, "Could not validate materialized PP-OCRv6 model", error)
            false
        }
    }

    private fun ByteArray.toHexString(): String =
        joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

    /**
     * Uses PaddleOCR's dynamic `RecResizeImg` preprocessing contract:
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
            val valueCount = CHANNEL_COUNT * planeSize
            val values = reusableInputValues(valueCount)
            for (index in 0 until valueCount) {
                values.put(index, 0f)
            }
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

    /**
     * Reuses one direct tensor buffer. The owning service serializes
     * recognition calls, and OrtSession.run has completed before this buffer
     * can be requested again.
     */
    private fun reusableInputValues(requiredCapacity: Int): FloatBuffer {
        var storage = reusableInputBuffer
        if (storage == null || storage.capacity() < requiredCapacity) {
            storage = ByteBuffer
                .allocateDirect(requiredCapacity * Float.SIZE_BYTES)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
            reusableInputBuffer = storage
        }
        return storage.duplicate().apply {
            position(0)
            limit(requiredCapacity)
        }
    }

    private data class PreparedInput(
        val values: FloatBuffer,
        val width: Int,
    )

    private data class EngineState(
        val session: OrtSession,
        val options: OrtSession.SessionOptions,
        val inputName: String,
        val characters: List<String>,
        val allowedClassIndices: IntArray,
    )

    private companion object {
        const val MODEL_ASSET =
            "handwriting/PP-OCRv6_small_rec.onnx"
        const val MODEL_DIRECTORY = "flowboard-handwriting"
        const val MATERIALIZED_MODEL_NAME =
            "PP-OCRv6_small_rec-5435fd74.onnx"
        const val MATERIALIZED_TEMPORARY_PREFIX = "paddle-model-"
        const val EXPECTED_MODEL_SIZE = 21_159_378L
        const val EXPECTED_MODEL_SHA256 =
            "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634"
        const val MODEL_COPY_BUFFER_SIZE = 256 * 1_024
        const val CONFIG_ASSET =
            "handwriting/PP-OCRv6_small_rec.yml"
        const val CHANNEL_COUNT = 3
        const val INPUT_HEIGHT = 48
        const val DEFAULT_INPUT_WIDTH = 320
        // Bounds one fp32 input below 1.2 MiB on low-power classroom panels.
        const val MAX_INPUT_WIDTH = 2_048
        const val MAX_INFERENCE_THREADS = 4
        const val EXPECTED_CHARACTER_COUNT = 18_708
        const val TAG = "FlowboardHandwriting"
        val MODEL_FILE_LOCK = Any()
        val TERMINATION_EXECUTOR =
            Executors.newSingleThreadScheduledExecutor { task ->
                Thread(task, "flowboard-handwriting-timeout").apply {
                    isDaemon = true
                }
            }
    }
}
