package de.flowboardx.flowboard_x

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
            PalmContactEvidence.isBroadForStylusGuard(
                measuredTouchRadiusMajorDp = radiusMajorDp,
                normalizedSize = normalizedSize,
                explicitlyPalm = explicitlyPalm,
            )
    }

    enum class TouchPhase { START, CONTINUE, END }

    private class StylusSignal(
        var xDp: Double,
        var yDp: Double,
        var eventTimeMillis: Long,
    ) {
        fun update(
            xDp: Double,
            yDp: Double,
            eventTimeMillis: Long,
        ) {
            this.xDp = xDp
            this.yDp = yDp
            this.eventTimeMillis = eventTimeMillis
        }
    }

    private val activeStyluses = LinkedHashMap<PointerKey, StylusSignal>()
    private val hoveringStyluses = LinkedHashMap<PointerKey, StylusSignal>()
    private val recentlyReleasedStyluses = ArrayDeque<StylusSignal>()
    private val suppressedTouchStreams = LinkedHashSet<TouchStreamKey>()

    fun stylusDown(
        key: PointerKey,
        position: Position,
        eventTimeMillis: Long,
    ) = stylusDown(
        key,
        position.xDp,
        position.yDp,
        eventTimeMillis,
    )

    fun stylusDown(
        key: PointerKey,
        xDp: Double,
        yDp: Double,
        eventTimeMillis: Long,
    ) {
        if (!xDp.isFinite() || !yDp.isFinite()) return
        val active = activeStyluses[key]
        if (active == null) {
            activeStyluses[key] = StylusSignal(xDp, yDp, eventTimeMillis)
        } else {
            active.update(xDp, yDp, eventTimeMillis)
        }
        hoveringStyluses.remove(key)
        expire(eventTimeMillis)
    }

    fun stylusMove(
        key: PointerKey,
        position: Position,
        eventTimeMillis: Long,
    ) = stylusMove(
        key,
        position.xDp,
        position.yDp,
        eventTimeMillis,
    )

    fun stylusMove(
        key: PointerKey,
        xDp: Double,
        yDp: Double,
        eventTimeMillis: Long,
    ) {
        if (!xDp.isFinite() || !yDp.isFinite()) return
        activeStyluses[key]?.update(xDp, yDp, eventTimeMillis)
        expire(eventTimeMillis)
    }

    fun stylusUp(
        key: PointerKey,
        position: Position?,
        eventTimeMillis: Long,
    ) {
        val previous = activeStyluses.remove(key)
        val releasePosition = position?.takeIf { it.isFinite() }
        val releaseX = releasePosition?.xDp ?: previous?.xDp
        val releaseY = releasePosition?.yDp ?: previous?.yDp
        if (releaseX != null && releaseY != null) {
            recentlyReleasedStyluses.addLast(
                StylusSignal(releaseX, releaseY, eventTimeMillis),
            )
        }
        expire(eventTimeMillis)
    }

    fun stylusHover(
        key: PointerKey,
        position: Position,
        eventTimeMillis: Long,
    ) = stylusHover(
        key,
        position.xDp,
        position.yDp,
        eventTimeMillis,
    )

    fun stylusHover(
        key: PointerKey,
        xDp: Double,
        yDp: Double,
        eventTimeMillis: Long,
    ) {
        if (!xDp.isFinite() || !yDp.isFinite()) return
        val hovering = hoveringStyluses[key]
        if (hovering == null) {
            hoveringStyluses[key] = StylusSignal(xDp, yDp, eventTimeMillis)
        } else {
            hovering.update(xDp, yDp, eventTimeMillis)
        }
        expire(eventTimeMillis)
    }

    fun stylusHoverExit(
        key: PointerKey,
        position: Position?,
        eventTimeMillis: Long,
    ) {
        val previous = hoveringStyluses.remove(key)
        val releasePosition = position?.takeIf { it.isFinite() }
        val releaseX = releasePosition?.xDp ?: previous?.xDp
        val releaseY = releasePosition?.yDp ?: previous?.yDp
        if (releaseX != null && releaseY != null) {
            recentlyReleasedStyluses.addLast(
                StylusSignal(releaseX, releaseY, eventTimeMillis),
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

    /** Removes stale native lifetimes without creating release protection. */
    fun discardStyluses(keys: Iterable<PointerKey>) {
        for (key in keys) {
            activeStyluses.remove(key)
            hoveringStyluses.remove(key)
        }
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
        // The decision is made exactly once, on DOWN. Building contact
        // geometry again for every MOVE cannot change the result and adds work
        // to the same UI thread which is dispatching high-rate pen samples.
        if (phase != TouchPhase.START) {
            val suppressed = suppressedTouchStreams.contains(key)
            if (phase == TouchPhase.END) suppressedTouchStreams.remove(key)
            return suppressed
        }
        expire(eventTimeMillis)
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
                        contact.position.xDp,
                        contact.position.yDp,
                        CLOSE_ACTIVE_STYLUS_RADIUS_DP,
                    )
                }
        }
        if (broadContactNearPen ||
            splitPalmNearPen ||
            fingerAlmostOnActiveTip
        ) {
            latchSuppressedTouchStream(key)
        }
        return suppressedTouchStreams.contains(key)
    }

    fun isStylusNear(
        position: Position,
        eventTimeMillis: Long,
    ): Boolean = isStylusNear(
        position.xDp,
        position.yDp,
        eventTimeMillis,
    )

    fun isStylusNear(
        xDp: Double,
        yDp: Double,
        eventTimeMillis: Long,
    ): Boolean {
        if (!xDp.isFinite() || !yDp.isFinite()) return false
        expire(eventTimeMillis)
        for (signal in activeStyluses.values) {
            if (eventTimeMillis - signal.eventTimeMillis <=
                activeTimeoutMillis &&
                signal.protects(xDp, yDp)
            ) {
                return true
            }
        }
        for (signal in hoveringStyluses.values) {
            if (eventTimeMillis - signal.eventTimeMillis <=
                hoverTimeoutMillis &&
                signal.protects(xDp, yDp)
            ) {
                return true
            }
        }
        for (signal in recentlyReleasedStyluses) {
            if (eventTimeMillis - signal.eventTimeMillis <=
                releaseGraceMillis &&
                signal.protects(xDp, yDp)
            ) {
                return true
            }
        }
        return false
    }

    fun clear() {
        activeStyluses.clear()
        hoveringStyluses.clear()
        recentlyReleasedStyluses.clear()
        suppressedTouchStreams.clear()
    }

    private fun latchSuppressedTouchStream(key: TouchStreamKey) {
        if (key in suppressedTouchStreams) return
        while (suppressedTouchStreams.size >= MAX_SUPPRESSED_TOUCH_STREAMS) {
            val iterator = suppressedTouchStreams.iterator()
            if (!iterator.hasNext()) break
            iterator.next()
            iterator.remove()
        }
        suppressedTouchStreams.add(key)
    }

    private fun expire(eventTimeMillis: Long) {
        removeExpired(activeStyluses, eventTimeMillis, activeTimeoutMillis)
        removeExpired(hoveringStyluses, eventTimeMillis, hoverTimeoutMillis)
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

    private fun removeExpired(
        signals: MutableMap<PointerKey, StylusSignal>,
        eventTimeMillis: Long,
        timeoutMillis: Long,
    ) {
        val iterator = signals.entries.iterator()
        while (iterator.hasNext()) {
            val signal = iterator.next().value
            if (eventTimeMillis - signal.eventTimeMillis > timeoutMillis) {
                iterator.remove()
            }
        }
    }

    private fun StylusSignal.protects(
        touchXDp: Double,
        touchYDp: Double,
    ): Boolean {
        val dx = touchXDp - xDp
        val dy = touchYDp - yDp
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
        touchXDp: Double,
        touchYDp: Double,
        radius: Double,
    ): Boolean {
        val deltaX = xDp - touchXDp
        val deltaY = yDp - touchYDp
        return deltaX * deltaX + deltaY * deltaY <= radius * radius
    }

    private companion object {
        // Contact evidence permits a useful palm corridor without swallowing a
        // second participant's ordinary fingertip across the board.
        const val DEFAULT_PROTECTION_RADIUS_DP = 300.0
        const val LOWER_CORRIDOR_FACTOR = 1.30
        const val UPPER_CORRIDOR_FACTOR = 0.60
        const val CLOSE_ACTIVE_STYLUS_RADIUS_DP = 56.0
        const val MIN_SPLIT_PALM_CONTACTS = 3
        const val DEFAULT_HOVER_TIMEOUT_MILLIS = 900L
        const val DEFAULT_RELEASE_GRACE_MILLIS = 160L
        const val DEFAULT_ACTIVE_TIMEOUT_MILLIS = 30_000L
        const val MAX_RELEASE_SIGNALS = 8
        // Android cannot expose this many simultaneous gesture streams. The
        // cap only protects long sessions from vendor drivers which omit an
        // UP/CANCEL packet and would otherwise grow the latch set forever.
        const val MAX_SUPPRESSED_TOUCH_STREAMS = 32
    }
}
