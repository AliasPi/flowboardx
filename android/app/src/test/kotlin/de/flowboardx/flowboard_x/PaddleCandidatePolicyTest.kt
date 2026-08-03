package de.flowboardx.flowboard_x

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
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
    fun optionalNativeEngineNeverContainsVirtualMachineErrors() {
        val fatal = OutOfMemoryError("native OCR memory exhausted")

        try {
            OptionalNativeEngine.create<Any>(
                onFailure = { fail("A fatal VM error must not become a fallback") },
            ) {
                throw fatal
            }
            fail("Expected the original fatal VM error")
        } catch (actual: OutOfMemoryError) {
            assertSame(fatal, actual)
        }
    }

    @Test
    fun moderateSingleRasterIsNeverStrongStandaloneEvidence() {
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Tafelbild",
                confidence = .97,
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
                confidence = .99,
                quality = .96,
                expectedLineCount = 1,
                expectedWordCount = 2,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Guten Morgen",
                confidence = .99,
                quality = .96,
                expectedLineCount = 1,
                expectedWordCount = 3,
            ),
        )
    }

    @Test
    fun correlatedPaddleRasterProfilesNeverCountAsIndependentConsensus() {
        @Suppress("DEPRECATION")
        assertFalse(
            PaddleCandidatePolicy.hasIndependentRasterConsensus(
                firstConfidence = 1.0,
                firstQuality = 1.0,
                secondConfidence = 1.0,
                secondQuality = 1.0,
                similarity = 1.0,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.hasIndependentEngineConsensus(
                firstBackend = HandwritingRecognitionBackend.PADDLE_OCR,
                firstConfidence = 1.0,
                firstQuality = 1.0,
                secondBackend = HandwritingRecognitionBackend.PADDLE_OCR,
                secondConfidence = 1.0,
                secondQuality = 1.0,
                similarity = 1.0,
            ),
        )
    }

    @Test
    fun independentEngineConsensusRequiresTwoUsableSimilarCandidates() {
        assertTrue(
            PaddleCandidatePolicy.hasIndependentEngineConsensus(
                firstBackend = HandwritingRecognitionBackend.PADDLE_OCR,
                firstConfidence = .86,
                firstQuality = .94,
                secondBackend = HandwritingRecognitionBackend.ML_KIT_LATIN_OCR,
                secondConfidence = .83,
                secondQuality = .91,
                similarity = .94,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.hasIndependentEngineConsensus(
                firstBackend = HandwritingRecognitionBackend.PADDLE_OCR,
                firstConfidence = .84,
                firstQuality = 1.0,
                secondBackend = HandwritingRecognitionBackend.ML_KIT_LATIN_OCR,
                secondConfidence = .41,
                secondQuality = .9,
                similarity = .97,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.hasIndependentEngineConsensus(
                firstBackend = HandwritingRecognitionBackend.PADDLE_OCR,
                firstConfidence = .84,
                firstQuality = 1.0,
                secondBackend = HandwritingRecognitionBackend.ML_KIT_LATIN_OCR,
                secondConfidence = .81,
                secondQuality = .9,
                similarity = .89,
            ),
        )
    }

    @Test
    fun standaloneEvidenceRejectsTinyAndMalformedCandidates() {
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "I",
                confidence = 1.0,
                quality = 1.0,
                expectedLineCount = 1,
                expectedWordCount = 1,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Hallo",
                confidence = Double.NaN,
                quality = 1.0,
                expectedLineCount = 1,
                expectedWordCount = 1,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isStrongStandalone(
                text = "Hallo\u0000",
                confidence = 1.0,
                quality = 1.0,
                expectedLineCount = 1,
                expectedWordCount = 1,
            ),
        )
    }

    @Test
    fun meaningfulLineSegmentationCanSupportPlausibleBroadCandidate() {
        assertTrue(
            PaddleCandidatePolicy.isPlausibleSegmentedCandidate(
                text = "Guten Morgen\nKlasse 7",
                confidence = .82,
                quality = .94,
                expectedLineCount = 2,
                expectedWordCount = 4,
                evidence = CandidateSegmentationEvidence.LINES,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isPlausibleSegmentedCandidate(
                text = "Guten Morgen",
                confidence = .82,
                quality = .94,
                expectedLineCount = 1,
                expectedWordCount = 2,
                evidence = CandidateSegmentationEvidence.LINES,
            ),
        )
    }

    @Test
    fun meaningfulWordSegmentationRequiresTheCompleteExpectedLayout() {
        assertTrue(
            PaddleCandidatePolicy.isPlausibleSegmentedCandidate(
                text = "Tafel Bild",
                confidence = .79,
                quality = .91,
                expectedLineCount = 1,
                expectedWordCount = 2,
                evidence = CandidateSegmentationEvidence.WORDS,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isPlausibleSegmentedCandidate(
                text = "Tafel",
                confidence = .91,
                quality = .97,
                expectedLineCount = 1,
                expectedWordCount = 2,
                evidence = CandidateSegmentationEvidence.WORDS,
            ),
        )
        assertFalse(
            PaddleCandidatePolicy.isPlausibleSegmentedCandidate(
                text = "Tafel Bild",
                confidence = .79,
                quality = .91,
                expectedLineCount = 1,
                expectedWordCount = 2,
                evidence = CandidateSegmentationEvidence.NONE,
            ),
        )
    }
}
