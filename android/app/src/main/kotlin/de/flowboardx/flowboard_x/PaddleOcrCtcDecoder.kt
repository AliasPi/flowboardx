package de.flowboardx.flowboard_x

import java.nio.FloatBuffer

/**
 * Pure Kotlin post-processing for the bundled PP-OCRv5 Latin model.
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
            val scalar = line.substring(4).trim()
            characters += parseYamlScalar(scalar)
        }
        require(characters.isNotEmpty()) {
            "PP-OCRv5 character dictionary is missing"
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
    ): Result? {
        require(probabilities.size == expectedOutputSize(timeSteps, classCount)) {
            "Unexpected PP-OCRv5 output size"
        }
        return decodeValues(
            timeSteps = timeSteps,
            classCount = classCount,
            characters = characters,
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
    ): Result? {
        require(
            probabilities.remaining() == expectedOutputSize(timeSteps, classCount),
        ) {
            "Unexpected PP-OCRv5 output size"
        }
        val start = probabilities.position()
        return decodeValues(
            timeSteps = timeSteps,
            classCount = classCount,
            characters = characters,
            probabilityAt = { index -> probabilities.get(start + index) },
        )
    }

    private fun expectedOutputSize(timeSteps: Int, classCount: Int): Int {
        require(timeSteps >= 0) { "timeSteps must not be negative" }
        require(classCount >= 0) { "classCount must not be negative" }
        val size = timeSteps.toLong() * classCount
        require(size <= Int.MAX_VALUE) { "PP-OCRv5 output is too large" }
        return size.toInt()
    }

    private inline fun decodeValues(
        timeSteps: Int,
        classCount: Int,
        characters: List<String>,
        probabilityAt: (Int) -> Float,
    ): Result? {
        require(timeSteps >= 0) { "timeSteps must not be negative" }
        require(classCount == characters.size + 2) {
            "Unexpected PP-OCRv5 class count: $classCount"
        }

        val text = StringBuilder()
        var previousIndex = -1
        var confidenceTotal = 0.0
        var emittedCount = 0
        for (time in 0 until timeSteps) {
            val offset = time * classCount
            var bestIndex = 0
            var bestProbability = probabilityAt(offset)
            for (index in 1 until classCount) {
                val probability = probabilityAt(offset + index)
                if (probability.isFinite() &&
                    (!bestProbability.isFinite() || probability > bestProbability)
                ) {
                    bestProbability = probability
                    bestIndex = index
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
        require(scalar.isNotEmpty()) { "Empty PP-OCRv5 character" }
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
            require(character.isNotEmpty()) { "Empty PP-OCRv5 character" }
        }
    }

    private const val BLANK_INDEX = 0
    private val MULTIPLE_SPACES = Regex(" +")
}
