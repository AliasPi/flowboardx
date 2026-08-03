package de.flowboardx.flowboard_x

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PalmTraceDecisionTest {
    @Test
    fun nativePalmDuringStylusWritingNeverErases() {
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = true,
                explicitNativePalm = true,
                canceledBySystem = true,
                hasCancellationEvidence = true,
                pathLengthDp = 120.0,
                displacementDp = 80.0,
            ),
        )
    }

    @Test
    fun stationaryPalmNeverErasesWithoutStylus() {
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = false,
                explicitNativePalm = true,
                canceledBySystem = true,
                hasCancellationEvidence = true,
                pathLengthDp = 2.0,
                displacementDp = 1.0,
            ),
        )
    }

    @Test
    fun movingFistEraserRemainsAvailableWithoutStylus() {
        assertTrue(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = false,
                explicitNativePalm = true,
                canceledBySystem = false,
                hasCancellationEvidence = true,
                pathLengthDp = 45.0,
                displacementDp = 30.0,
            ),
        )
    }

    @Test
    fun ordinaryCanceledTouchWithoutPalmEvidenceIsNotEraser() {
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = false,
                explicitNativePalm = false,
                canceledBySystem = true,
                hasCancellationEvidence = false,
                pathLengthDp = 45.0,
                displacementDp = 30.0,
            ),
        )
    }

    @Test
    fun movingCanceledSmartboardFingersWithPressureOneNeverErase() {
        val evidence = PalmContactEvidence.isStrongEraserEvidence(
            compactMultiContact = false,
        )
        assertFalse(evidence)
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = false,
                explicitNativePalm = false,
                canceledBySystem = true,
                hasCancellationEvidence = evidence,
                pathLengthDp = 240.0,
                displacementDp = 180.0,
            ),
        )
    }

    @Test
    fun pinnedSizeAloneNeverEnablesDestructiveReplay() {
        val evidence = PalmContactEvidence.isStrongEraserEvidence(
            compactMultiContact = false,
        )

        assertFalse(evidence)
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = false,
                explicitNativePalm = false,
                canceledBySystem = true,
                hasCancellationEvidence = evidence,
                pathLengthDp = 80.0,
                displacementDp = 60.0,
            ),
        )
    }

    @Test
    fun broadCanceledSingleFingerNeverEnablesDestructiveReplay() {
        val evidence = PalmContactEvidence.isStrongEraserEvidence(
            compactMultiContact = false,
        )

        assertFalse(evidence)
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = false,
                explicitNativePalm = false,
                canceledBySystem = true,
                hasCancellationEvidence = evidence,
                pathLengthDp = 80.0,
                displacementDp = 60.0,
            ),
        )
    }

    @Test
    fun threeCompactContactsRemainIndependentPalmEvidence() {
        assertTrue(
            PalmContactEvidence.isStrongEraserEvidence(
                compactMultiContact = true,
            ),
        )
    }
}
