package de.flowboardx.flowboard_x

/**
 * Native engines whose errors can provide genuinely independent evidence.
 *
 * Two render styles evaluated by the same engine intentionally have the same
 * identity. They are useful robustness probes, but their recognition errors
 * are correlated and must not be counted as two independent votes.
 */
enum class HandwritingRecognitionBackend {
    PADDLE_OCR,
    ML_KIT_LATIN_OCR,
}

/**
 * Geometry that was independently established before OCR was combined.
 */
enum class CandidateSegmentationEvidence {
    NONE,
    LINES,
    WORDS,
}

/**
 * Pure decision policy for accepting raster handwriting recognition.
 *
 * Keeping these thresholds outside the Android/ORT adapter makes it possible
 * to test the important "no confident-looking single guess" contract on the
 * local JVM without loading native libraries.
 */
object PaddleCandidatePolicy {
    fun isStrongStandalone(
        text: String,
        confidence: Double?,
        quality: Double,
        expectedLineCount: Int,
        expectedWordCount: Int,
    ): Boolean {
        val safeConfidence = confidence ?: return false
        val layout = candidateLayout(text)
        return validProbability(safeConfidence) &&
            validProbability(quality) &&
            safeConfidence >= STANDALONE_CONFIDENCE &&
            quality >= STANDALONE_QUALITY &&
            layout.alphaNumericCount >= MINIMUM_STANDALONE_CHARACTERS &&
            expectedLineCount > 0 &&
            expectedWordCount > 0 &&
            layout.lineCount == expectedLineCount &&
            layout.wordCount == expectedWordCount &&
            !layout.hasUnexpectedControlCharacter
    }

    /**
     * Compatibility boundary for callers which do not identify their engines.
     *
     * Without the engine identity there is no safe way to prove independence.
     * In particular, Paddle's smooth and sharp render profiles are correlated
     * observations from one model and deliberately return false here.
     */
    @Deprecated(
        message =
            "Raster profiles do not prove independence; use " +
                "hasIndependentEngineConsensus with explicit backends.",
    )
    fun hasIndependentRasterConsensus(
        firstConfidence: Double?,
        firstQuality: Double,
        secondConfidence: Double?,
        secondQuality: Double,
        similarity: Double,
    ): Boolean = false

    /**
     * Accepts corroboration only when two distinct native engines agree.
     */
    fun hasIndependentEngineConsensus(
        firstBackend: HandwritingRecognitionBackend,
        firstConfidence: Double?,
        firstQuality: Double,
        secondBackend: HandwritingRecognitionBackend,
        secondConfidence: Double?,
        secondQuality: Double,
        similarity: Double,
    ): Boolean {
        val safeFirstConfidence = firstConfidence ?: return false
        val safeSecondConfidence = secondConfidence ?: return false
        return firstBackend != secondBackend &&
            validProbability(safeFirstConfidence) &&
            validProbability(firstQuality) &&
            validProbability(safeSecondConfidence) &&
            validProbability(secondQuality) &&
            validProbability(similarity) &&
            safeFirstConfidence >= CONSENSUS_CONFIDENCE &&
            safeSecondConfidence >= CONSENSUS_CONFIDENCE &&
            firstQuality >= CONSENSUS_QUALITY &&
            secondQuality >= CONSENSUS_QUALITY &&
            similarity >= MINIMUM_RASTER_SIMILARITY
    }

    /**
     * Allows a somewhat broader candidate only when real spatial
     * segmentation supplied additional evidence that the complete selection
     * was retained. Merely labelling a single line or word as segmented is not
     * extra evidence.
     */
    fun isPlausibleSegmentedCandidate(
        text: String,
        confidence: Double?,
        quality: Double,
        expectedLineCount: Int,
        expectedWordCount: Int,
        evidence: CandidateSegmentationEvidence,
    ): Boolean {
        val safeConfidence = confidence ?: return false
        if (!validProbability(safeConfidence) ||
            !validProbability(quality) ||
            safeConfidence < SEGMENTED_CONFIDENCE ||
            quality < SEGMENTED_QUALITY ||
            expectedLineCount <= 0 ||
            expectedWordCount <= 0
        ) {
            return false
        }
        val layout = candidateLayout(text)
        if (layout.alphaNumericCount < MINIMUM_SEGMENTED_CHARACTERS ||
            layout.hasUnexpectedControlCharacter ||
            layout.lineCount != expectedLineCount ||
            layout.wordCount != expectedWordCount
        ) {
            return false
        }
        return when (evidence) {
            CandidateSegmentationEvidence.NONE -> false
            CandidateSegmentationEvidence.LINES -> expectedLineCount >= 2
            CandidateSegmentationEvidence.WORDS -> expectedWordCount >= 2
        }
    }

    private fun validProbability(value: Double): Boolean =
        value.isFinite() && value in 0.0..1.0

    private fun candidateLayout(text: String): CandidateLayout {
        val lines = text
            .lines()
            .map(String::trim)
            .filter(String::isNotEmpty)
        return CandidateLayout(
            lineCount = lines.size,
            wordCount = lines.sumOf { line ->
                line.split(WHITESPACE).count(String::isNotEmpty)
            },
            alphaNumericCount = text.count(Char::isLetterOrDigit),
            hasUnexpectedControlCharacter =
                text.any { character ->
                    character.isISOControl() &&
                        character != '\n' &&
                        character != '\r' &&
                        character != '\t'
                },
        )
    }

    private data class CandidateLayout(
        val lineCount: Int,
        val wordCount: Int,
        val alphaNumericCount: Int,
        val hasUnexpectedControlCharacter: Boolean,
    )

    private const val STANDALONE_CONFIDENCE = 0.98
    private const val STANDALONE_QUALITY = 0.90
    private const val MINIMUM_STANDALONE_CHARACTERS = 3
    private const val CONSENSUS_CONFIDENCE = 0.72
    private const val CONSENSUS_QUALITY = 0.78
    private const val MINIMUM_RASTER_SIMILARITY = 0.90
    private const val SEGMENTED_CONFIDENCE = 0.72
    private const val SEGMENTED_QUALITY = 0.82
    private const val MINIMUM_SEGMENTED_CHARACTERS = 2
    private val WHITESPACE = Regex("\\s+")
}

/**
 * LinkageError is not an Exception. Native optional features therefore catch
 * the expected linkage/initialization failures explicitly while fatal
 * VirtualMachineErrors always escape instead of triggering more allocations.
 */
object OptionalNativeEngine {
    fun <T> create(
        onFailure: (Throwable) -> Unit,
        factory: () -> T,
    ): T? = try {
        factory()
    } catch (error: VirtualMachineError) {
        throw error
    } catch (error: ExceptionInInitializerError) {
        rethrowVirtualMachineError(error)
        onFailure(error)
        null
    } catch (error: LinkageError) {
        rethrowVirtualMachineError(error)
        onFailure(error)
        null
    } catch (error: Exception) {
        rethrowVirtualMachineError(error)
        onFailure(error)
        null
    }

    private fun rethrowVirtualMachineError(error: Throwable) {
        var current: Throwable? = error
        repeat(8) {
            val candidate = current ?: return
            if (candidate is VirtualMachineError) throw candidate
            val cause = candidate.cause
            if (cause == null || cause === candidate) return
            current = cause
        }
    }
}
