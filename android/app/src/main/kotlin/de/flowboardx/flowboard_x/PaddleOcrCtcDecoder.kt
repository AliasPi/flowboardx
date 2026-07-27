package de.flowboardx.flowboard_x

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
        require(timeSteps >= 0) { "timeSteps must not be negative" }
        require(classCount == characters.size + 2) {
            "Unexpected PP-OCRv5 class count: $classCount"
        }
        require(probabilities.size == timeSteps * classCount) {
            "Unexpected PP-OCRv5 output size"
        }

        val text = StringBuilder()
        var previousIndex = -1
        var confidenceTotal = 0.0
        var emittedCount = 0
        for (time in 0 until timeSteps) {
            val offset = time * classCount
            var bestIndex = 0
            var bestProbability = probabilities[offset]
            for (index in 1 until classCount) {
                val probability = probabilities[offset + index]
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
