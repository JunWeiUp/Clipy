package com.clipyclone.nativeandroid.data

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.util.JsonReader
import android.util.JsonToken
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.Reader
import java.io.StringReader
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId

/** Imports the same pre-SQLite sources as Dart without losing originals or duplicating NULL-hash rows. */
object NativeLegacyMigration {
    private val lock = Any()
    private const val FLAG = "flutter.dbMigrationVersion"
    private const val JOURNAL = "native_legacy_imports"
    fun run(context: Context, db: SQLiteDatabase, root: File = context.filesDir,
            prefs: SharedPreferences = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)) {
        if (((prefs.all[FLAG] as? Number)?.toLong() ?: 0L) >= 1L) return
        synchronized(lock) {
            if (((prefs.all[FLAG] as? Number)?.toLong() ?: 0L) >= 1L) return
            val history = File(root, "history.json")
            val notifications = File(root, "notification_history.jsonl")
            val files = prefs.getString("flutter.fileHistory", null)
            if (history.isFile || notifications.isFile || !files.isNullOrEmpty()) {
                // Private import journal; base user tables and user_version remain v6 for rollback compatibility.
                db.execSQL("CREATE TABLE IF NOT EXISTS $JOURNAL (source TEXT PRIMARY KEY, imported_at INTEGER NOT NULL)")
            }
            if (history.isFile) {
                once(db, "history.json") {
                    history.reader(Charsets.UTF_8).use { input -> array(input) { value ->
                        val item = value.getJSONObject("item")
                        val type = item.keys().asSequence().firstOrNull() ?: error("Missing history item type")
                        val content = item.get(type)
                        db.insertWithOnConflict("clipboard_history", null, ContentValues().apply {
                            put("content_hash", nullableString(value, "contentHash")); put("item_type", type)
                            put("item_value", content.toString())
                            put("source_app", nullableString(value, "sourceApp")); put("created_at", historyDate(value.opt("date")))
                        }, SQLiteDatabase.CONFLICT_IGNORE)
                    } }
                }
                archive(history)
            }
            if (notifications.isFile) {
                once(db, "notification_history.jsonl") {
                    notifications.bufferedReader(Charsets.UTF_8).useLines { lines -> lines.filter { it.isNotBlank() }.forEach { line ->
                        val value = JSONObject(line)
                        val extras = value.optJSONObject("extras") ?: JSONObject()
                        db.insertWithOnConflict("notifications", null, ContentValues().apply {
                            put("id", value.getString("id")); put("notification_key", nullableString(value, "notificationKey"))
                            put("package_name", value.getString("packageName")); put("app_name", value.getString("appName"))
                            put("title", value.getString("title")); put("subtitle", nullableString(value, "subtitle")); put("body", value.getString("body"))
                            put("post_time", value.getLong("postTime")); put("group_key", nullableString(value, "groupKey"))
                            put("is_clearable", if (value.optBoolean("isClearable", true)) 1 else 0)
                            put("is_archived", if (value.optBoolean("isArchived", false) || extras.opt("clipyArchived")?.toString() == "true") 1 else 0)
                            put("extras_json", extras.toString())
                        }, SQLiteDatabase.CONFLICT_REPLACE)
                    } }
                }
                archive(notifications)
            }
            if (!files.isNullOrEmpty()) {
                once(db, "fileHistory") {
                    StringReader(files).use { input -> array(input) { value ->
                        db.insertOrThrow("file_transfers", null, ContentValues().apply {
                            put("file_name", value.optString("fileName", "")); put("file_path", value.optString("filePath", ""))
                            put("file_size", (value.opt("fileSize") as? Number)?.toLong() ?: 0L)
                            put("sender_name", value.optString("senderName", "")); put("created_at", (value.opt("date") as? Number)?.toLong() ?: System.currentTimeMillis())
                        })
                    } }
                }
            }
            check(prefs.edit().remove("flutter.fileHistory").putLong(FLAG, 1).commit()) { "Could not persist migration completion" }
        }
    }
    private fun once(db: SQLiteDatabase, source: String, block: () -> Unit) {
        if (db.rawQuery("SELECT 1 FROM $JOURNAL WHERE source=?", arrayOf(source)).use { it.moveToFirst() }) return
        db.beginTransaction()
        try {
            block()
            db.insertOrThrow(JOURNAL, null, ContentValues().apply { put("source", source); put("imported_at", System.currentTimeMillis()) })
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
    private fun archive(source: File) {
        var destination = File(source.path + ".migrated.bak")
        var suffix = 2
        while (destination.exists()) destination = File(source.path + ".migrated.bak.${suffix++}")
        check(source.renameTo(destination)) { "Could not archive imported legacy file" }
    }
    private fun nullableString(value: JSONObject, key: String): String? = value.opt(key) as? String
    private fun historyDate(value: Any?): Long = when (value) {
        is Number -> (value.toDouble() * 1000 + 978307200000L).toLong() // Apple's fixed reference epoch, as in the Dart importer.
        is String -> runCatching { Instant.parse(value).toEpochMilli() }.recoverCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
            .getOrElse { LocalDateTime.parse(value).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli() }
        else -> System.currentTimeMillis()
    }
    private fun array(input: Reader, row: (JSONObject) -> Unit) {
        JsonReader(input).use { reader ->
            reader.beginArray()
            while (reader.hasNext()) row(readValue(reader, 0) as JSONObject)
            reader.endArray()
            check(reader.peek() == JsonToken.END_DOCUMENT)
        }
    }
    private fun readValue(reader: JsonReader, depth: Int): Any {
        require(depth <= 64) { "Legacy JSON nesting too deep" }
        return when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> JSONObject().also { result ->
                reader.beginObject(); while (reader.hasNext()) result.put(reader.nextName(), readValue(reader, depth + 1)); reader.endObject()
            }
            JsonToken.BEGIN_ARRAY -> JSONArray().also { result ->
                reader.beginArray(); while (reader.hasNext()) result.put(readValue(reader, depth + 1)); reader.endArray()
            }
            JsonToken.STRING -> reader.nextString()
            JsonToken.NUMBER -> reader.nextString().let { it.toLongOrNull() ?: it.toDouble() }
            JsonToken.BOOLEAN -> reader.nextBoolean()
            JsonToken.NULL -> { reader.nextNull(); JSONObject.NULL }
            else -> error("Invalid legacy JSON value")
        }
    }
}
