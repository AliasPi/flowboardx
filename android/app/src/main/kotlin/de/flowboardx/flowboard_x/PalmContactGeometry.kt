package de.flowboardx.flowboard_x

import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min

/**
 * One DPI-corrected Android touch-contact estimate.
 *
 * [measuredRadiusMajorDp]/[measuredRadiusMinorDp] contain only the calibrated
 * TOUCH axes. TOOL axes may still provide a visual fallback, but never count
 * as destructive palm evidence because Android defines them as the estimated
 * tool body rather than the actual contact patch.
 */
internal data class PalmContactGeometry(
    val radiusMajorDp: Double,
    val radiusMinorDp: Double,
    val measuredRadiusMajorDp: Double,
    val measuredRadiusMinorDp: Double,
    val normalizedSize: Double,
    val normalizedPressure: Double,
    val orientation: Double,
) {
    val hasMeasuredAxes: Boolean
        get() = measuredRadiusMajorDp > 0.0
}

/**
 * Hardware-tolerant fusion of Android's four contact-area signals.
 *
 * Android guarantees display-pixel units for touchscreen touch/tool axes, but
 * board firmware varies widely: some panels report an accurate ellipse, some
 * expose only `size`, and others keep a small axis while pressure/size grows
 * under a fist. The eraser uses the largest finite physical estimate while
 * preserving the measured ellipse aspect ratio.
 */
internal object PalmContactGeometryEstimator {
    fun estimate(
        touchMajorPx: Double,
        touchMinorPx: Double,
        toolMajorPx: Double,
        toolMinorPx: Double,
        density: Double,
        normalizedSize: Double,
        normalizedPressure: Double,
        orientationRadians: Double,
    ): PalmContactGeometry {
        val safeDensity = density
            .takeIf { it.isFinite() && it > 0.0 }
            ?.coerceIn(MIN_DENSITY, MAX_DENSITY)
            ?: 1.0
        val touchMajor = axisRadiusDp(touchMajorPx, safeDensity)
        val touchMinor = axisRadiusDp(touchMinorPx, safeDensity)
        val toolMajor = axisRadiusDp(toolMajorPx, safeDensity)
        val toolMinor = axisRadiusDp(toolMinorPx, safeDensity)

        val measuredTouchMajor: Double
        val measuredTouchMinor: Double
        if (touchMajor > 0.0 && touchMinor > 0.0) {
            measuredTouchMajor = max(touchMajor, touchMinor)
            measuredTouchMinor = min(touchMajor, touchMinor)
        } else {
            measuredTouchMajor = max(touchMajor, touchMinor)
            measuredTouchMinor = 0.0
        }

        // Touch axes represent the actual contact patch. Tool axes describe
        // the estimated finger/tool body and are used only as non-evidentiary
        // rendering fallback when both touch axes are absent.
        var firstAxis = touchMajor
        var secondAxis = touchMinor
        if (firstAxis <= 0.0 && secondAxis <= 0.0) {
            firstAxis = toolMajor
            secondAxis = toolMinor
        }

        var orientation = normalizeOrientation(orientationRadians)
        val measuredMajor: Double
        val measuredMinor: Double
        if (firstAxis > 0.0 && secondAxis > 0.0) {
            measuredMajor = max(firstAxis, secondAxis)
            measuredMinor = min(firstAxis, secondAxis)
            if (secondAxis > firstAxis) {
                // Preserve the physical ellipse if malformed vendor data puts
                // the larger value in TOUCH_MINOR.
                orientation = normalizeOrientation(orientation + PI / 2.0)
            }
        } else {
            measuredMajor = max(firstAxis, secondAxis)
            measuredMinor = 0.0
        }

        val size = normalizedUnit(normalizedSize)
        val pressure = normalizedUnit(normalizedPressure)
        val pressureScale = if (pressure > 0.0) {
            PRESSURE_SCALE_MIN + pressure * PRESSURE_SCALE_SPAN
        } else {
            1.0
        }
        val sizeRadius = if (size > 0.0) {
            // `size` is device-normalized, not a physical length. This mapping
            // intentionally stays below the hard clamp while still allowing a
            // broad fist to exceed a small constant driver axis.
            (MIN_INFERRED_RADIUS_DP + size * SIZE_RADIUS_SPAN_DP) *
                pressureScale
        } else {
            0.0
        }

        var major: Double
        var minor: Double
        if (measuredMajor > 0.0) {
            val scaledMeasuredMajor = measuredMajor * pressureScale
            val scaledMeasuredMinor = measuredMinor * pressureScale
            val hasMeasuredTouchAxes = measuredTouchMajor > 0.0
            // SIZE is normalized by vendor firmware and is frequently pinned
            // to 1.0. A calibrated TOUCH axis is therefore authoritative: SIZE
            // may add only a small refinement which follows the current axis.
            // With no TOUCH axes, SIZE remains the best bounded fallback.
            val resolvedMajor = if (hasMeasuredTouchAxes && sizeRadius > 0.0) {
                val sizeRefinementCap =
                    scaledMeasuredMajor +
                        min(
                            MAX_SIZE_REFINEMENT_DP,
                            max(
                                MIN_SIZE_REFINEMENT_DP,
                                scaledMeasuredMajor * SIZE_REFINEMENT_RATIO,
                            ),
                        )
                max(scaledMeasuredMajor, min(sizeRadius, sizeRefinementCap))
            } else {
                max(scaledMeasuredMajor, sizeRadius)
            }
            if (measuredMinor > 0.0) {
                val aspectRatio =
                    (measuredMinor / measuredMajor).coerceIn(
                        MIN_ELLIPSE_ASPECT_RATIO,
                        1.0,
                    )
                major = resolvedMajor
                minor = max(scaledMeasuredMinor, resolvedMajor * aspectRatio)
            } else {
                // One calibrated axis does not reveal orientation/aspect ratio.
                // A centred circle cannot shift the erase area away from the
                // actual MotionEvent coordinate.
                major = resolvedMajor
                minor = major
            }
        } else {
            major = if (sizeRadius > 0.0) {
                sizeRadius
            } else {
                DEFAULT_RADIUS_DP
            }
            minor = major
        }

        major = major.coerceIn(MIN_RADIUS_DP, MAX_RADIUS_DP)
        minor = minor.coerceIn(MIN_RADIUS_DP, major)
        return PalmContactGeometry(
            radiusMajorDp = major,
            radiusMinorDp = minor,
            measuredRadiusMajorDp =
                measuredTouchMajor.coerceIn(0.0, MAX_RADIUS_DP),
            measuredRadiusMinorDp =
                measuredTouchMinor.coerceIn(0.0, MAX_RADIUS_DP),
            normalizedSize = size,
            normalizedPressure = pressure,
            orientation = orientation,
        )
    }

    private fun axisRadiusDp(valuePx: Double, density: Double): Double {
        if (!valuePx.isFinite() || valuePx <= 0.0) return 0.0
        // Android axes are full diameters in display pixels; Flutter and the
        // platform channel use logical pixels and radii.
        return (valuePx / density / 2.0).coerceIn(0.0, MAX_RADIUS_DP)
    }

    private fun normalizedUnit(value: Double): Double =
        value.takeIf { it.isFinite() && it > 0.0 }
            ?.coerceIn(0.0, 1.0)
            ?: 0.0

    private fun normalizeOrientation(value: Double): Double {
        if (!value.isFinite()) return 0.0
        var normalized = value
        while (normalized > PI / 2.0) normalized -= PI
        while (normalized < -PI / 2.0) normalized += PI
        return normalized
    }

    private const val MIN_DENSITY = 0.5
    private const val MAX_DENSITY = 8.0
    private const val MIN_RADIUS_DP = 1.0
    private const val MAX_RADIUS_DP = 160.0
    private const val DEFAULT_RADIUS_DP = 32.0
    private const val MIN_INFERRED_RADIUS_DP = 14.0
    private const val SIZE_RADIUS_SPAN_DP = 86.0
    private const val PRESSURE_SCALE_MIN = 1.0
    private const val PRESSURE_SCALE_SPAN = 0.08
    private const val MIN_SIZE_REFINEMENT_DP = 2.0
    private const val MAX_SIZE_REFINEMENT_DP = 10.0
    private const val SIZE_REFINEMENT_RATIO = 0.22
    private const val MIN_ELLIPSE_ASPECT_RATIO = 0.18
}

/**
 * Conservative destructive-gesture evidence shared by the native replay gate
 * and stylus palm guard.
 *
 * `pressure` is deliberately absent: many classroom boards pin it to 1.0 for
 * every finger. Likewise, tool-major/minor are excluded because they describe
 * the tool body, not its current surface contact.
 */
internal object PalmContactEvidence {
    fun isBroadForStylusGuard(
        measuredTouchRadiusMajorDp: Double,
        normalizedSize: Double,
        explicitlyPalm: Boolean,
    ): Boolean =
        explicitlyPalm ||
            positive(measuredTouchRadiusMajorDp) >=
            MIN_GUARD_TOUCH_RADIUS_DP ||
            unit(normalizedSize) >= MIN_GUARD_NORMALIZED_SIZE

    /**
     * Non-explicit TOOL_TYPE_FINGER input is destructive only when Android
     * observed a coherent compact 3+ contact cluster. A single pointer is
     * never promoted from TOUCH_MAJOR/MINOR: on several classroom boards an
     * ordinary selecting finger reports the same large axes as a palm.
     */
    fun isStrongEraserEvidence(compactMultiContact: Boolean): Boolean =
        compactMultiContact

    private fun positive(value: Double): Double =
        value.takeIf { it.isFinite() && it > 0.0 } ?: 0.0

    private fun unit(value: Double): Double =
        value.takeIf { it.isFinite() && it > 0.0 }
            ?.coerceIn(0.0, 1.0)
            ?: 0.0

    private const val MIN_GUARD_TOUCH_RADIUS_DP = 16.0
    private const val MIN_GUARD_NORMALIZED_SIZE = 0.34
}

internal data class RecognizedPalmFootprint(
    val radiusMajorDp: Double,
    val radiusMinorDp: Double,
)

/**
 * Physical footprint applied only after [PalmTraceDecision] accepted a trace.
 *
 * This post-classification boundary is intentional. Quantized board drivers
 * commonly report the same small axes and pressure=1 for every contact.
 * Current TOUCH axes remain authoritative. Normalized size and contact count
 * may only refine an already trusted palm/fist and can never make a normal
 * finger eligible for erasing.
 */
internal object RecognizedPalmFootprintPolicy {
    fun resolve(
        radiusMajorDp: Double,
        radiusMinorDp: Double,
        normalizedSize: Double,
        normalizedPressure: Double,
        contactCount: Int,
        hasMeasuredTouchAxes: Boolean,
    ): RecognizedPalmFootprint {
        val firstRadius = positive(radiusMajorDp)
        val secondRadius = positive(radiusMinorDp)
        val rawMajor = max(firstRadius, secondRadius)
        val rawMinor = if (firstRadius > 0.0 && secondRadius > 0.0) {
            min(firstRadius, secondRadius)
        } else {
            rawMajor
        }
        val size = unit(normalizedSize)
        val rawSizeGrowth = ((size - SIZE_DEAD_ZONE) /
            (1.0 - SIZE_DEAD_ZONE)).coerceIn(0.0, 1.0)
        val sizeGrowth =
            rawSizeGrowth * rawSizeGrowth * (3.0 - 2.0 * rawSizeGrowth)
        val safeContactCount = contactCount.coerceIn(1, MAX_CONTACT_COUNT)

        // Every accepted physical palm receives a useful board-scale minimum.
        // With calibrated TOUCH axes, pinned SIZE may only refine their
        // current value. Without axes, SIZE remains the bounded fallback.
        // Pressure has no calibrated range here and is deliberately excluded.
        val physicalFloor = max(MIN_RECOGNIZED_MAJOR_RADIUS_DP, rawMajor)
        val sizeFloor = if (hasMeasuredTouchAxes) {
            physicalFloor +
                sizeGrowth * min(
                    MAX_SIZE_REFINEMENT_DP,
                    max(MIN_SIZE_REFINEMENT_DP, physicalFloor * SIZE_REFINEMENT_RATIO),
                )
        } else {
            MIN_RECOGNIZED_MAJOR_RADIUS_DP +
                sizeGrowth * SIZE_FLOOR_SPAN_DP
        }
        val contactFallback = if (!hasMeasuredTouchAxes && size <= SIZE_DEAD_ZONE) {
            MIN_RECOGNIZED_MAJOR_RADIUS_DP +
                min(MAX_CONTACT_FALLBACK_DP, (safeContactCount - 1) * 2.0)
        } else {
            MIN_RECOGNIZED_MAJOR_RADIUS_DP
        }
        val major = max(physicalFloor, max(sizeFloor, contactFallback)).coerceIn(
            MIN_RECOGNIZED_MAJOR_RADIUS_DP,
            MAX_RECOGNIZED_RADIUS_DP,
        )

        val rawAspect = if (rawMajor > 0.0) rawMinor / rawMajor else 1.0
        val stableAspect = rawAspect.coerceIn(
            MIN_RECOGNIZED_ASPECT_RATIO,
            1.0,
        )
        val minor = max(
            rawMinor,
            max(MIN_RECOGNIZED_MINOR_RADIUS_DP, major * stableAspect),
        ).coerceIn(
            MIN_RECOGNIZED_MINOR_RADIUS_DP,
            major,
        )
        return RecognizedPalmFootprint(
            radiusMajorDp = major,
            radiusMinorDp = minor,
        )
    }

    private fun positive(value: Double): Double =
        value.takeIf { it.isFinite() && it > 0.0 } ?: 0.0

    private fun unit(value: Double): Double =
        value.takeIf { it.isFinite() && it > 0.0 }
            ?.coerceIn(0.0, 1.0)
            ?: 0.0

    private const val MIN_RECOGNIZED_MAJOR_RADIUS_DP = 44.0
    private const val MIN_RECOGNIZED_MINOR_RADIUS_DP = 24.0
    private const val MAX_RECOGNIZED_RADIUS_DP = 132.0
    private const val SIZE_FLOOR_SPAN_DP = 78.0
    private const val MIN_SIZE_REFINEMENT_DP = 4.0
    private const val MAX_SIZE_REFINEMENT_DP = 10.0
    private const val SIZE_REFINEMENT_RATIO = 0.15
    private const val MAX_CONTACT_FALLBACK_DP = 6.0
    private const val MIN_RECOGNIZED_ASPECT_RATIO = 0.42
    private const val MAX_CONTACT_COUNT = 6
    private const val SIZE_DEAD_ZONE = 0.34
}
