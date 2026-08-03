package de.flowboardx.flowboard_x

import java.nio.FloatBuffer

/**
 * Pure Kotlin post-processing for the bundled PP-OCRv6 Small model.
 *
 * Keeping this independent from Android and ONNX Runtime makes the character
 * contract and CTC collapse rules deterministic and directly unit-testable.
 */
object PaddleOcrCtcDecoder {
    data class Result(
        val text: String,
        val confidence: Double,
    )

    /**
     * Reads the `character_dict` sequence from PaddleOCR's official inference
     * YAML without adding a general-purpose YAML dependency to the APK.
     *
     * The exported model has one CTC blank class before this dictionary and
     * one space class after it.
     */
    fun parseCharacterDictionary(inferenceYaml: String): List<String> {
        val characters = ArrayList<String>()
        var inDictionary = false
        for (line in inferenceYaml.lineSequence()) {
            if (!inDictionary) {
                if (line.trim() == "character_dict:") inDictionary = true
                continue
            }
            if (!line.startsWith("  - ")) {
                if (characters.isNotEmpty()) break
                continue
            }
            // Do not trim Unicode whitespace here: PP-OCRv6 deliberately
            // contains U+3000 IDEOGRAPHIC SPACE as one vocabulary class.
            val scalar = line.substring(4)
            characters += parseYamlScalar(scalar)
        }
        require(characters.isNotEmpty()) {
            "PP-OCRv6 character dictionary is missing"
        }
        return characters
    }

    /**
     * Greedy CTC decoding for a single `[time, classes]` output.
     */
    fun decode(
        probabilities: FloatArray,
        timeSteps: Int,
        classCount: Int,
        characters: List<String>,
        allowedClassIndices: IntArray? = null,
    ): Result? {
        require(probabilities.size == expectedOutputSize(timeSteps, classCount)) {
            "Unexpected PP-OCRv6 output size"
        }
        return decodeValues(
            timeSteps = timeSteps,
            classCount = classCount,
            characters = characters,
            allowedClassIndices = allowedClassIndices,
            probabilityAt = probabilities::get,
        )
    }

    /**
     * Decodes ORT's direct output buffer without first duplicating the complete
     * native tensor into a Java FloatArray.
     */
    fun decode(
        probabilities: FloatBuffer,
        timeSteps: Int,
        classCount: Int,
        characters: List<String>,
        allowedClassIndices: IntArray? = null,
    ): Result? {
        require(
            probabilities.remaining() == expectedOutputSize(timeSteps, classCount),
        ) {
            "Unexpected PP-OCRv6 output size"
        }
        val start = probabilities.position()
        return decodeValues(
            timeSteps = timeSteps,
            classCount = classCount,
            characters = characters,
            allowedClassIndices = allowedClassIndices,
            probabilityAt = { index -> probabilities.get(start + index) },
        )
    }

    /**
     * Builds the de-DE/Latin subset once when the recognition session starts.
     *
     * PP-OCRv6 shares one 18k-class vocabulary across 50 languages. Restricting
     * argmax to the classes Flowboard accepts prevents visually similar Greek,
     * Cyrillic, CJK or emoji glyphs from displacing a Latin candidate. Blank
     * and the model's synthetic trailing space class always remain available.
     */
    fun latinClassIndices(characters: List<String>): IntArray {
        val indices = IntArray(characters.size + 2)
        var count = 0
        indices[count++] = BLANK_INDEX
        characters.forEachIndexed { index, character ->
            if (isLatinRecognitionCharacter(character)) {
                indices[count++] = index + 1
            }
        }
        indices[count++] = characters.size + 1
        return indices.copyOf(count)
    }

    private fun expectedOutputSize(timeSteps: Int, classCount: Int): Int {
        require(timeSteps >= 0) { "timeSteps must not be negative" }
        require(classCount >= 0) { "classCount must not be negative" }
        val size = timeSteps.toLong() * classCount
        require(size <= Int.MAX_VALUE) { "PP-OCRv6 output is too large" }
        return size.toInt()
    }

    private inline fun decodeValues(
        timeSteps: Int,
        classCount: Int,
        characters: List<String>,
        allowedClassIndices: IntArray?,
        probabilityAt: (Int) -> Float,
    ): Result? {
        require(timeSteps >= 0) { "timeSteps must not be negative" }
        require(classCount == characters.size + 2) {
            "Unexpected PP-OCRv6 class count: $classCount"
        }
        allowedClassIndices?.let { allowed ->
            require(allowed.isNotEmpty()) {
                "Allowed PP-OCRv6 class indices must not be empty"
            }
            var previous = -1
            allowed.forEach { index ->
                require(index in 0 until classCount && index > previous) {
                    "Allowed PP-OCRv6 class indices must be sorted and unique"
                }
                previous = index
            }
        }

        val text = StringBuilder()
        var previousIndex = -1
        var confidenceTotal = 0.0
        var emittedCount = 0
        for (time in 0 until timeSteps) {
            val offset = time * classCount
            val allowed = allowedClassIndices
            var bestIndex: Int
            var bestProbability: Float
            if (allowed == null) {
                bestIndex = 0
                bestProbability = probabilityAt(offset)
                for (index in 1 until classCount) {
                    val probability = probabilityAt(offset + index)
                    if (probability.isFinite() &&
                        (!bestProbability.isFinite() || probability > bestProbability)
                    ) {
                        bestProbability = probability
                        bestIndex = index
                    }
                }
            } else {
                bestIndex = allowed[0]
                bestProbability = probabilityAt(offset + bestIndex)
                for (position in 1 until allowed.size) {
                    val index = allowed[position]
                    val probability = probabilityAt(offset + index)
                    if (probability.isFinite() &&
                        (!bestProbability.isFinite() || probability > bestProbability)
                    ) {
                        bestProbability = probability
                        bestIndex = index
                    }
                }
            }
            if (bestIndex != BLANK_INDEX && bestIndex != previousIndex) {
                val token = when (bestIndex) {
                    classCount - 1 -> " "
                    else -> characters[bestIndex - 1]
                }
                text.append(token)
                if (bestProbability.isFinite()) {
                    confidenceTotal += bestProbability.coerceIn(0f, 1f)
                    emittedCount++
                }
            }
            previousIndex = bestIndex
        }
        val normalized = text
            .toString()
            .trim()
            .replace(MULTIPLE_SPACES, " ")
        if (normalized.isEmpty()) return null
        return Result(
            text = normalized,
            confidence = if (emittedCount == 0) {
                0.0
            } else {
                (confidenceTotal / emittedCount).coerceIn(0.0, 1.0)
            },
        )
    }

    private fun parseYamlScalar(scalar: String): String {
        require(scalar.isNotEmpty()) { "Empty PP-OCRv6 character" }
        return when {
            scalar.length >= 2 &&
                scalar.first() == '\'' &&
                scalar.last() == '\'' ->
                scalar.substring(1, scalar.lastIndex).replace("''", "'")
            scalar.length >= 2 &&
                scalar.first() == '"' &&
                scalar.last() == '"' ->
                scalar.substring(1, scalar.lastIndex)
                    .replace("\\\"", "\"")
                    .replace("\\\\", "\\")
            else -> scalar
        }.also { character ->
            require(character.isNotEmpty()) { "Empty PP-OCRv6 character" }
        }
    }

    private fun isLatinRecognitionCharacter(character: String): Boolean {
        if (character.codePointCount(0, character.length) != 1) return false
        val codePoint = character.codePointAt(0)
        return Character.UnicodeScript.of(codePoint) == Character.UnicodeScript.LATIN ||
            codePoint in ASCII_ZERO..ASCII_NINE ||
            codePoint in COMMON_PUNCTUATION
    }

    private const val BLANK_INDEX = 0
    private const val ASCII_ZERO = '0'.code
    private const val ASCII_NINE = '9'.code
    private val COMMON_PUNCTUATION = (
        "!\"#%&'()*+,-./:;<=>?@[\\]^_`{}|~" +
            "„“‚‘’«»‹›…–—·•€£\$¥°§"
        ).codePoints().toArray().toSet()
    private val MULTIPLE_SPACES = Regex(" +")
}
