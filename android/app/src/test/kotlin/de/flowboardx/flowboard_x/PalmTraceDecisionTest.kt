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
}
