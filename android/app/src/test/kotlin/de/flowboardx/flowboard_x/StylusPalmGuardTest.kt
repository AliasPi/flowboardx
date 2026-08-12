package de.flowboardx.flowboard_x

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StylusPalmGuardTest {
    private val stylus = StylusPalmGuard.PointerKey(deviceId = 7, pointerId = 3)
    private val touch = StylusPalmGuard.TouchStreamKey(
        deviceId = 9,
        downTimeMillis = 120L,
    )

    @Test
    fun hoverProtectsNearbyPalmBeforePenTouchesSurface() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusHover(stylus, point(500.0, 500.0), 100L)

        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(710.0, 540.0)),
                120L,
            ),
        )
    }

    @Test
    fun activeStylusSuppressesBroadMultiContactPalmAsOneStream() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)

        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(
                    finger(620.0, 560.0),
                    finger(655.0, 585.0),
                    finger(600.0, 610.0),
                ),
                120L,
            ),
        )
    }

    @Test
    fun suppressedStreamRemainsSuppressedUntilItsEnd() {
        val guard = StylusPalmGuard(
            protectionRadiusDp = 300.0,
            releaseGraceMillis = 0L,
        )
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)
        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(530.0, 520.0)),
                120L,
            ),
        )

        guard.stylusUp(stylus, point(500.0, 500.0), 130L)
        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.CONTINUE,
                listOf(palm(800.0, 800.0)),
                500L,
            ),
        )
        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.END,
                listOf(palm(800.0, 800.0)),
                510L,
            ),
        )
        assertFalse(
            guard.shouldSuppressTouch(
                touch.copy(downTimeMillis = 600L),
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(530.0, 520.0)),
                600L,
            ),
        )
    }

    @Test
    fun continuationDoesNotReadOrReevaluateContactGeometry() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)
        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(530.0, 520.0)),
                120L,
            ),
        )
        val contactsThatMustNotBeRead =
            object : Iterable<StylusPalmGuard.TouchContact> {
                override fun iterator(): Iterator<StylusPalmGuard.TouchContact> =
                    throw AssertionError("MOVE must use the latched decision")
            }

        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.CONTINUE,
                contactsThatMustNotBeRead,
                130L,
            ),
        )
        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.END,
                contactsThatMustNotBeRead,
                140L,
            ),
        )
        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.CONTINUE,
                contactsThatMustNotBeRead,
                150L,
            ),
        )
    }

    @Test
    fun inPlaceStylusMoveUsesLatestProtectionPosition() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, 100.0, 100.0, 100L)
        guard.stylusMove(stylus, 1_000.0, 700.0, 110L)

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(120.0, 120.0)),
                120L,
            ),
        )
        assertTrue(
            guard.shouldSuppressTouch(
                touch.copy(downTimeMillis = 121L),
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(1_020.0, 720.0)),
                121L,
            ),
        )
    }

    @Test
    fun malformedStreamsCannotGrowSuppressionLatchWithoutBound() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)
        val streams = List(40) { index ->
            touch.copy(downTimeMillis = 200L + index)
        }
        for ((index, stream) in streams.withIndex()) {
            assertTrue(
                guard.shouldSuppressTouch(
                    stream,
                    StylusPalmGuard.TouchPhase.START,
                    listOf(palm(530.0, 520.0)),
                    200L + index,
                ),
            )
        }

        assertFalse(
            guard.shouldSuppressTouch(
                streams.first(),
                StylusPalmGuard.TouchPhase.CONTINUE,
                emptyList(),
                300L,
            ),
        )
        assertTrue(
            guard.shouldSuppressTouch(
                streams.last(),
                StylusPalmGuard.TouchPhase.CONTINUE,
                emptyList(),
                300L,
            ),
        )
    }

    @Test
    fun palmBeforeStylusIsNotConsumedMidStreamButCannotBecomeEraser() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(530.0, 520.0)),
                90L,
            ),
        )

        guard.stylusDown(stylus, point(500.0, 500.0), 100L)
        // Never start consuming halfway: Flutter must receive a balanced
        // CANCEL/UP instead of an orphaned pointer sequence.
        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.CONTINUE,
                listOf(palm(535.0, 525.0)),
                110L,
            ),
        )
        assertFalse(
            PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection = true,
                explicitNativePalm = true,
                canceledBySystem = true,
                hasCancellationEvidence = true,
                pathLengthDp = 80.0,
                displacementDp = 60.0,
            ),
        )
    }

    @Test
    fun farTouchForSecondBoardParticipantIsNotSuppressed() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(250.0, 500.0), 100L)

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(finger(1_400.0, 500.0)),
                120L,
            ),
        )
    }

    @Test
    fun staleHoverCannotDisableLaterFistEraserGesture() {
        val guard = StylusPalmGuard(
            protectionRadiusDp = 300.0,
            hoverTimeoutMillis = 500L,
            releaseGraceMillis = 100L,
        )
        guard.stylusHover(stylus, point(500.0, 500.0), 100L)

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(510.0, 510.0)),
                700L,
            ),
        )
    }

    @Test
    fun shortReleaseGraceCoversDriverHoverToDownGap() {
        val guard = StylusPalmGuard(
            protectionRadiusDp = 300.0,
            hoverTimeoutMillis = 500L,
            releaseGraceMillis = 220L,
        )
        guard.stylusHover(stylus, point(500.0, 500.0), 100L)
        guard.stylusHoverExit(stylus, point(500.0, 500.0), 110L)

        assertTrue(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(520.0, 500.0)),
                250L,
            ),
        )
    }

    @Test
    fun nearbyOrdinaryFingerRemainsAvailableWhilePenOnlyHovers() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusHover(stylus, point(500.0, 500.0), 100L)

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(finger(610.0, 550.0)),
                120L,
            ),
        )
    }

    @Test
    fun narrowSmartboardFingerNeverBecomesPalmEvidence() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(
                    StylusPalmGuard.TouchContact(
                        position = point(650.0, 520.0),
                        radiusMajorDp = 7.0,
                        radiusMinorDp = 5.0,
                        normalizedSize = 0.08,
                    ),
                ),
                120L,
            ),
        )
    }

    @Test
    fun borderlineFingerContactStaysBelowConservativePalmThreshold() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(
                    StylusPalmGuard.TouchContact(
                        position = point(650.0, 520.0),
                        radiusMajorDp = 11.5,
                        radiusMinorDp = 7.0,
                        normalizedSize = 0.19,
                    ),
                ),
                120L,
            ),
        )
    }

    @Test
    fun broadContactOutsideDirectionalPalmCorridorIsNotSuppressed() {
        val guard = StylusPalmGuard(protectionRadiusDp = 300.0)
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)

        // Protection reaches farther below the pen than above it. A broad
        // contact well above the writer belongs to another interaction zone.
        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(500.0, 280.0)),
                120L,
            ),
        )
    }

    @Test
    fun discardedStaleStylusCreatesNoReleaseProtection() {
        val guard = StylusPalmGuard(
            protectionRadiusDp = 300.0,
            releaseGraceMillis = 500L,
        )
        guard.stylusDown(stylus, point(500.0, 500.0), 100L)
        guard.discardStyluses(listOf(stylus))

        assertFalse(
            guard.shouldSuppressTouch(
                touch,
                StylusPalmGuard.TouchPhase.START,
                listOf(palm(520.0, 520.0)),
                101L,
            ),
        )
    }

    private fun point(x: Double, y: Double) =
        StylusPalmGuard.Position(xDp = x, yDp = y)

    private fun finger(x: Double, y: Double) =
        StylusPalmGuard.TouchContact(
            position = point(x, y),
            radiusMajorDp = 7.0,
            radiusMinorDp = 5.0,
            normalizedSize = 0.08,
        )

    private fun palm(x: Double, y: Double) =
        StylusPalmGuard.TouchContact(
            position = point(x, y),
            radiusMajorDp = 24.0,
            radiusMinorDp = 14.0,
            normalizedSize = 0.34,
        )
}
