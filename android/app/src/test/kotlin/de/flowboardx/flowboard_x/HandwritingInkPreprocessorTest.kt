package de.flowboardx.flowboard_x

import org.junit.Assert.assertEquals
import org.junit.Test

class HandwritingInkPreprocessorTest {
    @Test
    fun `detached umlaut dots stay with their baseline`() {
        val firstBody = stroke(10f, 30f, 24f, 64f, 1_000L)
        val firstDot = stroke(14f, 18f, 15f, 19f, 2_000L)
        val secondDot = stroke(20f, 18f, 21f, 19f, 3_000L)
        val secondLine = stroke(8f, 105f, 30f, 138f, 4_000L)

        val lines = HandwritingInkPreprocessor.splitIntoLines(
            listOf(firstBody, firstDot, secondDot, secondLine),
        )

        assertEquals(2, lines.size)
        assertEquals(3, lines.first().size)
        assertEquals(1, lines.last().size)
    }

    @Test
    fun `smartboard sized umlaut loops do not become their own line`() {
        val body = stroke(10f, 30f, 26f, 66f, 1_000L)
        val firstLoop = stroke(12f, 17f, 16f, 21f, 2_000L)
        val secondLoop = stroke(20f, 17f, 24f, 21f, 3_000L)
        val secondLine = stroke(8f, 104f, 30f, 140f, 4_000L)

        val lines = HandwritingInkPreprocessor.splitIntoLines(
            listOf(body, firstLoop, secondLoop, secondLine),
        )

        assertEquals(2, lines.size)
        assertEquals(3, lines.first().size)
    }

    @Test
    fun `ascenders and descenders do not chain neighbouring lines`() {
        val tallFirstLine = stroke(10f, 10f, 22f, 78f, 1_000L)
        val regularFirstLine = stroke(30f, 35f, 46f, 68f, 2_000L)
        val regularSecondLine = stroke(8f, 96f, 26f, 132f, 3_000L)
        val tallSecondLine = stroke(32f, 82f, 47f, 142f, 4_000L)

        val lines = HandwritingInkPreprocessor.splitIntoLines(
            listOf(tallFirstLine, regularFirstLine, regularSecondLine, tallSecondLine),
        )

        assertEquals(2, lines.size)
        assertEquals(2, lines[0].size)
        assertEquals(2, lines[1].size)
    }

    @Test
    fun `slow block letters stay a word while clear whitespace splits`() {
        val firstLetter = stroke(0f, 0f, 10f, 40f, 1_000_000L)
        val slowSecondLetter = stroke(16f, 0f, 27f, 40f, 3_000_000L)
        val nextWord = stroke(58f, 0f, 70f, 40f, 3_100_000L)

        val words = HandwritingInkPreprocessor.splitIntoWords(
            listOf(firstLetter, slowSecondLetter, nextWord),
        )

        assertEquals(2, words.size)
        assertEquals(2, words.first().size)
        assertEquals(1, words.last().size)
    }

    private fun stroke(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        timestampMicros: Long,
    ): List<HandwritingInkPoint> = listOf(
        HandwritingInkPoint(left, top, timestampMicros),
        HandwritingInkPoint(right, bottom, timestampMicros + 1_000L),
    )
}
