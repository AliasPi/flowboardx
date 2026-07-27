package de.flowboardx.flowboard_x

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PaddleCandidatePolicyTest {
    @Test
    fun optionalNativeEngineContainsLinkageErrors() {
        var captured: Throwable? = null

        val engine = OptionalNativeEngine.create<Any>(
            onFailure = { captured = it },
        ) {
            throw UnsatisfiedLinkError("vendor linker namespace")
        }

        assertNull(engine)
        assertTrue(captured is UnsatisfiedLinkError)
    }

    @Test
    fun moderateSingleRasterIsNeverStrongStandaloneEvidence() {
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Tafelbild",
                confidence = .82,
                quality = 1.0,
                expectedLineCount = 1,
                expectedWordCount = 1,
            ),
        )
    }

    @Test
    fun strongStandaloneMustAlsoMatchGeometricLayout() {
        assertTrue(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Guten Morgen",
                confidence = .97,
                quality = 1.0,
                expectedLineCount = 1,
                expectedWordCount = 2,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Guten Morgen",
                confidence = .97,
                quality = 1.0,
                expectedLineCount = 1,
                expectedWordCount = 3,
            ),
        )
    }

    @Test
    fun rasterConsensusRequiresTwoUsableCandidatesAndHighSimilarity() {
        assertTrue(
            PaddleCandidatePolicy.hasIndependentRasterConsensus(
                firstConfidence = .84,
                firstQuality = 1.0,
                secondConfidence = .81,
                secondQuality = .9,
                similarity = .91,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.hasIndependentRasterConsensus(
                firstConfidence = .84,
                firstQuality = 1.0,
                secondConfidence = .41,
                secondQuality = .9,
                similarity = .97,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.hasIndependentRasterConsensus(
                firstConfidence = .84,
                firstQuality = 1.0,
                secondConfidence = .81,
                secondQuality = .9,
                similarity = .50,
            ),
        )
    }
}
