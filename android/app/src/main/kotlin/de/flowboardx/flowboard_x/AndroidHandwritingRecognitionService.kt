package de.flowboardx.flowboard_x

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.content.Context
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
 * Offline handwriting adapter backed primarily by the APK-bundled
 * PP-OCRv5 Latin handwriting model, executed through ONNX Runtime.
 *
 * Flowboard keeps ink as vectors. For recognition only, this service renders a
 * tightly cropped, high-contrast line bitmap off the Android main thread.
 * ML Kit's bundled Latin image OCR remains a defensive fallback. Neither path
 * uses Play Services model installation or a runtime download.
 */
class AndroidHandwritingRecognitionService(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val rasterExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "flowboard-handwriting-raster").apply { isDaemon = true }
    }
    private val activeNativeTasks = AtomicInteger(0)
    private val pendingRequests = AtomicInteger(0)
    private val nativeTaskMonitor = Object()
    private val fallbackRecognizerLock = Any()
    private val recognizerClosed = AtomicBoolean(false)

    @Volatile
    private var fallbackRecognizer: TextRecognizer? = null

    @Volatile
    private var fallbackRecognizerInitializationAttempted = false

    @Volatile
    private var paddleRecognizer: PaddleOcrHandwritingRecognizer? =
        createPaddleRecognizer(context.applicationContext)

    @Volatile
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
    }

    private fun createPaddleRecognizer(context: Context): PaddleOcrHandwritingRecognizer? =
        OptionalNativeEngine.create(
            onFailure = { error ->
                // In particular catch LinkageError/ExceptionInInitializerError.
                // Paddle is an optional primary engine; its failure must never
                // prevent the independent ML Kit fallback from starting.
                Log.e(TAG, "Bundled PP-OCRv5 engine could not be prepared", error)
            },
        ) {
            PaddleOcrHandwritingRecognizer(context)
        }

    /**
     * ML Kit is a compatibility fallback, not a second opinion after a
     * successful Paddle run. Delaying construction keeps its model and native
     * runtime out of memory on the normal bundled-Paddle path.
     */
    private fun getOrCreateFallbackRecognizer(): TextRecognizer? {
        fallbackRecognizer?.let { return it }
        if (fallbackRecognizerInitializationAttempted ||
            recognizerClosed.get() ||
            disposed
        ) {
            return null
        }
        synchronized(fallbackRecognizerLock) {
            fallbackRecognizer?.let { return it }
            if (fallbackRecognizerInitializationAttempted ||
                recognizerClosed.get() ||
                disposed
            ) {
                return null
            }
            fallbackRecognizerInitializationAttempted = true
            val created = try {
                TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            } catch (error: VirtualMachineError) {
                throw error
            } catch (error: ExceptionInInitializerError) {
                rethrowVirtualMachineError(error)
                Log.e(TAG, "Bundled Latin fallback could not be initialized", error)
                null
            } catch (error: LinkageError) {
                rethrowVirtualMachineError(error)
                Log.e(TAG, "Bundled Latin fallback could not be linked", error)
                null
            } catch (error: Exception) {
                rethrowVirtualMachineError(error)
                Log.e(TAG, "Bundled Latin fallback could not be created", error)
                null
            }
            if (created == null) return null
            if (recognizerClosed.get() || disposed) {
                closeFallbackRecognizer(created)
                return null
            }
            fallbackRecognizer = created
            return created
        }
    }

    private fun disablePaddleRecognizer(
        failedRecognizer: PaddleOcrHandwritingRecognizer,
        error: Throwable,
    ) {
        rethrowVirtualMachineError(error)
        if (paddleRecognizer === failedRecognizer) {
            paddleRecognizer = null
        }
        runCatching { failedRecognizer.close() }
            .onFailure { closeError ->
                rethrowVirtualMachineError(closeError)
                Log.w(TAG, "Could not close failed PP-OCRv5 engine", closeError)
            }
        Log.w(TAG, "Bundled PP-OCRv5 disabled; using Latin OCR fallback", error)
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        // Drain accepted jobs so every MethodChannel call receives exactly
        // one terminal response. shutdownNow() used to drop queued two-user
        // requests and leave their Dart futures unresolved forever.
        rasterExecutor.shutdown()
        closeRecognizerWhenIdle()
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
                result.success(
                    isSupportedLanguageTag(languageTag) &&
                        (
                            paddleRecognizer?.hasBundledAssets() == true ||
                                getOrCreateFallbackRecognizer() != null
                            ),
                )
            }
            "recognize" -> recognize(call.arguments, result)
            else -> result.notImplemented()
        }
    }

    private fun recognize(arguments: Any?, result: MethodChannel.Result) {
        if (paddleRecognizer?.hasBundledAssets() != true &&
            getOrCreateFallbackRecognizer() == null
        ) {
            result.error(
                "recognizer_start_failed",
                "Die eingebettete Handschrifterkennung konnte nicht gestartet werden.",
                null,
            )
            return
        }
        val queued = pendingRequests.incrementAndGet()
        if (queued > MAX_PENDING_REQUESTS) {
            releasePendingRequest()
            result.success(
                mapOf(
                    "status" to "notRecognized",
                    "message" to
                        "Es warten bereits mehrere Handschrifterkennungen. " +
                        "Bitte einen Moment warten.",
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
                        rethrowVirtualMachineError(error)
                        Log.e(TAG, "Could not prepare handwriting input", error)
                        postError(
                            result,
                            "invalid_ink",
                            "Die Handschriftdaten sind ungültig.",
                        )
                        return@execute
                    }
                    if (disposed) {
                        postError(
                            result,
                            "service_closed",
                            "Die Handschrifterkennung wurde beendet.",
                        )
                        return@execute
                    }
                    // A timed-out native task can complete after Tasks.await
                    // returns. Wait for it instead of rejecting the next
                    // participant's valid request as unrecognized handwriting.
                    if (!awaitNativeTasksIdle(NATIVE_DRAIN_TIMEOUT_SECONDS)) {
                        if (disposed) {
                            postError(
                                result,
                                "service_closed",
                                "Die Handschrifterkennung wurde beendet.",
                            )
                            return@execute
                        }
                        postSuccess(
                            result,
                            mapOf(
                                "status" to "notRecognized",
                                "message" to
                                    "Die Erkennungs-Engine beendet noch einen " +
                                    "vorherigen Auftrag. Bitte gleich erneut versuchen.",
                                "engine" to ENGINE_NAME,
                                "modelDelivery" to MODEL_DELIVERY,
                                "attempts" to 0,
                            ),
                        )
                        return@execute
                    }
                    try {
                        val outcome = recognizeWithOfflineFallbacks(request)
                        if (disposed) {
                            postError(
                                result,
                                "service_closed",
                                "Die Handschrifterkennung wurde beendet.",
                            )
                            return@execute
                        }
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
                                    "lineCountHint" to outcome.lineCountHint,
                                    "wordCountHint" to outcome.wordCountHint,
                                    "durationMillis" to outcome.durationMillis,
                                    "timedOut" to outcome.timedOut,
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
                                    "lineCountHint" to outcome.lineCountHint,
                                    "wordCountHint" to outcome.wordCountHint,
                                    "durationMillis" to outcome.durationMillis,
                                    "timedOut" to outcome.timedOut,
                                ),
                            )
                        }
                    } catch (error: Throwable) {
                        rethrowVirtualMachineError(error)
                        Log.e(TAG, "Offline handwriting recognition failed", error)
                        postError(
                            result,
                            "recognition_failed",
                            "Die lokale Handschrifterkennung ist fehlgeschlagen.",
                        )
                    }
                } catch (error: VirtualMachineError) {
                    // A fatal allocation/linker failure must terminate this
                    // request immediately, but it must not become an uncaught
                    // background-thread exception that kills the Android app.
                    Log.e(TAG, "Handwriting recognition exhausted runtime resources", error)
                    postError(
                        result,
                        "recognition_resource_exhausted",
                        "Die Texterkennung hat nicht genügend Gerätespeicher.",
                    )
                } finally {
                    releasePendingRequest()
                }
            }
        } catch (error: VirtualMachineError) {
            releasePendingRequest()
            Log.e(TAG, "Handwriting worker could not be scheduled", error)
            result.error(
                "recognition_resource_exhausted",
                "Die Texterkennung hat nicht genügend Gerätespeicher.",
                null,
            )
        } catch (error: Throwable) {
            releasePendingRequest()
            rethrowVirtualMachineError(error)
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
        request: RecognitionRequest,
    ): RecognitionOutcome {
        val startedNanos = System.nanoTime()
        val deadlineNanos = System.nanoTime() +
            TimeUnit.SECONDS.toNanos(RECOGNITION_TIMEOUT_SECONDS)
        var attempts = 0
        var completedAttempt = false
        var timedOut = false
        var lastFailure: Throwable? = null
        val candidates = ArrayList<OcrCandidate>(
            PRIMARY_RENDER_STYLES.size + RECOVERY_RENDER_STYLES.size + 2,
        )
        val lines = HandwritingInkPreprocessor
            .splitIntoLines(request.strokes)
            .ifEmpty { listOf(request.strokes) }
        val lineCountHint = lines.size.coerceIn(1, MAX_LINE_FALLBACKS)
        val normalizedRequest = RecognitionRequest(lines.flatten())
        val wordsByLine = lines.map(HandwritingInkPreprocessor::splitIntoWords)
        val expectedWordCount = wordsByLine.sumOf { it.size }

        fun runPaddleProfile(
            engine: PaddleOcrHandwritingRecognizer,
            style: RenderStyle,
            label: String,
        ): OcrCandidate? {
            val recognizedLines = ArrayList<OcrCandidate>(lines.size)
            var completePaddleResult = true
            for (line in lines.take(MAX_LINE_FALLBACKS)) {
                if (System.nanoTime() >= deadlineNanos) {
                    timedOut = true
                    completePaddleResult = false
                    break
                }
                attempts++
                val bitmap = renderInk(
                    RecognitionRequest(line),
                    style,
                    1,
                )
                try {
                    val recognized = engine.recognize(bitmap)
                    completedAttempt = true
                    // ORT runs synchronously, but recognition is already off the
                    // UI thread. Enforce the shared budget immediately after
                    // native inference and discard an over-budget result.
                    if (System.nanoTime() >= deadlineNanos) {
                        timedOut = true
                        completePaddleResult = false
                        break
                    }
                    if (recognized == null) {
                        completePaddleResult = false
                        break
                    }
                    recognizedLines += OcrCandidate(
                        text = recognized.text,
                        confidence = recognized.confidence,
                        quality = candidateTextQuality(recognized.text),
                        layoutFidelity = 1.0,
                    )
                } catch (error: Throwable) {
                    rethrowVirtualMachineError(error)
                    completePaddleResult = false
                    lastFailure = error
                    if (error is InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                    disablePaddleRecognizer(engine, error)
                    break
                } finally {
                    bitmap.recycle()
                }
            }
            if (!completePaddleResult || recognizedLines.size != lines.size) {
                return null
            }
            Log.d(TAG, "Bundled PP-OCRv5 $label profile completed")
            return combineLineCandidates(recognizedLines)
        }

        fun paddleOutcome(candidate: OcrCandidate?): RecognitionOutcome {
            val durationMillis = TimeUnit.NANOSECONDS
                .toMillis(System.nanoTime() - startedNanos)
                .coerceIn(0L, Int.MAX_VALUE.toLong())
                .toInt()
            return RecognitionOutcome(
                candidate = candidate,
                attemptCount = attempts,
                lineCountHint = lines.size,
                wordCountHint = expectedWordCount,
                durationMillis = durationMillis,
                timedOut = timedOut,
            )
        }

        // A single moderate-confidence raster must not replace the selected ink
        // before any independent evidence is available. Very strong geometry-
        // consistent output may return directly; otherwise use a second Paddle
        // raster. ML Kit is only initialized if Paddle cannot execute at all.
        val localPaddle = paddleRecognizer
        if (localPaddle != null &&
            !disposed &&
            !Thread.currentThread().isInterrupted
        ) {
            val primaryPaddle = runPaddleProfile(
                localPaddle,
                PADDLE_RENDER_STYLES.first(),
                "primary",
            )
            if (primaryPaddle != null) {
                candidates += primaryPaddle
                if (PaddleCandidatePolicy.isStrongStandalone(
                        text = primaryPaddle.text,
                        confidence = primaryPaddle.confidence,
                        quality = primaryPaddle.quality,
                        expectedLineCount = lines.size,
                        expectedWordCount = expectedWordCount,
                    )
                ) {
                    return paddleOutcome(primaryPaddle)
                }
            }

            if (!timedOut &&
                paddleRecognizer === localPaddle &&
                PADDLE_RENDER_STYLES.size > 1
            ) {
                val confirmingPaddle = runPaddleProfile(
                    localPaddle,
                    PADDLE_RENDER_STYLES[1],
                    "confirmation",
                )
                if (confirmingPaddle != null) {
                    candidates += confirmingPaddle
                    if (primaryPaddle != null &&
                        PaddleCandidatePolicy.hasIndependentRasterConsensus(
                            firstConfidence = primaryPaddle.confidence,
                            firstQuality = primaryPaddle.quality,
                            secondConfidence = confirmingPaddle.confidence,
                            secondQuality = confirmingPaddle.quality,
                            similarity = candidateSimilarity(
                                primaryPaddle.text,
                                confirmingPaddle.text,
                            ),
                        )
                    ) {
                        val agreed = chooseBestCandidate(
                            listOf(primaryPaddle, confirmingPaddle),
                            expectedLineCount = lines.size,
                            expectedWordCount = expectedWordCount,
                        ) ?: primaryPaddle
                        return paddleOutcome(agreed)
                    }
                }
            }
        }

        if (completedAttempt) {
            // ORT completed successfully, so do not retain a second OCR runtime
            // merely to obtain another opinion. Preserve any candidate which
            // already satisfies the common acceptance policy; otherwise report
            // a safe not-recognized result and leave the source ink untouched.
            val acceptedPaddle = chooseBestCandidate(
                candidates.filter { candidate ->
                    candidateIsAcceptable(
                        candidate,
                        candidates = candidates,
                        expectedLineCount = lines.size,
                        expectedWordCount = expectedWordCount,
                    )
                },
                expectedLineCount = lines.size,
                expectedWordCount = expectedWordCount,
            )
            return paddleOutcome(acceptedPaddle)
        }

        val recognizer = getOrCreateFallbackRecognizer()

        fun runAttempt(
            attemptRequest: RecognitionRequest,
            style: RenderStyle,
            expectedLines: Int,
            label: String,
        ): OcrCandidate? {
            if (recognizer == null ||
                timedOut ||
                disposed ||
                Thread.currentThread().isInterrupted ||
                System.nanoTime() >= deadlineNanos
            ) {
                return null
            }
            attempts++
            val bitmap = renderInk(attemptRequest, style, expectedLines)
            try {
                val candidate = recognizeBitmap(recognizer, bitmap, deadlineNanos)
                completedAttempt = true
                return candidate
            } catch (error: TimeoutException) {
                lastFailure = error
                timedOut = true
                Log.w(TAG, "Handwriting $label reached its global deadline", error)
            } catch (error: Exception) {
                if (error is InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw error
                }
                lastFailure = error
                Log.w(TAG, "Handwriting $label attempt $attempts failed", error)
            }
            return null
        }

        // Start with one balanced page profile. On slower classroom panels the
        // old implementation spent the complete deadline on four page OCR
        // passes before reaching the more accurate geometric segmentation.
        runAttempt(
            normalizedRequest,
            PRIMARY_RENDER_STYLES.first(),
            lineCountHint,
            "primary raster",
        )?.let(candidates::add)

        // Multi-line ink is always recognized line-by-line once. High OCR
        // confidence alone is not evidence that a printed-text model retained
        // every handwritten line.
        if (lines.size in 2..MAX_LINE_FALLBACKS && !timedOut) {
            val recognizedLines = ArrayList<OcrCandidate>(lines.size)
            var completeLineResult = true
            for (line in lines) {
                val candidate = runAttempt(
                    RecognitionRequest(line),
                    LINE_RENDER_STYLE,
                    1,
                    "line",
                )
                if (candidate == null) {
                    completeLineResult = false
                    break
                }
                recognizedLines += candidate
            }
            // Never replace all selected ink with a partial transcription.
            if (completeLineResult && recognizedLines.size == lines.size) {
                candidates += combineLineCandidates(recognizedLines)
            }
        }

        // A deliberately sharp profile retains corners that board firmware may
        // already have smoothed (M/N, V/U, 1/7).
        if (!timedOut && PRIMARY_RENDER_STYLES.size > 1) {
            runAttempt(
                normalizedRequest,
                PRIMARY_RENDER_STYLES[1],
                lineCountHint,
                "sharp raster",
            )?.let(candidates::add)
        }

        val currentBest = chooseBestCandidate(
            candidates,
            expectedLineCount = lines.size,
            expectedWordCount = expectedWordCount,
        )
        val currentWordCount = currentBest?.text
            ?.split(WHITESPACE)
            ?.count { it.isNotBlank() } ?: 0
        val wordFallbackNeeded =
            expectedWordCount in 2..MAX_WORD_FALLBACKS &&
                (currentBest == null ||
                    currentWordCount != expectedWordCount ||
                    !candidateLooksReliable(
                        currentBest,
                        expectedLineCount = lines.size,
                        expectedWordCount = expectedWordCount,
                    ))
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
                    val candidate = runAttempt(
                        RecognitionRequest(word),
                        WORD_RENDER_STYLE,
                        1,
                        "word",
                    )
                    if (candidate == null) {
                        completeWordResult = false
                        break@wordLoop
                    }
                    recognizedWords += candidate.copy(
                        text = candidate.text.replace(WHITESPACE, " ").trim(),
                    )
                }
                if (recognizedWords.size == words.size) {
                    recognizedLines += combineWordCandidates(recognizedWords)
                }
            }
            if (completeWordResult && recognizedLines.size == wordsByLine.size) {
                candidates += combineLineCandidates(recognizedLines)
            }
        }

        // Expensive scale extremes are recovery profiles, not the default
        // path. They remain useful for unusually small or broad board writing.
        var best = chooseBestCandidate(
            candidates,
            expectedLineCount = lines.size,
            expectedWordCount = expectedWordCount,
        )
        if (!timedOut &&
            (best == null ||
                !candidateIsAcceptable(
                    best,
                    candidates = candidates,
                    expectedLineCount = lines.size,
                    expectedWordCount = expectedWordCount,
                ))
        ) {
            for (style in RECOVERY_RENDER_STYLES) {
                runAttempt(
                    normalizedRequest,
                    style,
                    lineCountHint,
                    "recovery raster",
                )?.let(candidates::add)
                best = chooseBestCandidate(
                    candidates,
                    expectedLineCount = lines.size,
                    expectedWordCount = expectedWordCount,
                )
                if (best != null &&
                    candidateIsAcceptable(
                        best,
                        candidates = candidates,
                        expectedLineCount = lines.size,
                        expectedWordCount = expectedWordCount,
                    )
                ) {
                    break
                }
                if (timedOut) break
            }
        }

        // The highest raw score is not necessarily the best safe result. A
        // slightly lower-scoring line/word-segmented candidate carries real
        // geometric evidence and must not be hidden by a direct OCR guess.
        val candidate = chooseBestCandidate(
            candidates.filter {
                candidateIsAcceptable(
                    it,
                    candidates = candidates,
                    expectedLineCount = lines.size,
                    expectedWordCount = expectedWordCount,
                )
            },
            expectedLineCount = lines.size,
            expectedWordCount = expectedWordCount,
        )
        val durationMillis = TimeUnit.NANOSECONDS
            .toMillis(System.nanoTime() - startedNanos)
            .coerceIn(0L, Int.MAX_VALUE.toLong())
            .toInt()
        if (candidate != null) {
            return RecognitionOutcome(
                candidate = candidate,
                attemptCount = attempts,
                lineCountHint = lines.size,
                wordCountHint = expectedWordCount,
                durationMillis = durationMillis,
                timedOut = timedOut,
            )
        }
        // A deadline on a slow first invocation is an ordinary absence of a
        // candidate, not malformed handwriting. Only propagate a real engine
        // error when not one native attempt completed successfully.
        if (!completedAttempt && lastFailure != null && lastFailure !is TimeoutException) {
            throw lastFailure
        }
        return RecognitionOutcome(
            candidate = null,
            attemptCount = attempts,
            lineCountHint = lines.size,
            wordCountHint = expectedWordCount,
            durationMillis = durationMillis,
            timedOut = timedOut,
        )
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
            rethrowVirtualMachineError(error)
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
        synchronized(nativeTaskMonitor) {
            nativeTaskMonitor.notifyAll()
        }
        if (disposed) closeRecognizerWhenIdle()
    }

    private fun releasePendingRequest() {
        val remaining = pendingRequests.decrementAndGet()
        if (remaining < 0) {
            pendingRequests.set(0)
            Log.e(TAG, "Pending handwriting request accounting became negative")
        }
        if (disposed && remaining <= 0) closeRecognizerWhenIdle()
    }

    private fun awaitNativeTasksIdle(timeoutSeconds: Long): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        synchronized(nativeTaskMonitor) {
            while (activeNativeTasks.get() > 0 && !disposed) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) return false
                try {
                    TimeUnit.NANOSECONDS.timedWait(nativeTaskMonitor, remaining)
                } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return activeNativeTasks.get() == 0 && !disposed
    }

    private fun rethrowVirtualMachineError(error: Throwable) {
        var current: Throwable? = error
        repeat(MAX_FATAL_CAUSE_DEPTH) {
            val candidate = current ?: return
            if (candidate is VirtualMachineError) throw candidate
            val cause = candidate.cause
            if (cause == null || cause === candidate) return
            current = cause
        }
    }

    private fun closeRecognizerWhenIdle() {
        if (activeNativeTasks.get() != 0 ||
            pendingRequests.get() != 0 ||
            !recognizerClosed.compareAndSet(false, true)
        ) return
        val localFallback = synchronized(fallbackRecognizerLock) {
            fallbackRecognizer.also { fallbackRecognizer = null }
        }
        localFallback?.let(::closeFallbackRecognizer)
        val localPaddle = paddleRecognizer
        paddleRecognizer = null
        runCatching { localPaddle?.close() }
            .onFailure { error ->
                rethrowVirtualMachineError(error)
                Log.w(TAG, "Could not close PP-OCRv5 recognizer", error)
            }
    }

    private fun closeFallbackRecognizer(recognizer: TextRecognizer) {
        try {
            recognizer.close()
        } catch (error: VirtualMachineError) {
            throw error
        } catch (error: ExceptionInInitializerError) {
            rethrowVirtualMachineError(error)
            Log.w(TAG, "Could not close bundled Latin fallback", error)
        } catch (error: LinkageError) {
            rethrowVirtualMachineError(error)
            Log.w(TAG, "Could not unlink bundled Latin fallback", error)
        } catch (error: Exception) {
            rethrowVirtualMachineError(error)
            Log.w(TAG, "Could not close bundled Latin fallback", error)
        }
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
            layoutFidelity = 0.0,
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
        val text = lines.joinToString("\n") {
            it.text.replace(WHITESPACE, " ").trim()
        }
        return OcrCandidate(
            text = text,
            confidence = if (confidenceWeight == 0) {
                null
            } else {
                (confidenceTotal / confidenceWeight).coerceIn(0.0, 1.0)
            },
            quality = candidateTextQuality(text),
            layoutFidelity = 1.0,
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
            layoutFidelity = 1.0,
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
                candidateScore(
                    candidate = it,
                    candidates = candidates,
                    agreement = agreement,
                    expectedLineCount = expectedLineCount,
                    expectedWordCount = expectedWordCount,
                )
            }.thenBy { it.confidence ?: UNKNOWN_CONFIDENCE }
                .thenBy { it.text.count(Char::isLetterOrDigit) },
        )
    }

    private fun candidateScore(
        candidate: OcrCandidate,
        candidates: List<OcrCandidate>,
        agreement: Map<String, Int> =
            candidates.groupingBy { canonicalCandidate(it.text) }.eachCount(),
        expectedLineCount: Int? = null,
        expectedWordCount: Int? = null,
    ): Double {
        val repetitions = agreement[canonicalCandidate(candidate.text)] ?: 1
        val confidence = candidate.confidence ?: UNKNOWN_CONFIDENCE
        val consensus = candidates
            .asSequence()
            .filter { other -> other !== candidate }
            .map { other -> candidateSimilarity(candidate.text, other.text) }
            .averageOrZero()
        val lineLayout = expectedLineCount?.let { expected ->
            countSimilarity(candidate.text.lines().size, expected)
        } ?: 0.0
        val wordLayout = expectedWordCount?.let { expected ->
            val actual = candidate.text
                .split(WHITESPACE)
                .count { word -> word.isNotBlank() }
            countSimilarity(actual, expected)
        } ?: 0.0
        return confidence * CONFIDENCE_WEIGHT +
            candidate.quality * QUALITY_WEIGHT +
            min(MAX_AGREEMENT_BONUS, (repetitions - 1) * AGREEMENT_BONUS) +
            consensus * CONSENSUS_WEIGHT +
            lineLayout * LINE_LAYOUT_WEIGHT +
            wordLayout * WORD_LAYOUT_WEIGHT +
            candidate.layoutFidelity * GEOMETRY_LAYOUT_WEIGHT
    }

    private fun candidateLooksReliable(
        candidate: OcrCandidate,
        expectedLineCount: Int,
        expectedWordCount: Int,
    ): Boolean {
        val actualWords = candidate.text
            .split(WHITESPACE)
            .count { it.isNotBlank() }
        return candidate.quality >= RELIABLE_TEXT_QUALITY &&
            (candidate.confidence ?: 0.0) >= RELIABLE_CONFIDENCE &&
            (candidate.layoutFidelity >= 1.0 ||
                (candidate.text.lines().size == expectedLineCount &&
                    actualWords == expectedWordCount))
    }

    private fun candidateIsAcceptable(
        candidate: OcrCandidate,
        candidates: List<OcrCandidate>,
        expectedLineCount: Int,
        expectedWordCount: Int,
    ): Boolean {
        if (candidate.text.none(Char::isLetterOrDigit) ||
            candidate.quality < MINIMUM_TEXT_QUALITY
        ) {
            return false
        }
        val strongestAgreement = candidates
            .asSequence()
            .filter { it !== candidate }
            .map { candidateSimilarity(candidate.text, it.text) }
            .maxOrNull() ?: 0.0
        val confidence = candidate.confidence
        val directSingleWordLayoutMatches =
            expectedLineCount == 1 &&
                expectedWordCount == 1 &&
                candidate.text.lines().size == 1 &&
                candidate.text.split(WHITESPACE).count { it.isNotBlank() } == 1
        if (confidence != null &&
            confidence >= VERIFIED_SINGLE_WORD_CONFIDENCE &&
            directSingleWordLayoutMatches
        ) {
            return true
        }
        if (confidence != null &&
            confidence >= HIGH_CONFIDENCE_ACCEPTANCE &&
            (candidate.layoutFidelity >= 1.0 ||
                strongestAgreement >= HIGH_CONFIDENCE_MINIMUM_AGREEMENT)
        ) {
            return true
        }
        if (candidate.layoutFidelity >= 1.0 &&
            confidence != null &&
            confidence >= SEGMENTED_CONFIDENCE_ACCEPTANCE &&
            strongestAgreement >= SEGMENTED_MINIMUM_AGREEMENT
        ) {
            return true
        }
        val score = candidateScore(
            candidate = candidate,
            candidates = candidates,
            expectedLineCount = expectedLineCount,
            expectedWordCount = expectedWordCount,
        )
        return strongestAgreement >= MINIMUM_CANDIDATE_AGREEMENT &&
            score >= MINIMUM_CANDIDATE_SCORE
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
        val strokes = ArrayList<List<HandwritingInkPoint>>(rawStrokes.size)
        rawStrokes.forEach { rawStroke ->
            val stroke = rawStroke as? Map<*, *>
                ?: throw ChannelException("invalid_ink", "Ein Strich ist ungültig.")
            val rawCompactCoordinates = stroke["coordinates"]
            if (rawCompactCoordinates != null ||
                stroke.containsKey("coordinates")
            ) {
                val coordinates = rawCompactCoordinates as? FloatArray
                    ?: throw ChannelException(
                        "invalid_ink",
                        "Kompakte Strichkoordinaten sind ungültig.",
                    )
                if (coordinates.size % 2 != 0) {
                    throw ChannelException(
                        "invalid_ink",
                        "Kompakte Strichkoordinaten sind unvollständig.",
                    )
                }
                val pointCount = coordinates.size / 2
                if (pointCount == 0) return@forEach
                if (pointCount > MAX_POINTS - totalPoints) {
                    throw ChannelException(
                        "invalid_ink",
                        "Zu viele Handschriftpunkte.",
                    )
                }
                val timestamps = when (val raw = stroke["timestampsMicros"]) {
                    null -> null
                    is LongArray -> raw
                    else -> throw ChannelException(
                        "invalid_ink",
                        "Kompakte Zeitstempel sind ungültig.",
                    )
                }
                if (timestamps != null && timestamps.size != pointCount) {
                    throw ChannelException(
                        "invalid_ink",
                        "Koordinaten und Zeitstempel haben unterschiedliche Längen.",
                    )
                }
                val compactPoints = List(pointCount) { index ->
                    HandwritingInkPoint(
                        x = finiteCoordinate(coordinates[index * 2], "x"),
                        y = finiteCoordinate(coordinates[index * 2 + 1], "y"),
                        timestampMicros =
                            timestamps?.get(index)?.let(::optionalTimestamp),
                    )
                }
                strokes += compactPoints
                totalPoints += compactPoints.size
                return@forEach
            }

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
                HandwritingInkPoint(
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
        // MAX_BITMAP_SIZE is a memory ceiling, not a crop instruction. Include
        // padding in the scale budget so broad board writing remains complete
        // when the defensive bitmap limit is lowered.
        val maximumBitmapContent = max(
            1f,
            MAX_BITMAP_SIZE - renderStyle.padding * 2f,
        )
        val maximumBitmapScale = min(
            maximumBitmapContent / inkWidth,
            maximumBitmapContent / inkHeight,
        )
        scale = min(scale, maximumBitmapScale).coerceAtMost(MAX_SCALE)
        scale = max(scale, min(MIN_SCALE, maximumBitmapScale))

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
            rethrowVirtualMachineError(error)
            throw error
        }
    }

    /**
     * Normalizes very dense SMART Board packets after world-to-raster scaling.
     * This makes OCR input independent of a panel's sampling rate and caps path
     * commands while retaining both endpoints and every meaningful turn.
     */
    private fun rasterPoints(
        source: List<HandwritingInkPoint>,
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
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private data class RasterPoint(val x: Float, val y: Float)
    private data class RecognitionRequest(
        val strokes: List<List<HandwritingInkPoint>>,
    )
    private data class RecognitionOutcome(
        val candidate: OcrCandidate?,
        val attemptCount: Int,
        val lineCountHint: Int,
        val wordCountHint: Int,
        val durationMillis: Int,
        val timedOut: Boolean,
    )
    private data class OcrCandidate(
        val text: String,
        val confidence: Double?,
        val quality: Double,
        val layoutFidelity: Double,
    )
    private data class RenderStyle(
        val targetLineHeight: Float,
        val maximumInkWidth: Float,
        val padding: Float,
        val strokeWidth: Float,
        val smoothPath: Boolean = true,
    )

    private class ChannelException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/handwriting_recognition"
        const val DEFAULT_LANGUAGE_TAG = "de-DE"
        const val TAG = "FlowboardHandwriting"
        const val ENGINE_NAME = "bundledPaddleOcrV5WithLatinOcrFallback"
        const val MODEL_DELIVERY = "bundled-apk"
        const val MAX_LANGUAGE_TAG_LENGTH = 64
        const val MAX_STROKES = 4_096
        const val MAX_POINTS = 20_000
        const val MAX_FATAL_CAUSE_DEPTH = 8
        const val MAX_ABSOLUTE_COORDINATE = 10_000_000.0
        const val MAX_TIMESTAMP_MICROS = 9_000_000_000_000_000.0
        const val MAX_RASTER_POINTS_PER_STROKE = 12_000
        const val MIN_RASTER_POINT_DISTANCE = 0.35f
        const val MIN_INK_EXTENT = 1f
        const val MAX_INK_HEIGHT = 1_000f
        const val MIN_SCALE = 0.05f
        const val MAX_SCALE = 64f
        const val MIN_BITMAP_SIZE = 128
        const val MAX_BITMAP_SIZE = 1_536
        const val MAX_PENDING_REQUESTS = 1
        const val NATIVE_DRAIN_TIMEOUT_SECONDS = 8L
        // Cold inference is part of the first real queued request. It no longer
        // races a speculative warm-up, so this full budget is deterministic.
        const val RECOGNITION_TIMEOUT_SECONDS = 18L
        const val MAX_LINE_FALLBACKS = 6
        const val MAX_WORD_FALLBACKS = 16
        const val UNKNOWN_CONFIDENCE = 0.40
        const val CONFIDENCE_WEIGHT = 0.44
        const val QUALITY_WEIGHT = 0.16
        const val CONSENSUS_WEIGHT = 0.16
        const val LINE_LAYOUT_WEIGHT = 0.08
        const val WORD_LAYOUT_WEIGHT = 0.07
        const val GEOMETRY_LAYOUT_WEIGHT = 0.10
        const val AGREEMENT_BONUS = 0.08
        const val MAX_AGREEMENT_BONUS = 0.16
        const val RELIABLE_CONFIDENCE = 0.72
        const val RELIABLE_TEXT_QUALITY = 0.65
        const val MINIMUM_TEXT_QUALITY = 0.48
        const val HIGH_CONFIDENCE_ACCEPTANCE = 0.82
        const val VERIFIED_SINGLE_WORD_CONFIDENCE = 0.84
        const val HIGH_CONFIDENCE_MINIMUM_AGREEMENT = 0.30
        const val SEGMENTED_CONFIDENCE_ACCEPTANCE = 0.62
        const val SEGMENTED_MINIMUM_AGREEMENT = 0.42
        const val MINIMUM_CANDIDATE_AGREEMENT = 0.50
        const val MINIMUM_CANDIDATE_SCORE = 0.48
        val DIRECT_EXECUTOR = Executor { command -> command.run() }
        val PRIMARY_RENDER_STYLES = listOf(
            RenderStyle(112f, 1_900f, 30f, 7f),
            RenderStyle(96f, 1_900f, 28f, 3.25f, smoothPath = false),
        )
        val RECOVERY_RENDER_STYLES = listOf(
            RenderStyle(76f, 1_900f, 24f, 5f),
            RenderStyle(176f, 1_900f, 40f, 10.5f),
        )
        val LINE_RENDER_STYLE = RenderStyle(128f, 1_900f, 32f, 8f)
        val WORD_RENDER_STYLE = RenderStyle(144f, 1_500f, 34f, 7f)
        val PADDLE_RENDER_STYLES = listOf(
            RenderStyle(112f, 1_900f, 24f, 7f),
            RenderStyle(96f, 1_700f, 26f, 4.5f, smoothPath = false),
        )
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
