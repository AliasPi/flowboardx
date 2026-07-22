package de.flowboardx.flowboard_x

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class WidgetDocument(
    val id: String,
    val title: String,
    val updatedAtEpochMillis: Long,
    val previewPath: String?,
)

object WidgetPreferences {
    private const val PREFERENCES_NAME = "flowboard_widget"
    private const val KEY_DOCUMENTS = "recent_documents_v1"
    private const val MAX_DOCUMENTS = 12

    fun storeDocuments(context: Context, rawDocuments: List<Map<String, Any?>>): Int {
        val documents = rawDocuments.mapNotNull(::parseDocument)
            .groupBy(WidgetDocument::id)
            .mapNotNull { (_, versions) -> versions.maxByOrNull(WidgetDocument::updatedAtEpochMillis) }
            .sortedByDescending(WidgetDocument::updatedAtEpochMillis)
            .take(MAX_DOCUMENTS)

        val json = JSONArray()
        documents.forEach { document ->
            json.put(
                JSONObject().apply {
                    put("id", document.id)
                    put("title", document.title)
                    put("updatedAtEpochMillis", document.updatedAtEpochMillis)
                    document.previewPath?.let { put("previewPath", it) }
                },
            )
        }
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DOCUMENTS, json.toString())
            .commit()
        return documents.size
    }

    fun readDocuments(context: Context): List<WidgetDocument> {
        val encoded = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getString(KEY_DOCUMENTS, null) ?: return emptyList()
        return runCatching {
            val json = JSONArray(encoded)
            buildList {
                for (index in 0 until json.length()) {
                    val item = json.optJSONObject(index) ?: continue
                    val id = item.optString("id").trim()
                    val title = item.optString("title").trim()
                    val updatedAt = item.optLong("updatedAtEpochMillis", -1L)
                    if (id.isEmpty() || title.isEmpty() || updatedAt < 0L) continue
                    add(
                        WidgetDocument(
                            id = id,
                            title = title,
                            updatedAtEpochMillis = updatedAt,
                            previewPath = item.optString("previewPath")
                                .takeIf(String::isNotBlank),
                        ),
                    )
                }
            }
        }.getOrDefault(emptyList())
    }

    private fun parseDocument(value: Map<String, Any?>): WidgetDocument? {
        val id = (value["id"] as? String)?.trim().orEmpty()
        val title = (value["title"] as? String)?.trim().orEmpty()
        val updatedAt = when (val raw = value["updatedAtEpochMillis"]) {
            is Number -> raw.toLong()
            is String -> raw.toLongOrNull()
            else -> null
        } ?: return null
        if (id.isEmpty() || title.isEmpty() || updatedAt < 0L) return null
        return WidgetDocument(
            id = id,
            title = title.take(100),
            updatedAtEpochMillis = updatedAt,
            previewPath = (value["previewPath"] as? String)?.takeIf(String::isNotBlank),
        )
    }
}
