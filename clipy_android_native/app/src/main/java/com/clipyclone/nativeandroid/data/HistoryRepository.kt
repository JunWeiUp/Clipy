package com.clipyclone.nativeandroid.data

import android.content.ContentValues

/** Call on the owner's serial IO path. Queries always filter before pagination. */
class HistoryRepository(private val helper: ClipyDatabase) {
    fun page(query: String = "", filter: HistoryFilter = HistoryFilter.ALL, limit: Int = 50, offset: Int = 0): List<HistoryEntry> {
        require(limit > 0 && offset >= 0)
        val clauses = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (query.isNotBlank()) {
            val literal = query.trim().replace("!", "!!").replace("%", "!%").replace("_", "!_")
            clauses += "((item_type IN ('text', 'fileURL', 'fileURLs') AND item_value LIKE ? ESCAPE '!') OR source_app LIKE ? ESCAPE '!')"
            args += listOf("%$literal%", "%$literal%")
        }
        when (filter) {
            HistoryFilter.ALL -> Unit
            HistoryFilter.TEXT -> clauses += "item_type = 'text'"
            HistoryFilter.LINKS -> clauses += "item_type = 'text' AND (LOWER(TRIM(item_value)) LIKE 'https://%' OR LOWER(TRIM(item_value)) LIKE 'http://%')"
            HistoryFilter.FILES -> clauses += "item_type IN ('fileURL', 'fileURLs')"
            HistoryFilter.IMAGES -> clauses += "item_type = 'image'"
        }
        return helper.readableDatabase.query("clipboard_history", null,
            clauses.takeIf { it.isNotEmpty() }?.joinToString(" AND "), args.toTypedArray(),
            null, null, "created_at DESC, id DESC", "$offset,$limit").use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    fun value(name: String) = cursor.getString(cursor.getColumnIndexOrThrow(name))
                    add(HistoryEntry(cursor.getLong(cursor.getColumnIndexOrThrow("id")), value("content_hash"),
                        value("item_type"), value("item_value"), value("source_app"),
                        cursor.getLong(cursor.getColumnIndexOrThrow("created_at"))))
                }
            }
        }
    }

    fun saveText(text: String, now: Long = System.currentTimeMillis(), source: String = "Clipy") {
        require(text.isNotEmpty())
        val hash = ContentHash.text(text)
        val db = helper.writableDatabase
        db.beginTransaction()
        try {
            db.delete("clipboard_history", "content_hash = ?", arrayOf(hash))
            db.insertOrThrow("clipboard_history", null, ContentValues().apply {
                put("content_hash", hash); put("item_type", "text"); put("item_value", text)
                put("source_app", source); put("created_at", now)
            })
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    fun clear() { helper.writableDatabase.delete("clipboard_history", null, null) }

    fun trimToLimit(limit: Int) {
        if (limit <= 0) return
        helper.writableDatabase.execSQL("DELETE FROM clipboard_history WHERE id NOT IN (SELECT id FROM clipboard_history ORDER BY created_at DESC, id DESC LIMIT ?)", arrayOf(limit))
    }

    fun delete(id: Long) { helper.writableDatabase.delete("clipboard_history", "id = ?", arrayOf(id.toString())) }
}
