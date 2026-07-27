package de.flowboardx.flowboard_x

/**
 * Pure decision policy for accepting raster handwriting recognition.
 *
 * Keeping these thresholds outside the Android/ORT adapter makes it possible
 * to test the important "no confident-looking single guess" contract on the
 * local JVM without loading native libraries.
 */
internal object PaddleCandidatePolicy {
    fun isStrongStandalone(
        text: String,
        confidence: Double?,
        quality: Double,
        expectedLineCount: Int,
        expectedWordCount: Int,
    ): Boolean {
        val actualLineCount = text.lines().count { it.isNotBlank() }
        val actualWordCount = text
            .split(WHITESPACE)
            .count { it.isNotBlank() }
        return confidence != null &&
            confidence >= STANDALONE_CONFIDENCE &&
            quality >= STANDALONE_QUALITY &&
            actualLineCount == expectedLineCount &&
            (expectedWordCount <= 0 || actualWordCount == expectedWordCount)
    }

    fun hasIndependentRasterConsensus(
        firstConfidence: Double?,
        firstQuality: Double,
        secondConfidence: Double?,
        secondQuality: Double,
        similarity: Double,
    ): Boolean = firstConfidence != null &&
        secondConfidence != null &&
        firstConfidence >= CONSENSUS_CONFIDENCE &&
        secondConfidence >= CONSENSUS_CONFIDENCE &&
        firstQuality >= CONSENSUS_QUALITY &&
        secondQuality >= CONSENSUS_QUALITY &&
        similarity >= MINIMUM_RASTER_SIMILARITY

    private const val STANDALONE_CONFIDENCE = 0.94
    private const val STANDALONE_QUALITY = 0.72
    private const val CONSENSUS_CONFIDENCE = 0.60
    private const val CONSENSUS_QUALITY = 0.60
    private const val MINIMUM_RASTER_SIMILARITY = 0.82
    private val WHITESPACE = Regex("\\s+")
}

/**
 * LinkageError is not an Exception. Native optional features therefore catch
 * the expected linkage/initialization failures explicitly while fatal
 * VirtualMachineErrors always escape instead of triggering more allocations.
 */
internal object OptionalNativeEngine {
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
