package de.flowboardx.flowboard_x

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PaddleOcrCtcDecoderTest {
    @Test
    fun officialDictionaryMatchesExportedModelContract() {
        val yaml = File(
            "src/main/assets/handwriting/PP-OCRv6_small_rec.yml",
        ).readText(Charsets.UTF_8)

        val characters = PaddleOcrCtcDecoder.parseCharacterDictionary(yaml)

        assertEquals(18_708, characters.size)
        assertTrue("ä" in characters)
        assertTrue("ß" in characters)
        assertTrue("€" in characters)
        assertTrue("\u3000" in characters)
        assertEquals("🛅", characters.last())

        val latinIndices = PaddleOcrCtcDecoder
            .latinClassIndices(characters)
            .toSet()
        assertTrue(0 in latinIndices)
        assertTrue(characters.size + 1 in latinIndices)
        assertTrue(characters.indexOf("ä") + 1 in latinIndices)
        assertTrue(characters.indexOf("ß") + 1 in latinIndices)
        assertFalse(characters.indexOf("Ω") + 1 in latinIndices)
        assertFalse(characters.indexOf("中") + 1 in latinIndices)
        assertTrue(latinIndices.size < 2_000)
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

    @Test
    fun decoderReadsDirectOrtStyleBufferWithoutChangingItsPosition() {
        val probabilities = ByteBuffer
            .allocateDirect(6 * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        probabilities.put(floatArrayOf(0f, .9f, 0f, .8f, 0f, 0f))
        probabilities.flip()

        val result = PaddleOcrCtcDecoder.decode(
            probabilities = probabilities,
            timeSteps = 2,
            classCount = 3,
            characters = listOf("A"),
        )

        assertEquals("A", result?.text)
        assertEquals(0, probabilities.position())
    }

    @Test
    fun latinMaskIncludesGermanTextAndCommonPunctuationOnly() {
        val characters = listOf(
            "A",
            "ä",
            "ß",
            "7",
            "?",
            "€",
            "Б",
            "Ω",
            "中",
            "٢",
            "🛅",
        )

        val indices = PaddleOcrCtcDecoder.latinClassIndices(characters)

        assertEquals(
            listOf(0, 1, 2, 3, 4, 5, 6, characters.size + 1),
            indices.toList(),
        )
    }

    @Test
    fun latinMaskLetsLatinCandidateBeatNonLatinGlobalMaximum() {
        val characters = listOf("A", "Б", "中")
        val classCount = characters.size + 2
        val probabilities = floatArrayOf(
            .01f,
            .81f,
            .99f,
            .92f,
            .02f,
        )

        val result = PaddleOcrCtcDecoder.decode(
            probabilities = probabilities,
            timeSteps = 1,
            classCount = classCount,
            characters = characters,
            allowedClassIndices =
                PaddleOcrCtcDecoder.latinClassIndices(characters),
        )

        assertEquals("A", result?.text)
        assertEquals(.81, result?.confidence ?: 0.0, .001)
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
