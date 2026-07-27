package de.flowboardx.flowboard_x

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Geometry-only preprocessing for the bundled Android recognizer.
 *
 * This code intentionally has no Android dependency. Keeping the spatial
 * decisions separate from bitmap/OCR work makes the most error-prone part of
 * Smartboard handwriting recognition deterministic and unit-testable.
 */
object HandwritingInkPreprocessor {
    fun splitIntoLines(
        strokes: List<List<HandwritingInkPoint>>,
    ): List<List<List<HandwritingInkPoint>>> {
        val positioned = strokes
            .filter { it.isNotEmpty() }
            .map(::positioned)
        if (positioned.size < 2) {
            return if (positioned.isEmpty()) emptyList() else listOf(listOf(positioned.single().points))
        }

        val typicalHeight = robustTypicalHeight(positioned)
        val detachedThreshold = max(MIN_DETACHED_HEIGHT, typicalHeight * DETACHED_HEIGHT_RATIO)
        val detachedWidth = max(MIN_DETACHED_WIDTH, typicalHeight * DETACHED_WIDTH_RATIO)
        fun isDetached(stroke: PositionedStroke): Boolean =
            stroke.height <= detachedThreshold && stroke.width <= detachedWidth
        val detached = positioned.filter(::isDetached)
        val bodyCandidates = positioned.filterNot(::isDetached)
        val bodies = bodyCandidates
            .ifEmpty { positioned }
            .sortedWith(compareBy<PositionedStroke> { it.centerY }.thenBy { it.left })

        val lines = ArrayList<MutableInkLine>()
        for (stroke in bodies) {
            val best = lines
                .mapNotNull { line ->
                    line.acceptanceScore(stroke, typicalHeight)
                        ?.let { score -> line to score }
                }
                .minByOrNull { it.second }
                ?.first
            if (best == null) {
                lines += MutableInkLine(stroke)
            } else {
                best.addBody(stroke)
            }
        }

        // Dots, umlauts and crossbars are deliberately assigned after the
        // baseline-bearing strokes. Their tiny bounding boxes must not create
        // a separate line or pull two neighbouring baselines together.
        if (bodyCandidates.isNotEmpty()) {
            for (mark in detached.sortedBy { it.centerY }) {
                val best = lines
                    .mapNotNull { line ->
                        line.attachmentScore(mark, typicalHeight)
                            ?.let { score -> line to score }
                    }
                    .minByOrNull { it.second }
                    ?.first
                if (best == null) {
                    lines += MutableInkLine(mark)
                } else {
                    best.addMark(mark)
                }
            }
        }

        return lines
            .filter { it.strokes.isNotEmpty() }
            .sortedBy { it.top }
            .map { line ->
                line.strokes
                    .sortedWith(
                        compareBy<PositionedStroke> { it.left }
                            .thenBy { it.top }
                            .thenBy { it.startMicros ?: Long.MAX_VALUE },
                    )
                    .map { it.points }
            }
    }

    /**
     * Splits only at clear whitespace. A timestamp pause is supporting
     * evidence, never sufficient by itself; slow block-letter writing on a
     * classroom board must remain one word.
     */
    fun splitIntoWords(
        line: List<List<HandwritingInkPoint>>,
    ): List<List<List<HandwritingInkPoint>>> {
        if (line.size < 2) return listOf(line)
        val positioned = line
            .filter { it.isNotEmpty() }
            .map(::positioned)
            .sortedWith(compareBy<PositionedStroke> { it.left }.thenBy { it.top })
        if (positioned.size < 2) return listOf(line)

        val lineTop = positioned.minOf { it.top }
        val lineBottom = positioned.maxOf { it.bottom }
        val lineHeight = max(1f, lineBottom - lineTop)
        val minimumWordGap = max(MIN_WORD_GAP_WORLD, lineHeight * WORD_GAP_HEIGHT_RATIO)
        val temporalWordGap = max(
            MIN_TEMPORAL_WORD_GAP_WORLD,
            lineHeight * TEMPORAL_WORD_GAP_HEIGHT_RATIO,
        )
        val words = ArrayList<MutableList<PositionedStroke>>()
        var current = arrayListOf(positioned.first())
        var occupiedRight = positioned.first().right
        var latestTimestamp = positioned.first().endMicros
        for (index in 1 until positioned.size) {
            val stroke = positioned[index]
            val gap = stroke.left - occupiedRight
            val pause = if (stroke.startMicros != null && latestTimestamp != null) {
                stroke.startMicros - latestTimestamp
            } else {
                0L
            }
            val startsNewWord =
                gap > minimumWordGap ||
                    (gap > temporalWordGap && pause >= WORD_PAUSE_MICROS)
            if (startsNewWord) {
                words += current
                current = arrayListOf(stroke)
                occupiedRight = stroke.right
                latestTimestamp = stroke.endMicros
            } else {
                current += stroke
                occupiedRight = max(occupiedRight, stroke.right)
                val endMicros = stroke.endMicros
                if (endMicros != null &&
                    (latestTimestamp == null || endMicros > latestTimestamp)
                ) {
                    latestTimestamp = endMicros
                }
            }
        }
        words += current
        return words.map { word -> word.map { it.points } }
    }

    private fun positioned(points: List<HandwritingInkPoint>): PositionedStroke {
        var left = Float.POSITIVE_INFINITY
        var top = Float.POSITIVE_INFINITY
        var right = Float.NEGATIVE_INFINITY
        var bottom = Float.NEGATIVE_INFINITY
        points.forEach { point ->
            left = min(left, point.x)
            top = min(top, point.y)
            right = max(right, point.x)
            bottom = max(bottom, point.y)
        }
        return PositionedStroke(points, left, top, right, bottom)
    }

    private fun robustTypicalHeight(strokes: List<PositionedStroke>): Float {
        val heights = strokes
            .map { it.height }
            .filter { it > MIN_DETACHED_HEIGHT }
            .sorted()
            .ifEmpty { return 1f }
        // The upper-middle quantile is stable when a word contains several
        // dots/crossbars but does not let one tall descender dominate.
        val index = ceil((heights.lastIndex) * TYPICAL_HEIGHT_QUANTILE)
            .toInt()
            .coerceIn(0, heights.lastIndex)
        return max(1f, heights[index])
    }

    private data class PositionedStroke(
        val points: List<HandwritingInkPoint>,
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
    ) {
        val centerY: Float get() = (top + bottom) * .5f
        val width: Float get() = max(1f, right - left)
        val height: Float get() = max(1f, bottom - top)
        val startMicros: Long? = points.mapNotNull { it.timestampMicros }.minOrNull()
        val endMicros: Long? = points.mapNotNull { it.timestampMicros }.maxOrNull()
    }

    private class MutableInkLine(first: PositionedStroke) {
        val strokes = ArrayList<PositionedStroke>().apply { add(first) }
        var top = first.top
            private set
        var bottom = first.bottom
            private set
        private var left = first.left
        private var right = first.right
        private var bodyCount = 1
        private var bodyCenterTotal = first.centerY
        private var bodyBottomTotal = first.bottom

        private val bodyCenter: Float get() = bodyCenterTotal / bodyCount
        private val baseline: Float get() = bodyBottomTotal / bodyCount

        fun acceptanceScore(
            stroke: PositionedStroke,
            typicalHeight: Float,
        ): Float? {
            val centerTolerance = max(
                MIN_LINE_TOLERANCE,
                typicalHeight * LINE_CENTER_TOLERANCE_RATIO,
            )
            val baselineTolerance = max(
                MIN_LINE_TOLERANCE,
                typicalHeight * LINE_BASELINE_TOLERANCE_RATIO,
            )
            val centerDistance = abs(bodyCenter - stroke.centerY)
            val baselineDistance = abs(baseline - stroke.bottom)
            val overlap = max(0f, min(bottom, stroke.bottom) - max(top, stroke.top))
            val overlapRatio = overlap / min(max(1f, bottom - top), stroke.height)
            if (centerDistance > centerTolerance &&
                baselineDistance > baselineTolerance &&
                overlapRatio < MIN_VERTICAL_OVERLAP_RATIO
            ) {
                return null
            }
            return min(
                centerDistance / centerTolerance,
                baselineDistance / baselineTolerance,
            ) - overlapRatio * OVERLAP_SCORE_BONUS
        }

        fun attachmentScore(
            mark: PositionedStroke,
            typicalHeight: Float,
        ): Float? {
            val horizontalGap = when {
                mark.right < left -> left - mark.right
                mark.left > right -> mark.left - right
                else -> 0f
            }
            val verticalGap = when {
                mark.bottom < top -> top - mark.bottom
                mark.top > bottom -> mark.top - bottom
                else -> 0f
            }
            val maximumHorizontalGap = max(8f, typicalHeight * MARK_HORIZONTAL_REACH)
            val maximumVerticalGap = max(8f, typicalHeight * MARK_VERTICAL_REACH)
            if (horizontalGap > maximumHorizontalGap ||
                verticalGap > maximumVerticalGap
            ) {
                return null
            }
            return horizontalGap / maximumHorizontalGap +
                verticalGap / maximumVerticalGap +
                abs(bodyCenter - mark.centerY) / max(1f, typicalHeight) * .15f
        }

        fun addBody(stroke: PositionedStroke) {
            addBounds(stroke)
            bodyCount++
            bodyCenterTotal += stroke.centerY
            bodyBottomTotal += stroke.bottom
        }

        fun addMark(stroke: PositionedStroke) {
            addBounds(stroke)
        }

        private fun addBounds(stroke: PositionedStroke) {
            strokes += stroke
            left = min(left, stroke.left)
            top = min(top, stroke.top)
            right = max(right, stroke.right)
            bottom = max(bottom, stroke.bottom)
        }
    }

    private const val TYPICAL_HEIGHT_QUANTILE = .60f
    private const val MIN_DETACHED_HEIGHT = 2f
    private const val MIN_DETACHED_WIDTH = 3f
    private const val DETACHED_HEIGHT_RATIO = .32f
    private const val DETACHED_WIDTH_RATIO = 1.15f
    private const val MIN_LINE_TOLERANCE = 8f
    private const val LINE_CENTER_TOLERANCE_RATIO = .64f
    private const val LINE_BASELINE_TOLERANCE_RATIO = .58f
    private const val MIN_VERTICAL_OVERLAP_RATIO = .12f
    private const val OVERLAP_SCORE_BONUS = .20f
    private const val MARK_HORIZONTAL_REACH = 1.65f
    private const val MARK_VERTICAL_REACH = 1.30f
    private const val MIN_WORD_GAP_WORLD = 8f
    private const val WORD_GAP_HEIGHT_RATIO = .30f
    private const val MIN_TEMPORAL_WORD_GAP_WORLD = 5f
    private const val TEMPORAL_WORD_GAP_HEIGHT_RATIO = .17f
    private const val WORD_PAUSE_MICROS = 850_000L
}

data class HandwritingInkPoint(
    val x: Float,
    val y: Float,
    val timestampMicros: Long?,
)
