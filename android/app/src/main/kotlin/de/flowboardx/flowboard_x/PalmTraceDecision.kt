package de.flowboardx.flowboard_x

/**
 * Final safety gate before a native Android palm trace is replayed as eraser.
 *
 * Android's cancellation signal identifies an interrupted touch, not the
 * user's intent to erase. Non-explicit contacts therefore require independent
 * broad-contact evidence as well as wipe movement. Every trace which
 * overlapped a live stylus protection zone is rejected.
 */
object PalmTraceDecision {
    fun shouldReplayAsEraser(
        overlappedStylusProtection: Boolean,
        explicitNativePalm: Boolean,
        canceledBySystem: Boolean,
        hasCancellationEvidence: Boolean,
        pathLengthDp: Double,
        displacementDp: Double,
    ): Boolean {
        if (overlappedStylusProtection) return false
        if (!explicitNativePalm &&
            !(canceledBySystem && hasCancellationEvidence)
        ) {
            return false
        }
        return pathLengthDp >= MIN_ERASE_PATH_LENGTH_DP ||
            displacementDp >= MIN_ERASE_DISPLACEMENT_DP
    }

    private const val MIN_ERASE_PATH_LENGTH_DP = 10.0
    private const val MIN_ERASE_DISPLACEMENT_DP = 6.0
}
