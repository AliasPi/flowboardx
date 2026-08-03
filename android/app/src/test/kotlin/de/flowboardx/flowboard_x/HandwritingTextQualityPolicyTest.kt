package de.flowboardx.flowboard_x

import java.text.Normalizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HandwritingTextQualityPolicyTest {
    @Test
    fun `normalization canonicalizes German accents and whitespace`() {
        val decomposed = "  Gru\u0308ße\t  aus\r\n\n Ko\u0308ln  "

        val normalized = HandwritingTextQualityPolicy.normalize(decomposed)

        assertEquals("Grüße aus\nKöln", normalized)
        assertTrue(Normalizer.isNormalized(normalized, Normalizer.Form.NFC))
    }

    @Test
    fun `German umlauts and sharp s are accepted as Latin text`() {
        val result = HandwritingTextQualityPolicy.evaluate(
            "Ärger, Öl, Übergröße und Fußgänger",
            "de-DE",
        )

        assertTrue(result.accepted)
        assertEquals(0, result.nonLatinAlphaNumericCount)
        assertEquals(0, result.unsafeInputCount)
        assertTrue(result.quality > .80)
    }

    @Test
    fun `extended Latin languages retain their native diacritics`() {
        val candidates = listOf(
            "fr-FR" to "Élève français",
            "pl-PL" to "Zażółć gęślą jaźń",
            "tr-TR" to "Çığ öğütür",
            "vi-VN" to "Tiếng Việt",
        )

        candidates.forEach { (languageTag, text) ->
            val result = HandwritingTextQualityPolicy.evaluate(text, languageTag)
            assertTrue("$languageTag should accept $text", result.accepted)
            assertEquals(0, result.nonLatinAlphaNumericCount)
        }
    }

    @Test
    fun `mixed Greek homoglyph in a German word is rejected`() {
        // U+03B1 GREEK SMALL LETTER ALPHA visually resembles Latin a.
        val result = HandwritingTextQualityPolicy.evaluate("Mαthe", "de-DE")

        assertFalse(result.accepted)
        assertEquals(
            HandwritingTextDisposition.nonLatinScript,
            result.disposition,
        )
        assertEquals(1, result.nonLatinAlphaNumericCount)
        assertTrue(result.quality <= .35)
    }

    @Test
    fun `mixed Cyrillic homoglyph in otherwise Latin OCR is rejected`() {
        // The first character is Cyrillic capital Es, not Latin C.
        val result = HandwritingTextQualityPolicy.evaluate("Сhemie", "de-DE")

        assertFalse(result.accepted)
        assertEquals(
            HandwritingTextDisposition.nonLatinScript,
            result.disposition,
        )
    }

    @Test
    fun `entirely non Latin candidate is rejected for German`() {
        val result = HandwritingTextQualityPolicy.evaluate("Привет", "de")

        assertFalse(result.accepted)
        assertEquals(0, result.latinLetterCount)
        assertEquals(6, result.nonLatinAlphaNumericCount)
        assertEquals(
            HandwritingTextDisposition.nonLatinScript,
            result.disposition,
        )
    }

    @Test
    fun `same script is not rejected when language is not Latin`() {
        val result = HandwritingTextQualityPolicy.evaluate("Привет", "ru-RU")

        assertTrue(result.accepted)
        assertFalse(result.isLatinLanguage)
        assertTrue(result.quality > .95)
    }

    @Test
    fun `numbers and classroom formulas remain valid`() {
        val values = listOf(
            "2026",
            "3 + 4 = 7",
            "12,5 €",
            "x² + y² = 25",
        )

        values.forEach { value ->
            val result = HandwritingTextQualityPolicy.evaluate(value, "de-DE")
            assertTrue("$value should be accepted", result.accepted)
            assertTrue(result.quality >= .60)
        }
    }

    @Test
    fun `punctuation or emoji without text content is not accepted`() {
        listOf("...", "—", "🙂").forEach { value ->
            val result = HandwritingTextQualityPolicy.evaluate(value, "de-DE")
            assertFalse(value, result.accepted)
            assertEquals(
                HandwritingTextDisposition.noTextContent,
                result.disposition,
            )
            assertTrue(result.quality <= .20)
        }
    }

    @Test
    fun `replacement and bidi formatting characters are unsafe`() {
        val replacement = HandwritingTextQualityPolicy.evaluate(
            "Hal\uFFFDo",
            "de-DE",
        )
        val bidi = HandwritingTextQualityPolicy.evaluate(
            "Hallo\u202Etxt",
            "de-DE",
        )

        assertFalse(replacement.accepted)
        assertFalse(bidi.accepted)
        assertEquals(
            HandwritingTextDisposition.unsafeCharacters,
            replacement.disposition,
        )
        assertEquals(
            HandwritingTextDisposition.unsafeCharacters,
            bidi.disposition,
        )
        assertEquals("Hallotxt", bidi.normalizedText)
        assertTrue(replacement.unsafeInputCount > 0)
        assertTrue(bidi.unsafeInputCount > 0)
    }

    @Test
    fun `null separators are normalized without rejecting otherwise valid text`() {
        val result = HandwritingTextQualityPolicy.evaluate(
            "Guten\u0000Morgen",
            "de-DE",
        )

        assertTrue(result.accepted)
        assertEquals("Guten Morgen", result.normalizedText)
    }

    @Test
    fun `non Latin numerals are rejected for Latin language requests`() {
        val result = HandwritingTextQualityPolicy.evaluate("١٢٣", "de-DE")

        assertFalse(result.accepted)
        assertEquals(3, result.nonLatinAlphaNumericCount)
        assertEquals(
            HandwritingTextDisposition.nonLatinScript,
            result.disposition,
        )
    }

    @Test
    fun `language tags accept case region and underscore variants`() {
        assertTrue(HandwritingTextQualityPolicy.isLatinLanguageTag("DE-de"))
        assertTrue(HandwritingTextQualityPolicy.isLatinLanguageTag("pt_BR"))
        assertFalse(HandwritingTextQualityPolicy.isLatinLanguageTag("el-GR"))
        assertFalse(HandwritingTextQualityPolicy.isLatinLanguageTag(""))
    }

    @Test
    fun `empty and whitespace only candidates are stable`() {
        listOf("", "  \t\r\n ").forEach { value ->
            val result = HandwritingTextQualityPolicy.evaluate(value)
            assertFalse(result.accepted)
            assertEquals("", result.normalizedText)
            assertEquals(0.0, result.quality, 0.0)
            assertEquals(HandwritingTextDisposition.empty, result.disposition)
        }
    }
}
