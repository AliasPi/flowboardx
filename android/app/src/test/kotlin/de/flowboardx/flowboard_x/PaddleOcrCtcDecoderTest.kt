package de.flowboardx.flowboard_x

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PaddleOcrCtcDecoderTest {
    @Test
    fun officialDictionaryMatchesExportedModelContract() {
        val yaml = File(
            "src/main/assets/handwriting/latin_PP-OCRv5_mobile_rec.yml",
        ).readText(Charsets.UTF_8)

        val characters = PaddleOcrCtcDecoder.parseCharacterDictionary(yaml)

        assertEquals(836, characters.size)
        assertTrue("ä" in characters)
        assertTrue("ß" in characters)
        assertTrue("€" in characters)
        assertEquals("☺", characters.last())
    }

    @Test
    fun decoderCollapsesCtcRepeatsAndRestoresSpaces() {
        val characters = listOf("H", "i", "a", "l")
        val classCount = characters.size + 2
        // blank, H, H, blank, i, space, a, l, l, blank, l
        val winningIndices = intArrayOf(0, 1, 1, 0, 2, 5, 3, 4, 4, 0, 4)
        val probabilities = FloatArray(winningIndices.size * classCount)
        winningIndices.forEachIndexed { time, winner ->
            probabilities[time * classCount + winner] = .92f
        }

        val result = PaddleOcrCtcDecoder.decode(
            probabilities,
            winningIndices.size,
            classCount,
            characters,
        )

        assertNotNull(result)
        assertEquals("Hi all", result!!.text)
        assertEquals(.92, result.confidence, .001)
    }

    @Test(expected = IllegalArgumentException::class)
    fun decoderRejectsACharacterModelMismatch() {
        PaddleOcrCtcDecoder.decode(
            probabilities = FloatArray(3),
            timeSteps = 1,
            classCount = 3,
            characters = emptyList(),
        )
    }
}
