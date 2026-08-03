package de.flowboardx.flowboard_x

import kotlin.math.PI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PalmContactGeometryTest {
    @Test
    fun touchscreenAxesAreConvertedFromDiameterPixelsToLogicalRadii() {
        val geometry = estimate(
            touchMajorPx = 192.0,
            touchMinorPx = 96.0,
            density = 2.0,
        )

        assertEquals(48.0, geometry.radiusMajorDp, EPSILON)
        assertEquals(24.0, geometry.radiusMinorDp, EPSILON)
        assertEquals(48.0, geometry.measuredRadiusMajorDp, EPSILON)
        assertEquals(24.0, geometry.measuredRadiusMinorDp, EPSILON)
    }

    @Test
    fun pinnedSizeCanOnlyRefineAConstantSmallSmartboardAxis() {
        val geometry = estimate(
            touchMajorPx = 20.0,
            touchMinorPx = 12.0,
            density = 2.0,
            normalizedSize = 0.5,
            normalizedPressure = 0.8,
        )

        assertEquals(5.0, geometry.measuredRadiusMajorDp, EPSILON)
        assertEquals(3.0, geometry.measuredRadiusMinorDp, EPSILON)
        assertTrue(geometry.radiusMajorDp in 7.0..8.0)
        assertTrue(geometry.radiusMinorDp in 4.0..5.0)
        assertEquals(
            0.6,
            geometry.radiusMinorDp / geometry.radiusMajorDp,
            EPSILON,
        )
    }

    @Test
    fun pressureAloneCannotPretendToMeasureContactArea() {
        val light = estimate(normalizedPressure = 0.2)
        val pinnedSmartboardPressure = estimate(normalizedPressure = 1.0)

        assertEquals(32.0, light.radiusMajorDp, EPSILON)
        assertEquals(
            light.radiusMajorDp,
            pinnedSmartboardPressure.radiusMajorDp,
            EPSILON,
        )
        assertEquals(light.radiusMajorDp, light.radiusMinorDp, EPSILON)
        assertEquals(
            pinnedSmartboardPressure.radiusMajorDp,
            pinnedSmartboardPressure.radiusMinorDp,
            EPSILON,
        )
    }

    @Test
    fun pinnedPressureAndSizeCannotOverrideMeasuredTouchAxes() {
        val finger = estimate(
            touchMajorPx = 20.0,
            touchMinorPx = 12.0,
            normalizedSize = 0.1,
            normalizedPressure = 1.0,
        )
        val fist = estimate(
            touchMajorPx = 20.0,
            touchMinorPx = 12.0,
            normalizedSize = 0.55,
            normalizedPressure = 1.0,
        )

        assertEquals(finger.radiusMajorDp, fist.radiusMajorDp, EPSILON)
        assertFalse(
            PalmContactEvidence.isStrongEraserEvidence(
                compactMultiContact = false,
            ),
        )
        assertFalse(
            PalmContactEvidence.isStrongEraserEvidence(
                compactMultiContact = false,
            ),
        )
    }

    @Test
    fun pinnedSizeStillFollowsShrinkingCurrentTouchAxes() {
        val broad = estimate(
            touchMajorPx = 160.0,
            touchMinorPx = 80.0,
            density = 2.0,
            normalizedSize = 1.0,
            normalizedPressure = 1.0,
        )
        val compact = estimate(
            touchMajorPx = 40.0,
            touchMinorPx = 20.0,
            density = 2.0,
            normalizedSize = 1.0,
            normalizedPressure = 1.0,
        )

        assertTrue(broad.radiusMajorDp > 50.0)
        assertTrue(compact.radiusMajorDp < 15.0)
        assertTrue(compact.radiusMajorDp < broad.radiusMajorDp * 0.3)
    }

    @Test
    fun normalizedSizeRemainsFallbackWithoutTouchOrToolAxes() {
        val compact = estimate(normalizedSize = 0.1)
        val broad = estimate(normalizedSize = 1.0)

        assertTrue(broad.radiusMajorDp > compact.radiusMajorDp * 3.5)
        assertEquals(100.0, broad.radiusMajorDp, EPSILON)
        assertFalse(broad.hasMeasuredAxes)
    }

    @Test
    fun touchAxesWinOverToolBodyAxes() {
        val geometry = estimate(
            touchMajorPx = 120.0,
            touchMinorPx = 60.0,
            toolMajorPx = 400.0,
            toolMinorPx = 400.0,
            density = 2.0,
        )

        assertEquals(30.0, geometry.radiusMajorDp, EPSILON)
        assertEquals(15.0, geometry.radiusMinorDp, EPSILON)
    }

    @Test
    fun toolAxesRemainADpiCorrectedFallback() {
        val geometry = estimate(
            toolMajorPx = 200.0,
            toolMinorPx = 80.0,
            density = 2.0,
        )

        assertEquals(50.0, geometry.radiusMajorDp, EPSILON)
        assertEquals(20.0, geometry.radiusMinorDp, EPSILON)
        assertFalse(geometry.hasMeasuredAxes)
        assertEquals(0.0, geometry.measuredRadiusMajorDp, EPSILON)
    }

    @Test
    fun swappedVendorAxesRotateTheEllipseInsteadOfMovingItsFootprint() {
        val geometry = estimate(
            touchMajorPx = 40.0,
            touchMinorPx = 80.0,
            density = 2.0,
            orientationRadians = 0.0,
        )

        assertEquals(20.0, geometry.radiusMajorDp, EPSILON)
        assertEquals(10.0, geometry.radiusMinorDp, EPSILON)
        assertEquals(PI / 2.0, geometry.orientation, EPSILON)
    }

    @Test
    fun malformedDriverValuesFallBackToFiniteBoundedGeometry() {
        val geometry = estimate(
            touchMajorPx = Double.NaN,
            touchMinorPx = Double.POSITIVE_INFINITY,
            toolMajorPx = -20.0,
            density = Double.NaN,
            normalizedSize = Double.POSITIVE_INFINITY,
            normalizedPressure = -1.0,
            orientationRadians = Double.NEGATIVE_INFINITY,
        )

        assertEquals(32.0, geometry.radiusMajorDp, EPSILON)
        assertEquals(32.0, geometry.radiusMinorDp, EPSILON)
        assertEquals(0.0, geometry.orientation, EPSILON)
    }

    @Test
    fun hostileAxisAndDensityValuesCannotCreateAnUnboundedEraser() {
        val geometry = estimate(
            touchMajorPx = 100_000.0,
            touchMinorPx = 100_000.0,
            density = 0.01,
            normalizedSize = 20.0,
            normalizedPressure = 20.0,
        )

        assertEquals(160.0, geometry.radiusMajorDp, EPSILON)
        assertEquals(160.0, geometry.radiusMinorDp, EPSILON)
        assertEquals(1.0, geometry.normalizedSize, EPSILON)
        assertEquals(1.0, geometry.normalizedPressure, EPSILON)
    }

    private fun estimate(
        touchMajorPx: Double = 0.0,
        touchMinorPx: Double = 0.0,
        toolMajorPx: Double = 0.0,
        toolMinorPx: Double = 0.0,
        density: Double = 1.0,
        normalizedSize: Double = 0.0,
        normalizedPressure: Double = 0.0,
        orientationRadians: Double = 0.0,
    ) = PalmContactGeometryEstimator.estimate(
        touchMajorPx = touchMajorPx,
        touchMinorPx = touchMinorPx,
        toolMajorPx = toolMajorPx,
        toolMinorPx = toolMinorPx,
        density = density,
        normalizedSize = normalizedSize,
        normalizedPressure = normalizedPressure,
        orientationRadians = orientationRadians,
    )

    private companion object {
        const val EPSILON = 0.000_001
    }
}
