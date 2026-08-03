package de.flowboardx.flowboard_x

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecognizedPalmFootprintPolicyTest {
    @Test
    fun trustedQuantizedPalmGetsUsefulPhysicalMinimum() {
        val footprint = resolve(
            radiusMajorDp = 12.0,
            radiusMinorDp = 7.0,
            normalizedSize = 0.10,
            normalizedPressure = 1.0,
            contactCount = 1,
        )

        assertEquals(44.0, footprint.radiusMajorDp, EPSILON)
        assertTrue(footprint.radiusMinorDp >= 24.0)
        assertTrue(footprint.radiusMajorDp > 12.0)
    }

    @Test
    fun pinnedSizeCannotOverrideShrinkingMeasuredTouchAxes() {
        val broad = resolve(
            radiusMajorDp = 60.0,
            radiusMinorDp = 30.0,
            normalizedSize = 1.0,
            normalizedPressure = 1.0,
            contactCount = 1,
        )
        val compact = resolve(
            radiusMajorDp = 12.0,
            radiusMinorDp = 7.0,
            normalizedSize = 1.0,
            normalizedPressure = 1.0,
            contactCount = 1,
        )

        assertTrue(broad.radiusMajorDp > 65.0)
        assertTrue(compact.radiusMajorDp < 55.0)
        assertTrue(compact.radiusMajorDp < broad.radiusMajorDp * 0.8)
    }

    @Test
    fun sizeRemainsFallbackWhenMeasuredTouchAxesAreMissing() {
        val compact = resolve(
            radiusMajorDp = 12.0,
            radiusMinorDp = 7.0,
            normalizedSize = 0.34,
            normalizedPressure = 0.0,
            contactCount = 1,
            hasMeasuredTouchAxes = false,
        )
        val broad = resolve(
            radiusMajorDp = 12.0,
            radiusMinorDp = 7.0,
            normalizedSize = 1.0,
            normalizedPressure = 0.0,
            contactCount = 1,
            hasMeasuredTouchAxes = false,
        )

        assertEquals(44.0, compact.radiusMajorDp, EPSILON)
        assertEquals(122.0, broad.radiusMajorDp, EPSILON)
    }

    @Test
    fun pressureCannotChangeFallbackWhenTouchAxesAreMissing() {
        val light = resolve(
            radiusMajorDp = 0.0,
            radiusMinorDp = 0.0,
            normalizedSize = 0.70,
            normalizedPressure = 0.0,
            contactCount = 1,
            hasMeasuredTouchAxes = false,
        )
        val pinnedPressure = resolve(
            radiusMajorDp = 0.0,
            radiusMinorDp = 0.0,
            normalizedSize = 0.70,
            normalizedPressure = 1.0,
            contactCount = 1,
            hasMeasuredTouchAxes = false,
        )

        assertEquals(light.radiusMajorDp, pinnedPressure.radiusMajorDp, EPSILON)
        assertEquals(light.radiusMinorDp, pinnedPressure.radiusMinorDp, EPSILON)
    }

    @Test
    fun splitFistContactCountExpandsQuantizedFootprint() {
        val single = resolve(
            radiusMajorDp = 12.0,
            radiusMinorDp = 7.0,
            normalizedSize = 0.10,
            normalizedPressure = 1.0,
            contactCount = 1,
            hasMeasuredTouchAxes = false,
        )
        val fourPartFist = resolve(
            radiusMajorDp = 12.0,
            radiusMinorDp = 7.0,
            normalizedSize = 0.10,
            normalizedPressure = 1.0,
            contactCount = 4,
            hasMeasuredTouchAxes = false,
        )

        assertEquals(44.0, single.radiusMajorDp, EPSILON)
        assertEquals(50.0, fourPartFist.radiusMajorDp, EPSILON)
    }

    @Test
    fun footprintExpansionCannotPromoteOrdinaryFinger() {
        val ordinaryFingerIsEvidence =
            PalmContactEvidence.isStrongEraserEvidence(
                compactMultiContact = false,
            )

        assertFalse(ordinaryFingerIsEvidence)
        // The footprint policy is intentionally a post-decision API. Its
        // broad result cannot affect the independent evidence result above.
        assertTrue(
            resolve(
                radiusMajorDp = 20.0,
                radiusMinorDp = 12.0,
                normalizedSize = 0.40,
                normalizedPressure = 1.0,
                contactCount = 2,
            ).radiusMajorDp > 20.0,
        )
    }

    @Test
    fun malformedRecognizedPalmGeometryRemainsFiniteAndBounded() {
        val footprint = resolve(
            radiusMajorDp = Double.POSITIVE_INFINITY,
            radiusMinorDp = Double.NaN,
            normalizedSize = 50.0,
            normalizedPressure = 50.0,
            contactCount = Int.MAX_VALUE,
        )

        assertTrue(footprint.radiusMajorDp in 44.0..132.0)
        assertTrue(footprint.radiusMinorDp in 24.0..132.0)
    }

    private fun resolve(
        radiusMajorDp: Double,
        radiusMinorDp: Double,
        normalizedSize: Double,
        normalizedPressure: Double,
        contactCount: Int,
        hasMeasuredTouchAxes: Boolean = true,
    ) = RecognizedPalmFootprintPolicy.resolve(
        radiusMajorDp = radiusMajorDp,
        radiusMinorDp = radiusMinorDp,
        normalizedSize = normalizedSize,
        normalizedPressure = normalizedPressure,
        contactCount = contactCount,
        hasMeasuredTouchAxes = hasMeasuredTouchAxes,
    )

    private companion object {
        const val EPSILON = 0.000_001
    }
}
