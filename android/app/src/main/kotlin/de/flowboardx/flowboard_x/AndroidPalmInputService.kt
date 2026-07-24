package de.flowboardx.flowboard_x

import android.content.Context
import android.os.Build
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.max

/**
 * Passive Android palm observer.
 *
 * Samsung/Android can classify an unintended touch only after Flutter has
 * already received part of its pointer stream. This service keeps a small,
 * bounded copy of touchscreen traces and reports native palm evidence over a
 * side channel. It never mutates, cancels, recycles or consumes MotionEvents.
 */
internal class AndroidPalmInputService(
    context: Context,
    messenger: BinaryMessenger,
    private val coordinateViewProvider: () -> View? = { null },
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val fallbackDensity = context.resources.displayMetrics.density
        .takeIf { it.isFinite() && it > 0f }
        ?: 1f
    private val traces = LinkedHashMap<Int, Trace>()

    @Volatile
    private var disposed = false

    /** Called on the activity UI thread before Flutter handles [event]. */
    fun observe(event: MotionEvent) {
        if (disposed ||
            (!event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) &&
                !event.hasPalmTool())
        ) return
        try {
            expireOldTraces(event.eventTime)
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    traces.clear()
                    ensureTrace(event, event.actionIndex)
                    appendCurrentSamples(event)
                }

                MotionEvent.ACTION_POINTER_DOWN -> {
                    ensureTrace(event, event.actionIndex)
                    appendCurrentSamples(event)
                }

                MotionEvent.ACTION_MOVE -> appendCurrentSamples(event)

                MotionEvent.ACTION_POINTER_UP,
                MotionEvent.ACTION_UP,
                -> {
                    appendCurrentSamples(event)
                    val pointerId = event.getPointerId(event.actionIndex)
                    finishTrace(
                        pointerId,
                        event,
                        canceledBySystem = event.hasPalmCancellationFlag(),
                    )
                    if (event.actionMasked == MotionEvent.ACTION_UP) {
                        traces.clear()
                    }
                }

                MotionEvent.ACTION_CANCEL -> {
                    appendCurrentSamples(event)
                    val pointerIds = traces.keys.toList()
                    val legacySingleFingerCancellation =
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU &&
                            traces.size == 1 &&
                            traces.values.single().lastToolType ==
                            MotionEvent.TOOL_TYPE_FINGER
                    val systemPalmCancellation =
                        event.hasPalmCancellationFlag() || legacySingleFingerCancellation
                    for (pointerId in pointerIds) {
                        finishTrace(
                            pointerId,
                            event,
                            canceledBySystem = systemPalmCancellation,
                        )
                    }
                    traces.clear()
                }
            }
        } catch (error: Throwable) {
            // Native palm diagnostics are best-effort and must never interfere
            // with Flutter's dispatchTouchEvent path.
            Log.w(TAG, "Palm input observation failed", error)
            traces.clear()
        }
    }

    fun dispose() {
        disposed = true
        traces.clear()
    }

    private fun appendCurrentSamples(event: MotionEvent) {
        val eligiblePointerIndices = (0 until event.pointerCount)
            .filter { pointerIndex -> event.isEligibleTool(pointerIndex) }
        if (eligiblePointerIndices.isEmpty()) return
        val contactCount = eligiblePointerIndices.size
        val compactMultiContact = event.hasCompactMultiContact(eligiblePointerIndices)

        for (pointerIndex in 0 until event.pointerCount) {
            if (!event.isEligibleTool(pointerIndex)) continue
            val trace = ensureTrace(event, pointerIndex) ?: continue
            val toolType = event.getToolType(pointerIndex)
            trace.lastToolType = toolType
            if (toolType == HIDDEN_TOOL_TYPE_PALM) {
                trace.nativeReason = REASON_TOOL_TYPE_PALM
            }
            trace.peakContactCount = max(trace.peakContactCount, contactCount)
            trace.compactMultiContactEvidence =
                trace.compactMultiContactEvidence || compactMultiContact
            val contact = contactGeometryDp(event, pointerIndex)
            trace.maximumRadiusDp = max(
                trace.maximumRadiusDp,
                contact.radiusMajorDp,
            )
            val position = logicalViewPosition(event, pointerIndex)
            trace.add(
                Sample(
                    xDp = position.first,
                    yDp = position.second,
                    eventTimeMillis = event.eventTime,
                    radiusMajorDp = contact.radiusMajorDp,
                    radiusMinorDp = contact.radiusMinorDp,
                    orientation = contact.orientation,
                ),
            )
        }
    }

    private fun ensureTrace(event: MotionEvent, pointerIndex: Int): Trace? {
        if (!event.isEligibleTool(pointerIndex)) return null
        val pointerId = event.getPointerId(pointerIndex)
        traces[pointerId]?.let { return it }
        while (traces.size >= MAX_ACTIVE_TRACES) {
            val oldest = traces.entries.minByOrNull { it.value.lastEventTimeMillis }
                ?: break
            traces.remove(oldest.key)
        }
        return Trace(
            pointerId = pointerId,
            deviceId = event.deviceId,
            downTimeMillis = event.downTime,
            lastEventTimeMillis = event.eventTime,
            lastToolType = event.getToolType(pointerIndex),
        ).also { trace ->
            if (trace.lastToolType == HIDDEN_TOOL_TYPE_PALM) {
                trace.nativeReason = REASON_TOOL_TYPE_PALM
            }
            traces[pointerId] = trace
        }
    }

    private fun finishTrace(
        pointerId: Int,
        event: MotionEvent,
        canceledBySystem: Boolean,
    ) {
        val trace = traces.remove(pointerId) ?: return
        val reason = trace.nativeReason
            ?: if (canceledBySystem && trace.hasCancellationEvidence()) {
                REASON_SYSTEM_CANCELED
            } else {
                null
            }
            ?: return
        if (trace.samples.isEmpty()) return
        channel.invokeMethod(
            METHOD_PALM_TRACE,
            mapOf(
                "traceId" to "${trace.deviceId}:${trace.downTimeMillis}:${trace.pointerId}",
                "pointerId" to trace.pointerId,
                "deviceId" to trace.deviceId,
                "downTimeMillis" to trace.downTimeMillis,
                "eventTimeMillis" to event.eventTime,
                "reason" to reason,
                "toolType" to trace.lastToolType,
                "radius" to trace.maximumRadiusDp,
                "contactCount" to trace.peakContactCount,
                "pathLength" to trace.pathLengthDp,
                "displacement" to trace.displacementDp(),
                "points" to trace.samples.map { sample ->
                    mapOf(
                        "x" to sample.xDp,
                        "y" to sample.yDp,
                        "timestampMillis" to sample.eventTimeMillis,
                        "radius" to sample.radiusMajorDp,
                        "radiusMajor" to sample.radiusMajorDp,
                        "radiusMinor" to sample.radiusMinorDp,
                        "orientation" to sample.orientation,
                    )
                },
            ),
        )
    }

    private fun expireOldTraces(eventTimeMillis: Long) {
        val iterator = traces.entries.iterator()
        while (iterator.hasNext()) {
            val trace = iterator.next().value
            if (eventTimeMillis - trace.lastEventTimeMillis > MAX_TRACE_AGE_MILLIS) {
                iterator.remove()
            }
        }
    }

    private fun contactGeometryDp(
        event: MotionEvent,
        pointerIndex: Int,
    ): ContactGeometry {
        val density = coordinateDensity()
        var major = positiveAxis(event.getTouchMajor(pointerIndex)) /
            density / 2.0
        var minor = positiveAxis(event.getTouchMinor(pointerIndex)) /
            density / 2.0
        if (major <= 0.0 && minor <= 0.0) {
            major = positiveAxis(
                event.getAxisValue(MotionEvent.AXIS_TOOL_MAJOR, pointerIndex),
            ) / density / 2.0
            minor = positiveAxis(
                event.getAxisValue(MotionEvent.AXIS_TOOL_MINOR, pointerIndex),
            ) / density / 2.0
        }
        if (major <= 0.0 && minor <= 0.0) {
            val normalizedSize = event.getSize(pointerIndex)
                .takeIf { it.isFinite() && it > 0f }
                ?.coerceIn(0f, 1f)
                ?.toDouble()
                ?: 0.0
            val fallback = if (normalizedSize > 0) {
                18.0 + normalizedSize * 60.0
            } else {
                DEFAULT_RADIUS_DP
            }
            major = fallback
            minor = fallback
        } else if (major <= 0.0) {
            major = minor
        } else if (minor <= 0.0) {
            // Do not infer a top-left anchored elongated contact from a
            // single calibrated axis. A centred circle is the safe fallback.
            minor = major
        }
        if (minor > major) {
            val previousMajor = major
            major = minor
            minor = previousMajor
        }
        val orientation = event.getOrientation(pointerIndex)
            .takeIf { it.isFinite() }
            ?.toDouble()
            ?.coerceIn(-Math.PI / 2, Math.PI / 2)
            ?: 0.0
        val safeMajor = major.coerceIn(1.0, MAX_RADIUS_DP)
        return ContactGeometry(
            radiusMajorDp = safeMajor,
            radiusMinorDp = minor.coerceIn(1.0, safeMajor),
            orientation = orientation,
        )
    }

    /**
     * Converts Android display pixels to Flutter-view-global logical pixels.
     *
     * getRawX/getRawY are display coordinates, whereas Flutter's global
     * pointer origin is the FlutterView's top-left. Subtracting the actual
     * view origin prevents status bars, multi-window offsets and board vendor
     * decorations from shifting a palm trace towards the upper-left.
     */
    private fun logicalViewPosition(
        event: MotionEvent,
        pointerIndex: Int,
    ): Pair<Double, Double> {
        val density = coordinateDensity()
        val rawX = rawX(event, pointerIndex).toDouble()
        val rawY = rawY(event, pointerIndex).toDouble()
        val view = runCatching { coordinateViewProvider() }.getOrNull()
        if (view != null && view.isAttachedToWindow) {
            val origin = IntArray(2)
            view.getLocationOnScreen(origin)
            return Pair(
                (rawX - origin[0]) / density,
                (rawY - origin[1]) / density,
            )
        }
        return Pair(rawX / density, rawY / density)
    }

    private fun coordinateDensity(): Double {
        val viewDensity = runCatching {
            coordinateViewProvider()?.resources?.displayMetrics?.density
        }.getOrNull()
        return viewDensity
            ?.takeIf { it.isFinite() && it > 0f }
            ?.toDouble()
            ?: fallbackDensity.toDouble()
    }

    private fun positiveAxis(value: Float): Double =
        value.takeIf { it.isFinite() && it > 0f }?.toDouble() ?: 0.0

    private fun rawX(event: MotionEvent, pointerIndex: Int): Float =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            event.getRawX(pointerIndex)
        } else {
            event.rawX - event.x + event.getX(pointerIndex)
        }

    private fun rawY(event: MotionEvent, pointerIndex: Int): Float =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            event.getRawY(pointerIndex)
        } else {
            event.rawY - event.y + event.getY(pointerIndex)
        }

    private fun MotionEvent.hasPalmCancellationFlag(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            flags and MotionEvent.FLAG_CANCELED != 0

    private fun MotionEvent.hasPalmTool(): Boolean {
        for (pointerIndex in 0 until pointerCount) {
            if (getToolType(pointerIndex) == HIDDEN_TOOL_TYPE_PALM) return true
        }
        return false
    }

    private fun MotionEvent.isEligibleTool(pointerIndex: Int): Boolean {
        val toolType = getToolType(pointerIndex)
        return toolType == MotionEvent.TOOL_TYPE_FINGER ||
            toolType == HIDDEN_TOOL_TYPE_PALM
    }

    private fun MotionEvent.hasCompactMultiContact(
        eligiblePointerIndices: List<Int>,
    ): Boolean {
        if (eligiblePointerIndices.size !in MIN_COMPACT_CONTACT_COUNT..
            MAX_COMPACT_CONTACT_COUNT
        ) return false
        var minX = Double.POSITIVE_INFINITY
        var minY = Double.POSITIVE_INFINITY
        var maxX = Double.NEGATIVE_INFINITY
        var maxY = Double.NEGATIVE_INFINITY
        for (pointerIndex in eligiblePointerIndices) {
            val position = logicalViewPosition(this, pointerIndex)
            val x = position.first
            val y = position.second
            if (!x.isFinite() || !y.isFinite()) return false
            minX = kotlin.math.min(minX, x)
            minY = kotlin.math.min(minY, y)
            maxX = kotlin.math.max(maxX, x)
            maxY = kotlin.math.max(maxY, y)
        }
        return hypot(maxX - minX, maxY - minY) <= MAX_COMPACT_CLUSTER_DIAMETER_DP
    }

    private data class Sample(
        val xDp: Double,
        val yDp: Double,
        val eventTimeMillis: Long,
        val radiusMajorDp: Double,
        val radiusMinorDp: Double,
        val orientation: Double,
    )

    private data class ContactGeometry(
        val radiusMajorDp: Double,
        val radiusMinorDp: Double,
        val orientation: Double,
    )

    private class Trace(
        val pointerId: Int,
        val deviceId: Int,
        val downTimeMillis: Long,
        var lastEventTimeMillis: Long,
        var lastToolType: Int,
    ) {
        var nativeReason: String? = null
        var maximumRadiusDp: Double = 0.0
        var peakContactCount: Int = 1
        var compactMultiContactEvidence: Boolean = false
        var pathLengthDp: Double = 0.0
        private var firstSample: Sample? = null
        private var lastObservedSample: Sample? = null
        val samples = ArrayList<Sample>(INITIAL_SAMPLE_CAPACITY)

        fun add(sample: Sample) {
            lastEventTimeMillis = sample.eventTimeMillis
            if (firstSample == null) firstSample = sample
            lastObservedSample?.let { previous ->
                pathLengthDp += hypot(
                    sample.xDp - previous.xDp,
                    sample.yDp - previous.yDp,
                )
            }
            lastObservedSample = sample
            val previous = samples.lastOrNull()
            if (previous != null &&
                sample.eventTimeMillis - previous.eventTimeMillis < MIN_SAMPLE_INTERVAL_MILLIS &&
                hypot(sample.xDp - previous.xDp, sample.yDp - previous.yDp) <
                MIN_SAMPLE_DISTANCE_DP
            ) {
                samples[samples.lastIndex] = sample
                return
            }
            if (samples.size >= MAX_SAMPLES_PER_TRACE) {
                // Uniformly compact the complete path instead of dropping its
                // beginning. Endpoints survive and future samples have room.
                var writeIndex = 1
                var readIndex = 2
                while (readIndex < samples.size - 1) {
                    samples[writeIndex++] = samples[readIndex]
                    readIndex += 2
                }
                val last = samples.last()
                if (writeIndex < samples.size) samples[writeIndex++] = last
                samples.subList(writeIndex, samples.size).clear()
            }
            samples += sample
        }

        fun displacementDp(): Double {
            val first = firstSample ?: return 0.0
            val last = lastObservedSample ?: return 0.0
            return hypot(last.xDp - first.xDp, last.yDp - first.yDp)
        }

        fun hasCancellationEvidence(): Boolean =
            pathLengthDp >= MIN_CANCEL_PATH_LENGTH_DP ||
                displacementDp() >= MIN_CANCEL_DISPLACEMENT_DP ||
                maximumRadiusDp >= MIN_CANCEL_RADIUS_DP ||
                compactMultiContactEvidence
    }

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/palm_input"
        const val METHOD_PALM_TRACE = "palmTrace"
        const val TAG = "FlowboardPalmInput"
        const val HIDDEN_TOOL_TYPE_PALM = 5
        const val REASON_TOOL_TYPE_PALM = "tool_type_palm"
        const val REASON_SYSTEM_CANCELED = "system_canceled"
        const val MAX_ACTIVE_TRACES = 16
        const val MAX_SAMPLES_PER_TRACE = 192
        const val INITIAL_SAMPLE_CAPACITY = 64
        const val MAX_TRACE_AGE_MILLIS = 30_000L
        const val MIN_SAMPLE_INTERVAL_MILLIS = 4L
        const val MIN_SAMPLE_DISTANCE_DP = 0.75
        const val MAX_RADIUS_DP = 160.0
        const val DEFAULT_RADIUS_DP = 32.0
        const val MIN_CANCEL_PATH_LENGTH_DP = 12.0
        const val MIN_CANCEL_DISPLACEMENT_DP = 8.0
        const val MIN_CANCEL_RADIUS_DP = 13.0
        const val MIN_COMPACT_CONTACT_COUNT = 3
        const val MAX_COMPACT_CONTACT_COUNT = 4
        const val MAX_COMPACT_CLUSTER_DIAMETER_DP = 120.0
    }
}
