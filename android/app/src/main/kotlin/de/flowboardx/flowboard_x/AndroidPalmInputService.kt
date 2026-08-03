package de.flowboardx.flowboard_x

import android.content.Context
import android.os.Build
import android.util.Log
import android.util.LongSparseArray
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
 * side channel. Touch streams which begin next to an active/hovering stylus
 * are quarantined as a whole; mixed stylus/touch packets always pass through
 * so an active pen stroke can never be interrupted by the guard.
 */
class AndroidPalmInputService(
    context: Context,
    messenger: BinaryMessenger,
    private val coordinateViewProvider: () -> View? = { null },
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val fallbackDensity = context.resources.displayMetrics.density
        .takeIf { it.isFinite() && it > 0f }
        ?: 1f
    private val traces = LinkedHashMap<Int, Trace>()
    private val stylusPalmGuard = StylusPalmGuard()
    // observe/observeGenericMotion are dispatched synchronously on Android's
    // UI thread. Reusing these tiny buffers avoids one Pair and one IntArray
    // allocation per pointer sample without retaining MotionEvent instances.
    private val logicalPositionScratch = DoubleArray(2)
    private val viewOriginScratch = IntArray(2)
    private val stylusPointerKeys =
        LongSparseArray<StylusPalmGuard.PointerKey>()
    private var coordinateCacheReady = false
    private var cachedCoordinateDensity = fallbackDensity.toDouble()
    private var cachedViewOriginAvailable = false
    private var coordinateCacheEventTimeMillis = Long.MIN_VALUE

    @Volatile
    private var disposed = false

    /**
     * Called on the activity UI thread before Flutter handles [event].
     *
     * @return true only when the complete, touch-only stream must be consumed
     * natively because it started in the protected area around a live stylus.
     */
    fun observe(event: MotionEvent): Boolean {
        if (disposed) return false
        try {
            if (event.actionMasked == MotionEvent.ACTION_DOWN ||
                event.actionMasked == MotionEvent.ACTION_POINTER_DOWN
            ) {
                resetCoordinateCache()
            }
            val observedStylus = observeStylusPointers(event)
            if (observedStylus && traces.isNotEmpty()) {
                markTracesOverlappingStylus(event.eventTime)
            }
            if (shouldSuppressForStylus(event)) {
                discardEventTraces(event)
                return true
            }
            if ((!event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) &&
                    !event.hasPalmTool()) ||
                !event.hasEligibleTouch()
            ) {
                return false
            }
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
                            MotionEvent.TOOL_TYPE_FINGER &&
                            traces.values.single().hasStrongPalmEvidence()
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
        return false
    }

    /** Observes stylus hover without consuming or changing the event. */
    fun observeGenericMotion(event: MotionEvent) {
        if (disposed) return
        try {
            if (event.actionMasked == MotionEvent.ACTION_HOVER_ENTER) {
                resetCoordinateCache()
            }
            when (event.actionMasked) {
                MotionEvent.ACTION_HOVER_ENTER,
                MotionEvent.ACTION_HOVER_MOVE,
                -> {
                    for (pointerIndex in 0 until event.pointerCount) {
                        if (!event.isStylusTool(pointerIndex)) continue
                        logicalViewPosition(
                            event,
                            pointerIndex,
                            logicalPositionScratch,
                        )
                        stylusPalmGuard.stylusHover(
                            event.stylusPointerKey(pointerIndex),
                            logicalPositionScratch[0],
                            logicalPositionScratch[1],
                            event.eventTime,
                        )
                    }
                }

                MotionEvent.ACTION_HOVER_EXIT -> {
                    for (pointerIndex in 0 until event.pointerCount) {
                        if (!event.isStylusTool(pointerIndex)) continue
                        stylusPalmGuard.stylusHoverExit(
                            event.stylusPointerKey(pointerIndex),
                            event.guardPosition(pointerIndex),
                            event.eventTime,
                        )
                    }
                }
            }
        } catch (error: Throwable) {
            // Hover is an optional optimisation. Never put platform dispatch at
            // risk if a vendor driver supplies malformed pointer metadata.
            Log.w(TAG, "Stylus hover observation failed", error)
        }
    }

    fun dispose() {
        disposed = true
        traces.clear()
        stylusPointerKeys.clear()
        stylusPalmGuard.clear()
    }

    private fun appendCurrentSamples(event: MotionEvent) {
        var contactCount = 0
        for (pointerIndex in 0 until event.pointerCount) {
            if (event.isEligibleTool(pointerIndex)) contactCount += 1
        }
        if (contactCount == 0) return
        val compactMultiContact = event.hasCompactMultiContact(contactCount)

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
            logicalViewPosition(
                event,
                pointerIndex,
                logicalPositionScratch,
            )
            val xDp = logicalPositionScratch[0]
            val yDp = logicalPositionScratch[1]
            if (stylusPalmGuard.isStylusNear(xDp, yDp, event.eventTime)) {
                trace.overlappedStylusProtection = true
            }
            trace.add(
                Sample(
                    xDp = xDp,
                    yDp = yDp,
                    eventTimeMillis = event.eventTime,
                    // Preserve the current physical sample. The Dart side uses
                    // an attack/release filter after palm recognition, so a
                    // settling fist grows quickly without freezing the peak
                    // size for the rest of the wipe.
                    // When calibrated TOUCH axes exist, keep those raw axes
                    // here. RecognizedPalmFootprintPolicy fuses SIZE exactly
                    // once during replay; storing the estimator's already
                    // fused radius would apply a pinned SIZE value twice.
                    radiusMajorDp = if (contact.hasMeasuredAxes) {
                        contact.measuredRadiusMajorDp
                    } else {
                        // Without calibrated TOUCH axes, the estimator's
                        // visual fallback has already fused SIZE and pressure.
                        // Replay starts from zero and lets the recognized-palm
                        // policy apply SIZE once, without leaking pressure or
                        // fixed TOOL-body axes into the destructive footprint.
                        0.0
                    },
                    radiusMinorDp = if (contact.hasMeasuredAxes) {
                        contact.measuredRadiusMinorDp
                    } else {
                        0.0
                    },
                    orientation = contact.orientation,
                    normalizedSize = contact.normalizedSize,
                    normalizedPressure = contact.normalizedPressure,
                    contactCount = contactCount,
                    hasMeasuredTouchAxes = contact.hasMeasuredAxes,
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
        if (!PalmTraceDecision.shouldReplayAsEraser(
                overlappedStylusProtection =
                    trace.overlappedStylusProtection,
                explicitNativePalm = trace.nativeReason != null,
                canceledBySystem = canceledBySystem,
                hasCancellationEvidence = trace.hasCancellationEvidence(),
                pathLengthDp = trace.pathLengthDp,
                displacementDp = trace.displacementDp(),
            )
        ) {
            return
        }
        val reason = trace.nativeReason
            ?: if (canceledBySystem) {
                REASON_SYSTEM_CANCELED
            } else {
                null
            }
            ?: return
        if (trace.samples.isEmpty()) return
        var maximumRenderedRadiusDp = 0.0
        val renderedPoints = trace.samples.map { sample ->
            val footprint = RecognizedPalmFootprintPolicy.resolve(
                radiusMajorDp = sample.radiusMajorDp,
                radiusMinorDp = sample.radiusMinorDp,
                normalizedSize = sample.normalizedSize,
                normalizedPressure = sample.normalizedPressure,
                contactCount = sample.contactCount,
                hasMeasuredTouchAxes = sample.hasMeasuredTouchAxes,
            )
            maximumRenderedRadiusDp = max(
                maximumRenderedRadiusDp,
                footprint.radiusMajorDp,
            )
            mapOf(
                "x" to sample.xDp,
                "y" to sample.yDp,
                "timestampMillis" to sample.eventTimeMillis,
                "radius" to footprint.radiusMajorDp,
                "radiusMajor" to footprint.radiusMajorDp,
                "radiusMinor" to footprint.radiusMinorDp,
                "orientation" to sample.orientation,
                "size" to sample.normalizedSize,
                "pressure" to sample.normalizedPressure,
                "contactCount" to sample.contactCount,
            )
        }
        channel.invokeMethod(
            METHOD_PALM_TRACE,
            mapOf(
                "traceId" to "${trace.deviceId}:${trace.downTimeMillis}:${trace.pointerId}",
                "pointerId" to trace.pointerId,
                "deviceId" to trace.deviceId,
                "downTimeMillis" to trace.downTimeMillis,
                "eventTimeMillis" to event.eventTime,
                "reason" to reason,
                "startedAsPalm" to trace.startedAsPalm,
                "toolType" to trace.lastToolType,
                "radius" to maximumRenderedRadiusDp,
                "contactCount" to trace.peakContactCount,
                "pathLength" to trace.pathLengthDp,
                "displacement" to trace.displacementDp(),
                "points" to renderedPoints,
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
    ): PalmContactGeometry {
        return PalmContactGeometryEstimator.estimate(
            touchMajorPx = event.getTouchMajor(pointerIndex).toDouble(),
            touchMinorPx = event.getTouchMinor(pointerIndex).toDouble(),
            toolMajorPx = event.getAxisValue(
                MotionEvent.AXIS_TOOL_MAJOR,
                pointerIndex,
            ).toDouble(),
            toolMinorPx = event.getAxisValue(
                MotionEvent.AXIS_TOOL_MINOR,
                pointerIndex,
            ).toDouble(),
            density = coordinateDensity(event.eventTime),
            normalizedSize = event.getSize(pointerIndex).toDouble(),
            normalizedPressure = event.getPressure(pointerIndex).toDouble(),
            orientationRadians =
                event.getOrientation(pointerIndex).toDouble(),
        )
    }

    private fun observeStylusPointers(event: MotionEvent): Boolean {
        var observedStylus = false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN,
            MotionEvent.ACTION_POINTER_DOWN,
            -> {
                val actionIndex = event.actionIndex
                if (event.isStylusTool(actionIndex)) {
                    observedStylus = true
                    logicalViewPosition(
                        event,
                        actionIndex,
                        logicalPositionScratch,
                    )
                    stylusPalmGuard.stylusDown(
                        event.stylusPointerKey(actionIndex),
                        logicalPositionScratch[0],
                        logicalPositionScratch[1],
                        event.eventTime,
                    )
                }
                for (pointerIndex in 0 until event.pointerCount) {
                    if (pointerIndex == actionIndex ||
                        !event.isStylusTool(pointerIndex)
                    ) {
                        continue
                    }
                    observedStylus = true
                    logicalViewPosition(
                        event,
                        pointerIndex,
                        logicalPositionScratch,
                    )
                    stylusPalmGuard.stylusMove(
                        event.stylusPointerKey(pointerIndex),
                        logicalPositionScratch[0],
                        logicalPositionScratch[1],
                        event.eventTime,
                    )
                }
            }

            MotionEvent.ACTION_MOVE -> {
                for (pointerIndex in 0 until event.pointerCount) {
                    if (!event.isStylusTool(pointerIndex)) continue
                    observedStylus = true
                    logicalViewPosition(
                        event,
                        pointerIndex,
                        logicalPositionScratch,
                    )
                    stylusPalmGuard.stylusMove(
                        event.stylusPointerKey(pointerIndex),
                        logicalPositionScratch[0],
                        logicalPositionScratch[1],
                        event.eventTime,
                    )
                }
            }

            MotionEvent.ACTION_POINTER_UP,
            MotionEvent.ACTION_UP,
            -> {
                val actionIndex = event.actionIndex
                for (pointerIndex in 0 until event.pointerCount) {
                    if (!event.isStylusTool(pointerIndex)) continue
                    observedStylus = true
                    if (pointerIndex == actionIndex) {
                        stylusPalmGuard.stylusUp(
                            event.stylusPointerKey(pointerIndex),
                            event.guardPosition(pointerIndex),
                            event.eventTime,
                        )
                    } else {
                        stylusPalmGuard.stylusMove(
                            event.stylusPointerKey(pointerIndex),
                            event.guardPosition(pointerIndex),
                            event.eventTime,
                        )
                    }
                }
            }

            MotionEvent.ACTION_CANCEL -> {
                for (pointerIndex in 0 until event.pointerCount) {
                    if (!event.isStylusTool(pointerIndex)) continue
                    observedStylus = true
                    stylusPalmGuard.stylusUp(
                        event.stylusPointerKey(pointerIndex),
                        null,
                        event.eventTime,
                    )
                }
            }
        }
        return observedStylus
    }

    private fun shouldSuppressForStylus(event: MotionEvent): Boolean {
        if ((!event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) &&
                !event.hasPalmTool()) ||
            !event.hasOnlyTouchTools()
        ) {
            return false
        }
        val phase = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> StylusPalmGuard.TouchPhase.START
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL,
            -> StylusPalmGuard.TouchPhase.END
            else -> StylusPalmGuard.TouchPhase.CONTINUE
        }
        val contacts: List<StylusPalmGuard.TouchContact>
        if (phase == StylusPalmGuard.TouchPhase.START) {
            val downContacts =
                ArrayList<StylusPalmGuard.TouchContact>(event.pointerCount)
            for (pointerIndex in 0 until event.pointerCount) {
                downContacts += event.guardContact(pointerIndex)
            }
            contacts = downContacts
        } else {
            // A touch stream cannot switch between passed and suppressed once
            // Flutter has seen its DOWN. Avoid reading axes and allocating
            // contacts for MOVE/UP while a palm rests beside the stylus.
            contacts = emptyList()
        }
        return stylusPalmGuard.shouldSuppressTouch(
            StylusPalmGuard.TouchStreamKey(event.deviceId, event.downTime),
            phase,
            contacts,
            event.eventTime,
        )
    }

    private fun discardEventTraces(event: MotionEvent) {
        for (pointerIndex in 0 until event.pointerCount) {
            traces.remove(event.getPointerId(pointerIndex))
        }
    }

    private fun markTracesOverlappingStylus(eventTimeMillis: Long) {
        for (trace in traces.values) {
            if (trace.isLastPositionNear(stylusPalmGuard, eventTimeMillis)) {
                trace.overlappedStylusProtection = true
            }
        }
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
        result: DoubleArray,
    ) {
        prepareCoordinateCache(event.eventTime)
        val rawX = rawX(event, pointerIndex).toDouble()
        val rawY = rawY(event, pointerIndex).toDouble()
        if (cachedViewOriginAvailable) {
            result[0] =
                (rawX - viewOriginScratch[0]) / cachedCoordinateDensity
            result[1] =
                (rawY - viewOriginScratch[1]) / cachedCoordinateDensity
            return
        }
        result[0] = rawX / cachedCoordinateDensity
        result[1] = rawY / cachedCoordinateDensity
    }

    private fun resetCoordinateCache() {
        coordinateCacheReady = false
        coordinateCacheEventTimeMillis = Long.MIN_VALUE
    }

    private fun prepareCoordinateCache(eventTimeMillis: Long) {
        val cacheAge = eventTimeMillis - coordinateCacheEventTimeMillis
        if (coordinateCacheReady &&
            cacheAge >= 0L &&
            cacheAge < COORDINATE_CACHE_MAX_AGE_MILLIS
        ) {
            return
        }
        val view = runCatching { coordinateViewProvider() }.getOrNull()
        val viewDensity = runCatching {
            view?.resources?.displayMetrics?.density
        }.getOrNull()
        cachedCoordinateDensity = viewDensity
            ?.takeIf { it.isFinite() && it > 0f }
            ?.toDouble()
            ?: fallbackDensity.toDouble()
        cachedViewOriginAvailable =
            view != null &&
                runCatching { view.isAttachedToWindow }.getOrDefault(false) &&
                runCatching {
                    view.getLocationOnScreen(viewOriginScratch)
                }.isSuccess
        coordinateCacheReady = true
        coordinateCacheEventTimeMillis = eventTimeMillis
    }

    private fun coordinateDensity(eventTimeMillis: Long): Double {
        prepareCoordinateCache(eventTimeMillis)
        return cachedCoordinateDensity
    }

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
        eligiblePointerCount: Int,
    ): Boolean {
        if (eligiblePointerCount !in MIN_COMPACT_CONTACT_COUNT..
            MAX_COMPACT_CONTACT_COUNT
        ) return false
        // Translation to the FlutterView origin cancels out when measuring a
        // cluster diameter. Work directly in display pixels so this evidence
        // scan does not allocate or query the view origin for every contact.
        val density = coordinateDensity(eventTime)
        var minX = Double.POSITIVE_INFINITY
        var minY = Double.POSITIVE_INFINITY
        var maxX = Double.NEGATIVE_INFINITY
        var maxY = Double.NEGATIVE_INFINITY
        for (pointerIndex in 0 until pointerCount) {
            if (!isEligibleTool(pointerIndex)) continue
            val x = rawX(this, pointerIndex).toDouble() / density
            val y = rawY(this, pointerIndex).toDouble() / density
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
        val normalizedSize: Double,
        val normalizedPressure: Double,
        val contactCount: Int,
        val hasMeasuredTouchAxes: Boolean,
    )

    private class Trace(
        val pointerId: Int,
        val deviceId: Int,
        val downTimeMillis: Long,
        var lastEventTimeMillis: Long,
        var lastToolType: Int,
    ) {
        val startedAsPalm: Boolean = lastToolType == HIDDEN_TOOL_TYPE_PALM
        var nativeReason: String? = null
        var peakContactCount: Int = 1
        var compactMultiContactEvidence: Boolean = false
        var overlappedStylusProtection: Boolean = false
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

        fun isLastPositionNear(
            guard: StylusPalmGuard,
            eventTimeMillis: Long,
        ): Boolean {
            val sample = lastObservedSample ?: return false
            return guard.isStylusNear(
                sample.xDp,
                sample.yDp,
                eventTimeMillis,
            )
        }

        // Movement proves the wipe intent later in PalmTraceDecision, but it
        // is never palm evidence. Android may cancel ordinary one-/two-finger
        // navigation after a long movement; replaying that path would turn a
        // benign gesture-arena transition into destructive erasing.
        fun hasCancellationEvidence(): Boolean = hasStrongPalmEvidence()

        fun hasStrongPalmEvidence(): Boolean =
            PalmContactEvidence.isStrongEraserEvidence(
                compactMultiContact = compactMultiContactEvidence,
            )

    }

    private fun MotionEvent.isStylusTool(pointerIndex: Int): Boolean {
        val toolType = getToolType(pointerIndex)
        return toolType == MotionEvent.TOOL_TYPE_STYLUS ||
            toolType == MotionEvent.TOOL_TYPE_ERASER
    }

    private fun MotionEvent.hasOnlyTouchTools(): Boolean {
        if (pointerCount <= 0) return false
        for (pointerIndex in 0 until pointerCount) {
            val toolType = getToolType(pointerIndex)
            if (toolType != MotionEvent.TOOL_TYPE_FINGER &&
                toolType != HIDDEN_TOOL_TYPE_PALM
            ) {
                return false
            }
        }
        return true
    }

    private fun MotionEvent.hasEligibleTouch(): Boolean {
        for (pointerIndex in 0 until pointerCount) {
            if (isEligibleTool(pointerIndex)) return true
        }
        return false
    }

    private fun MotionEvent.stylusPointerKey(
        pointerIndex: Int,
    ): StylusPalmGuard.PointerKey {
        val pointerId = getPointerId(pointerIndex)
        val packed =
            (deviceId.toLong() shl 32) xor
                (pointerId.toLong() and 0xffffffffL)
        stylusPointerKeys.get(packed)?.let { return it }
        if (stylusPointerKeys.size() >= MAX_CACHED_STYLUS_POINTER_KEYS) {
            // A real Android pointer stream cannot approach this bound. The
            // cap only protects against vendor drivers which recycle neither
            // pointer IDs nor complete UP/CANCEL packets.
            stylusPointerKeys.clear()
        }
        return StylusPalmGuard.PointerKey(deviceId, pointerId).also {
            stylusPointerKeys.put(packed, it)
        }
    }

    private fun MotionEvent.guardPosition(
        pointerIndex: Int,
    ): StylusPalmGuard.Position {
        logicalViewPosition(this, pointerIndex, logicalPositionScratch)
        return StylusPalmGuard.Position(
            logicalPositionScratch[0],
            logicalPositionScratch[1],
        )
    }

    private fun MotionEvent.guardContact(
        pointerIndex: Int,
    ): StylusPalmGuard.TouchContact {
        val geometry = contactGeometryDp(this, pointerIndex)
        return StylusPalmGuard.TouchContact(
            position = guardPosition(pointerIndex),
            // The circular fallback is useful for eraser rendering but must not
            // turn every device with missing axes into a native palm.
            radiusMajorDp = if (geometry.hasMeasuredAxes) {
                geometry.measuredRadiusMajorDp
            } else {
                0.0
            },
            radiusMinorDp = if (geometry.hasMeasuredAxes) {
                geometry.measuredRadiusMinorDp
            } else {
                0.0
            },
            normalizedSize = geometry.normalizedSize,
            explicitlyPalm = getToolType(pointerIndex) == HIDDEN_TOOL_TYPE_PALM,
        )
    }

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/palm_input"
        const val METHOD_PALM_TRACE = "palmTrace"
        const val TAG = "FlowboardPalmInput"
        const val HIDDEN_TOOL_TYPE_PALM = 5
        const val REASON_TOOL_TYPE_PALM = "tool_type_palm"
        const val REASON_SYSTEM_CANCELED = "system_canceled"
        const val MAX_ACTIVE_TRACES = 16
        const val MAX_CACHED_STYLUS_POINTER_KEYS = 32
        const val COORDINATE_CACHE_MAX_AGE_MILLIS = 1_000L
        const val MAX_SAMPLES_PER_TRACE = 192
        const val INITIAL_SAMPLE_CAPACITY = 64
        const val MAX_TRACE_AGE_MILLIS = 30_000L
        const val MIN_SAMPLE_INTERVAL_MILLIS = 4L
        const val MIN_SAMPLE_DISTANCE_DP = 0.75
        const val MIN_COMPACT_CONTACT_COUNT = 3
        const val MAX_COMPACT_CONTACT_COUNT = 4
        const val MAX_COMPACT_CLUSTER_DIAMETER_DP = 120.0
    }
}
