package de.flowboardx.flowboard_x

import java.text.Normalizer
import java.util.Locale
import kotlin.math.max

/**
 * Language-aware normalization and quality policy for OCR handwriting output.
 *
 * The recognizer's Latin model contains characters from several scripts and a
 * broad symbol alphabet. A visually ambiguous Greek or Cyrillic glyph can
 * therefore win even for a German request. This policy rejects mixed/non-Latin
 * words for Latin language tags while retaining German umlauts, sharp-s and
 * other legitimate Latin extensions.
 *
 * It deliberately does not contain a dictionary. Names, subject terminology,
 * numbers and formulas remain valid without a network or a vocabulary update.
 */
object HandwritingTextQualityPolicy {
    /**
     * Normalizes model output before candidate comparison or persistence.
     *
     * - canonicalizes equivalent accents to NFC;
     * - normalizes line endings;
     * - collapses horizontal Unicode whitespace;
     * - removes empty lines and unsafe/invisible formatting code points.
     */
    fun normalize(rawText: String): String {
        if (rawText.isEmpty()) return ""
        val canonical = Normalizer.normalize(rawText, Normalizer.Form.NFC)
        val cleaned = StringBuilder(canonical.length)
        var index = 0
        var pendingSpace = false
        while (index < canonical.length) {
            val codePoint = canonical.codePointAt(index)
            index += Character.charCount(codePoint)
            when {
                codePoint == CARRIAGE_RETURN -> {
                    if (index < canonical.length &&
                        canonical.codePointAt(index) == LINE_FEED
                    ) {
                        index += Character.charCount(LINE_FEED)
                    }
                    trimTrailingSpace(cleaned)
                    appendLineBreak(cleaned)
                    pendingSpace = false
                }
                codePoint == LINE_FEED -> {
                    trimTrailingSpace(cleaned)
                    appendLineBreak(cleaned)
                    pendingSpace = false
                }
                codePoint == NULL || Character.isWhitespace(codePoint) -> {
                    pendingSpace = cleaned.isNotEmpty() && cleaned.last() != '\n'
                }
                isUnsafeOrInvisible(codePoint) -> {
                    // Do not let bidi controls, unpaired surrogates or private
                    // model tokens enter a TextObject.
                }
                else -> {
                    if (pendingSpace) cleaned.append(' ')
                    cleaned.appendCodePoint(codePoint)
                    pendingSpace = false
                }
            }
        }
        trimTrailingSpace(cleaned)
        while (cleaned.isNotEmpty() && cleaned.last() == '\n') {
            cleaned.setLength(cleaned.length - 1)
        }
        return Normalizer.normalize(cleaned.toString(), Normalizer.Form.NFC)
    }

    /**
     * Evaluates one recognizer candidate for the requested language.
     *
     * [quality] is in `[0, 1]`. [accepted] is the explicit safety decision and
     * should be checked independently of any model-confidence threshold.
     */
    fun evaluate(
        rawText: String,
        languageTag: String = DEFAULT_LANGUAGE_TAG,
    ): HandwritingTextQuality {
        val normalized = normalize(rawText)
        val latinLanguage = isLatinLanguageTag(languageTag)
        val unsafeInputCount = countUnsafeOrInvisible(rawText)
        if (normalized.isEmpty()) {
            return HandwritingTextQuality(
                normalizedText = "",
                quality = 0.0,
                disposition = HandwritingTextDisposition.empty,
                isLatinLanguage = latinLanguage,
                visibleCharacterCount = 0,
                latinLetterCount = 0,
                digitCount = 0,
                nonLatinAlphaNumericCount = 0,
                decorationCount = 0,
                unsafeInputCount = unsafeInputCount,
            )
        }

        var visibleCount = 0
        var latinLetterCount = 0
        var digitCount = 0
        var nonLatinAlphaNumericCount = 0
        var decorationCount = 0
        var unsupportedCount = 0
        var previousBaseWasLatin = false
        var index = 0
        while (index < normalized.length) {
            val codePoint = normalized.codePointAt(index)
            index += Character.charCount(codePoint)
            if (Character.isWhitespace(codePoint)) {
                previousBaseWasLatin = false
                continue
            }
            visibleCount++
            val script = Character.UnicodeScript.of(codePoint)
            val type = Character.getType(codePoint)
            when {
                Character.isLetter(codePoint) -> {
                    if (script == Character.UnicodeScript.LATIN) {
                        latinLetterCount++
                        previousBaseWasLatin = true
                    } else {
                        nonLatinAlphaNumericCount++
                        previousBaseWasLatin = false
                    }
                }
                Character.isDigit(codePoint) || isNumericType(type) -> {
                    if (script == Character.UnicodeScript.COMMON ||
                        script == Character.UnicodeScript.INHERITED ||
                        script == Character.UnicodeScript.LATIN
                    ) {
                        digitCount++
                    } else {
                        nonLatinAlphaNumericCount++
                    }
                    previousBaseWasLatin = false
                }
                isCombiningMark(type) -> {
                    if (previousBaseWasLatin) {
                        decorationCount++
                    } else {
                        unsupportedCount++
                    }
                }
                isSafeDecoration(type, codePoint) -> {
                    decorationCount++
                    previousBaseWasLatin = false
                }
                else -> {
                    unsupportedCount++
                    previousBaseWasLatin = false
                }
            }
        }

        val informativeCount =
            latinLetterCount + digitCount +
                if (latinLanguage) 0 else nonLatinAlphaNumericCount
        val supportedCount =
            informativeCount + decorationCount
        val visibleDenominator = max(1, visibleCount).toDouble()
        val informativeRatio = informativeCount / visibleDenominator
        val supportedRatio =
            (supportedCount.toDouble() / visibleDenominator).coerceIn(0.0, 1.0)
        var quality =
            informativeRatio * INFORMATIVE_WEIGHT +
                supportedRatio * SUPPORTED_WEIGHT

        val disposition = when {
            unsafeInputCount > 0 || unsupportedCount > 0 ->
                HandwritingTextDisposition.unsafeCharacters
            latinLanguage && nonLatinAlphaNumericCount > 0 ->
                HandwritingTextDisposition.nonLatinScript
            informativeCount == 0 ->
                HandwritingTextDisposition.noTextContent
            else -> HandwritingTextDisposition.accepted
        }
        quality = when (disposition) {
            HandwritingTextDisposition.accepted -> quality
            HandwritingTextDisposition.nonLatinScript ->
                minOf(quality, NON_LATIN_QUALITY_CEILING)
            HandwritingTextDisposition.unsafeCharacters ->
                minOf(quality, UNSAFE_QUALITY_CEILING)
            HandwritingTextDisposition.noTextContent ->
                minOf(quality, NO_CONTENT_QUALITY_CEILING)
            HandwritingTextDisposition.empty -> 0.0
        }.coerceIn(0.0, 1.0)

        return HandwritingTextQuality(
            normalizedText = normalized,
            quality = quality,
            disposition = disposition,
            isLatinLanguage = latinLanguage,
            visibleCharacterCount = visibleCount,
            latinLetterCount = latinLetterCount,
            digitCount = digitCount,
            nonLatinAlphaNumericCount = nonLatinAlphaNumericCount,
            decorationCount = decorationCount,
            unsafeInputCount = unsafeInputCount + unsupportedCount,
        )
    }

    fun isLatinLanguageTag(languageTag: String): Boolean {
        val primary = languageTag
            .trim()
            .substringBefore('-')
            .substringBefore('_')
            .lowercase(Locale.ROOT)
        return primary in LATIN_LANGUAGE_CODES
    }

    private fun countUnsafeOrInvisible(value: String): Int {
        var result = 0
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            index += Character.charCount(codePoint)
            if (isUnsafeOrInvisible(codePoint)) result++
        }
        return result
    }

    private fun isUnsafeOrInvisible(codePoint: Int): Boolean {
        if (codePoint == REPLACEMENT_CHARACTER) return true
        return when (Character.getType(codePoint)) {
            Character.CONTROL.toInt() ->
                codePoint != NULL &&
                    codePoint != CARRIAGE_RETURN &&
                    codePoint != LINE_FEED &&
                    !Character.isWhitespace(codePoint)
            Character.FORMAT.toInt(),
            Character.PRIVATE_USE.toInt(),
            Character.SURROGATE.toInt(),
            Character.UNASSIGNED.toInt(),
            -> true
            else -> false
        }
    }

    private fun isCombiningMark(type: Int): Boolean =
        type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt()

    private fun isNumericType(type: Int): Boolean =
        type == Character.DECIMAL_DIGIT_NUMBER.toInt() ||
            type == Character.LETTER_NUMBER.toInt() ||
            type == Character.OTHER_NUMBER.toInt()

    private fun isSafeDecoration(type: Int, codePoint: Int): Boolean {
        if (codePoint == REPLACEMENT_CHARACTER) return false
        return when (type) {
            Character.CONNECTOR_PUNCTUATION.toInt(),
            Character.DASH_PUNCTUATION.toInt(),
            Character.START_PUNCTUATION.toInt(),
            Character.END_PUNCTUATION.toInt(),
            Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
            Character.FINAL_QUOTE_PUNCTUATION.toInt(),
            Character.OTHER_PUNCTUATION.toInt(),
            Character.MATH_SYMBOL.toInt(),
            Character.CURRENCY_SYMBOL.toInt(),
            Character.MODIFIER_SYMBOL.toInt(),
            Character.OTHER_SYMBOL.toInt(),
            -> true
            else -> false
        }
    }

    private fun trimTrailingSpace(builder: StringBuilder) {
        while (builder.isNotEmpty() && builder.last() == ' ') {
            builder.setLength(builder.length - 1)
        }
    }

    private fun appendLineBreak(builder: StringBuilder) {
        if (builder.isNotEmpty() && builder.last() != '\n') {
            builder.append('\n')
        }
    }

    private const val DEFAULT_LANGUAGE_TAG = "de-DE"
    private const val NULL = 0
    private const val LINE_FEED = 0x0A
    private const val CARRIAGE_RETURN = 0x0D
    private const val REPLACEMENT_CHARACTER = 0xFFFD
    private const val INFORMATIVE_WEIGHT = 0.65
    private const val SUPPORTED_WEIGHT = 0.35
    private const val NON_LATIN_QUALITY_CEILING = 0.35
    private const val UNSAFE_QUALITY_CEILING = 0.25
    private const val NO_CONTENT_QUALITY_CEILING = 0.20

    private val LATIN_LANGUAGE_CODES = setOf(
        "af",
        "ca",
        "cs",
        "cy",
        "da",
        "de",
        "en",
        "es",
        "et",
        "eu",
        "fi",
        "fr",
        "ga",
        "gl",
        "hr",
        "hu",
        "id",
        "is",
        "it",
        "la",
        "lt",
        "lv",
        "ms",
        "mt",
        "nl",
        "no",
        "pl",
        "pt",
        "ro",
        "sk",
        "sl",
        "sq",
        "sv",
        "sw",
        "tr",
        "vi",
    )
}

enum class HandwritingTextDisposition {
    accepted,
    empty,
    noTextContent,
    nonLatinScript,
    unsafeCharacters,
}

data class HandwritingTextQuality(
    val normalizedText: String,
    val quality: Double,
    val disposition: HandwritingTextDisposition,
    val isLatinLanguage: Boolean,
    val visibleCharacterCount: Int,
    val latinLetterCount: Int,
    val digitCount: Int,
    val nonLatinAlphaNumericCount: Int,
    val decorationCount: Int,
    val unsafeInputCount: Int,
) {
    val accepted: Boolean
        get() = disposition == HandwritingTextDisposition.accepted
}
