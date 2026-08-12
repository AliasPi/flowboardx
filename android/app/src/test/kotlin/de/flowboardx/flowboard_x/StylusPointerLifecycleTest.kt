package de.flowboardx.flowboard_x

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StylusPointerLifecycleTest {
    private val lifecycle = StylusPointerLifecycle<String>()

    @Test
    fun secondFingerReportedAsStylusIsLatchedAsAmbiguous() {
        assertFalse(
            lifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 100L,
                pointerId = 2,
                key = "misreported-second-finger",
                hasExistingFinger = true,
            ),
        )

        assertTrue(lifecycle.isAmbiguous(7, 100L, 2))
        assertFalse(
            lifecycle.canForwardReportedStylusSample(7, 100L, 2),
        )
    }

    @Test
    fun ambiguousPointerStaysBlockedAcrossToolTypeChangesUntilUp() {
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 2,
            key = "misreported-second-finger",
            hasExistingFinger = true,
        )

        // The caller only asks this on samples currently reported as stylus.
        // A FINGER sample does not clear the latch, so a later STYLUS sample
        // from the same pointer lifetime is still rejected.
        assertFalse(
            lifecycle.canForwardReportedStylusSample(7, 100L, 2),
        )
        assertFalse(
            lifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 100L,
                pointerId = 2,
                key = "same-pointer-after-tool-type-change",
                hasExistingFinger = false,
            ),
        )
        assertNull(lifecycle.finishPointer(7, 100L, 2))
        assertFalse(lifecycle.isAmbiguous(7, 100L, 2))

        assertTrue(
            lifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 200L,
                pointerId = 2,
                key = "real-stylus-in-new-stream",
                hasExistingFinger = false,
            ),
        )
    }

    @Test
    fun realStylusIsReturnedForCleanupRegardlessOfUpToolType() {
        assertTrue(
            lifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 100L,
                pointerId = 3,
                key = "real-stylus",
                hasExistingFinger = false,
            ),
        )
        assertTrue(
            lifecycle.canForwardReportedStylusSample(7, 100L, 3),
        )

        // finishPointer intentionally has no current-tool-type argument.
        assertEquals(
            "real-stylus",
            lifecycle.finishPointer(7, 100L, 3),
        )
        assertFalse(
            lifecycle.canForwardReportedStylusSample(7, 100L, 3),
        )
        assertNull(lifecycle.finishPointer(7, 100L, 3))
    }

    @Test
    fun malformedDuplicateDownCannotReclassifyForwardedStylus() {
        assertTrue(
            lifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 100L,
                pointerId = 3,
                key = "real-stylus",
                hasExistingFinger = false,
            ),
        )

        assertTrue(
            lifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 100L,
                pointerId = 3,
                key = "duplicate-key-must-not-replace-original",
                hasExistingFinger = true,
            ),
        )
        assertFalse(lifecycle.isAmbiguous(7, 100L, 3))
        assertEquals(
            "real-stylus",
            lifecycle.finishPointer(7, 100L, 3),
        )
    }

    @Test
    fun toolTypeIndependentCleanupPreventsThirtySecondGhostStylus() {
        val guard = StylusPalmGuard(
            protectionRadiusDp = 300.0,
            releaseGraceMillis = 0L,
        )
        val guardKey = StylusPalmGuard.PointerKey(
            deviceId = 7,
            pointerId = 3,
        )
        val guardLifecycle =
            StylusPointerLifecycle<StylusPalmGuard.PointerKey>()
        assertTrue(
            guardLifecycle.registerReportedStylusDown(
                deviceId = 7,
                downTimeMillis = 100L,
                pointerId = 3,
                key = guardKey,
                hasExistingFinger = false,
            ),
        )
        guard.stylusDown(guardKey, 500.0, 500.0, 100L)
        assertTrue(guard.isStylusNear(500.0, 500.0, 101L))

        // The terminal packet may now say FINGER. Cleanup uses only the
        // pointer lifetime recorded at stylusDown, not that current tool type.
        val endedKey = checkNotNull(
            guardLifecycle.finishPointer(7, 100L, 3),
        )
        guard.stylusUp(endedKey, null, 110L)

        assertFalse(guard.isStylusNear(500.0, 500.0, 111L))
    }

    @Test
    fun cancelCleansEveryForwardedStylusAndAmbiguousMarkerInStream() {
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 1,
            key = "pen-one",
            hasExistingFinger = false,
        )
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 2,
            key = "pen-two",
            hasExistingFinger = false,
        )
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 3,
            key = "ambiguous-finger",
            hasExistingFinger = true,
        )

        assertEquals(
            setOf("pen-one", "pen-two"),
            lifecycle.finishStream(7, 100L).toSet(),
        )
        assertFalse(lifecycle.isAmbiguous(7, 100L, 3))
        assertFalse(
            lifecycle.canForwardReportedStylusSample(7, 100L, 1),
        )
        assertFalse(
            lifecycle.canForwardReportedStylusSample(7, 100L, 2),
        )
    }

    @Test
    fun cancelDoesNotClearAnotherDevicesOrStreamsPointers() {
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 1,
            key = "ended-stream",
            hasExistingFinger = false,
        )
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 200L,
            pointerId = 1,
            key = "later-stream",
            hasExistingFinger = false,
        )
        lifecycle.registerReportedStylusDown(
            deviceId = 8,
            downTimeMillis = 100L,
            pointerId = 1,
            key = "other-device",
            hasExistingFinger = false,
        )

        assertEquals(
            listOf("ended-stream"),
            lifecycle.finishStream(7, 100L),
        )
        assertTrue(
            lifecycle.canForwardReportedStylusSample(7, 200L, 1),
        )
        assertTrue(
            lifecycle.canForwardReportedStylusSample(8, 100L, 1),
        )
    }

    @Test
    fun newStreamDropsOnlyStalePointersFromTheSameDevice() {
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 1,
            key = "stale-pen",
            hasExistingFinger = false,
        )
        lifecycle.registerReportedStylusDown(
            deviceId = 7,
            downTimeMillis = 100L,
            pointerId = 2,
            key = "stale-ambiguous",
            hasExistingFinger = true,
        )
        lifecycle.registerReportedStylusDown(
            deviceId = 8,
            downTimeMillis = 100L,
            pointerId = 1,
            key = "other-device",
            hasExistingFinger = false,
        )

        assertEquals(
            listOf("stale-pen"),
            lifecycle.beginStream(7, 200L),
        )
        assertFalse(lifecycle.isAmbiguous(7, 100L, 2))
        assertFalse(
            lifecycle.canForwardReportedStylusSample(7, 100L, 1),
        )
        assertTrue(
            lifecycle.canForwardReportedStylusSample(8, 100L, 1),
        )

        // A duplicate ACTION_DOWN for the same stream is idempotent.
        assertTrue(lifecycle.beginStream(8, 100L).isEmpty())
        assertTrue(
            lifecycle.canForwardReportedStylusSample(8, 100L, 1),
        )
    }
}
