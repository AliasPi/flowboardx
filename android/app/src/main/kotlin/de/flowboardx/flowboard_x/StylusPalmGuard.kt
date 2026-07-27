package de.flowboardx.flowboard_x

import kotlin.math.hypot

/**
 * Stateful, Android-independent arbitration between pen proximity and touch.
 *
 * A complete touch stream is either passed through or suppressed from its
 * initial DOWN until UP/CANCEL. Switching halfway through a stream would leave
 * Flutter with orphaned pointers and can cancel an unrelated pen stroke.
 */
internal class StylusPalmGuard(
    private val protectionRadiusDp: Double = DEFAULT_PROTECTION_RADIUS_DP,
    private val hoverTimeoutMillis: Long = DEFAULT_HOVER_TIMEOUT_MILLIS,
    private val releaseGraceMillis: Long = DEFAULT_RELEASE_GRACE_MILLIS,
    private val activeTimeoutMillis: Long = DEFAULT_ACTIVE_TIMEOUT_MILLIS,
) {
    init {
        require(protectionRadiusDp > 0.0)
        require(hoverTimeoutMillis >= 0L)
        require(releaseGraceMillis >= 0L)
        require(activeTimeoutMillis > 0L)
    }

    data class PointerKey(val deviceId: Int, val pointerId: Int)

    data class TouchStreamKey(val deviceId: Int, val downTimeMillis: Long)

    data class Position(val xDp: Double, val yDp: Double) {
        fun isFinite(): Boolean = xDp.isFinite() && yDp.isFinite()
    }

    data class TouchContact(
        val position: Position,
        val radiusMajorDp: Double = 0.0,
        val radiusMinorDp: Double = 0.0,
        val normalizedSize: Double = 0.0,
        val explicitlyPalm: Boolean = false,
    ) {
        fun isBroad(): Boolean =
            explicitlyPalm ||
                radiusMajorDp >= MIN_PALM_RADIUS_DP ||
                normalizedSize >= MIN_PALM_NORMALIZED_SIZE
    }

    enum class TouchPhase { START, CONTINUE, END }

    private data class StylusSignal(
        val position: Position,
        val eventTimeMillis: Long,
    )

    private val activeStyluses = LinkedHashMap<PointerKey, StylusSignal>()
    private val hoveringStyluses = LinkedHashMap<PointerKey, StylusSignal>()
    private val recentlyReleasedStyluses = ArrayDeque<StylusSignal>()
    private val suppressedTouchStreams = HashSet<TouchStreamKey>()

    fun stylusDown(
        key: PointerKey,
        position: Position,
        eventTimeMillis: Long,
    ) {
        if (!position.isFinite()) return
        activeStyluses[key] = StylusSignal(position, eventTimeMillis)
        hoveringStyluses.remove(key)
        expire(eventTimeMillis)
    }

    fun stylusMove(
        key: PointerKey,
        position: Position,
        eventTimeMillis: Long,
    ) {
        if (!position.isFinite()) return
        if (activeStyluses.containsKey(key)) {
            activeStyluses[key] = StylusSignal(position, eventTimeMillis)
        }
        expire(eventTimeMillis)
    }

    fun stylusUp(
        key: PointerKey,
        position: Position?,
        eventTimeMillis: Long,
    ) {
        val previous = activeStyluses.remove(key)
        val releasePosition = position?.takeIf { it.isFinite() }
            ?: previous?.position
        if (releasePosition != null) {
            recentlyReleasedStyluses.addLast(
                StylusSignal(releasePosition, eventTimeMillis),
            )
        }
        expire(eventTimeMillis)
    }

    fun stylusHover(
        key: PointerKey,
        position: Position,
        eventTimeMillis: Long,
    ) {
        if (!position.isFinite()) return
        hoveringStyluses[key] = StylusSignal(position, eventTimeMillis)
        expire(eventTimeMillis)
    }

    fun stylusHoverExit(
        key: PointerKey,
        position: Position?,
        eventTimeMillis: Long,
    ) {
        val previous = hoveringStyluses.remove(key)
        val releasePosition = position?.takeIf { it.isFinite() }
            ?: previous?.position
        if (releasePosition != null) {
            recentlyReleasedStyluses.addLast(
                StylusSignal(releasePosition, eventTimeMillis),
            )
        }
        expire(eventTimeMillis)
    }

    fun cancelStyluses(
        keys: Iterable<PointerKey>,
        eventTimeMillis: Long,
    ) {
        for (key in keys) stylusUp(key, null, eventTimeMillis)
    }

    /**
     * Returns true only for a stream which started near a live/recent pen.
     *
     * Broad contacts use an asymmetric pen-to-hand corridor: a hand normally
     * rests below/beside the tip, so protection reaches farther down than up.
     * Ordinary fingertips are preserved unless they start almost on an active
     * pen tip. Three compact-looking contacts are treated as one split palm.
     */
    fun shouldSuppressTouch(
        key: TouchStreamKey,
        phase: TouchPhase,
        touchContacts: Iterable<TouchContact>,
        eventTimeMillis: Long,
    ): Boolean {
        expire(eventTimeMillis)
        if (phase == TouchPhase.START) {
            val contacts = touchContacts.filter {
                it.position.isFinite()
            }.toList()
            val broadContactNearPen = contacts.any { contact ->
                contact.isBroad() &&
                    isStylusNear(contact.position, eventTimeMillis)
            }
            val splitPalmNearPen =
                contacts.size >= MIN_SPLIT_PALM_CONTACTS &&
                    contacts.any {
                        isStylusNear(it.position, eventTimeMillis)
                    }
            val fingerAlmostOnActiveTip = contacts.any { contact ->
                !contact.isBroad() &&
                    activeStyluses.values.any { signal ->
                        signal.isWithinCircular(
                            contact.position,
                            CLOSE_ACTIVE_STYLUS_RADIUS_DP,
                        )
                    }
            }
            if (broadContactNearPen ||
                splitPalmNearPen ||
                fingerAlmostOnActiveTip
            ) {
                suppressedTouchStreams.add(key)
            }
        }
        val suppressed = suppressedTouchStreams.contains(key)
        if (phase == TouchPhase.END) suppressedTouchStreams.remove(key)
        return suppressed
    }

    fun isStylusNear(
        position: Position,
        eventTimeMillis: Long,
    ): Boolean {
        if (!position.isFinite()) return false
        expire(eventTimeMillis)
        return activeStyluses.values.any {
            eventTimeMillis - it.eventTimeMillis <= activeTimeoutMillis &&
                it.protects(position)
        } ||
            hoveringStyluses.values.any {
                eventTimeMillis - it.eventTimeMillis <= hoverTimeoutMillis &&
                    it.protects(position)
            } ||
            recentlyReleasedStyluses.any {
                eventTimeMillis - it.eventTimeMillis <= releaseGraceMillis &&
                    it.protects(position)
            }
    }

    fun clear() {
        activeStyluses.clear()
        hoveringStyluses.clear()
        recentlyReleasedStyluses.clear()
        suppressedTouchStreams.clear()
    }

    private fun expire(eventTimeMillis: Long) {
        activeStyluses.entries.removeAll { (_, signal) ->
            eventTimeMillis - signal.eventTimeMillis > activeTimeoutMillis
        }
        hoveringStyluses.entries.removeAll { (_, signal) ->
            eventTimeMillis - signal.eventTimeMillis > hoverTimeoutMillis
        }
        while (recentlyReleasedStyluses.isNotEmpty() &&
            eventTimeMillis - recentlyReleasedStyluses.first().eventTimeMillis >
            releaseGraceMillis
        ) {
            recentlyReleasedStyluses.removeFirst()
        }
        while (recentlyReleasedStyluses.size > MAX_RELEASE_SIGNALS) {
            recentlyReleasedStyluses.removeFirst()
        }
    }

    private fun StylusSignal.protects(touch: Position): Boolean {
        val dx = touch.xDp - position.xDp
        val dy = touch.yDp - position.yDp
        val horizontalRadius = protectionRadiusDp
        val verticalRadius = if (dy >= 0.0) {
            protectionRadiusDp * LOWER_CORRIDOR_FACTOR
        } else {
            protectionRadiusDp * UPPER_CORRIDOR_FACTOR
        }
        val normalizedX = dx / horizontalRadius
        val normalizedY = dy / verticalRadius
        return normalizedX * normalizedX + normalizedY * normalizedY <= 1.0
    }

    private fun StylusSignal.isWithinCircular(
        touch: Position,
        radius: Double,
    ): Boolean =
        hypot(position.xDp - touch.xDp, position.yDp - touch.yDp) <= radius

    private companion object {
        // Contact evidence permits a useful palm corridor without swallowing a
        // second participant's ordinary fingertip across the board.
        const val DEFAULT_PROTECTION_RADIUS_DP = 300.0
        const val LOWER_CORRIDOR_FACTOR = 1.30
        const val UPPER_CORRIDOR_FACTOR = 0.60
        const val CLOSE_ACTIVE_STYLUS_RADIUS_DP = 56.0
        const val MIN_PALM_RADIUS_DP = 13.0
        const val MIN_PALM_NORMALIZED_SIZE = 0.24
        const val MIN_SPLIT_PALM_CONTACTS = 3
        const val DEFAULT_HOVER_TIMEOUT_MILLIS = 900L
        const val DEFAULT_RELEASE_GRACE_MILLIS = 160L
        const val DEFAULT_ACTIVE_TIMEOUT_MILLIS = 30_000L
        const val MAX_RELEASE_SIGNALS = 8
    }
}
