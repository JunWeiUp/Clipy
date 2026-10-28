package com.clipyclone.nativeandroid.data

import android.content.ContentValues
import android.database.Cursor
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import com.clipyclone.nativeandroid.notifications.*
import org.json.JSONObject

data class NotificationUpsert(val accepted: Boolean, val replaced: List<NotificationEntry> = emptyList())

/** v6-compatible repository, including WeChat archived snapshots and content-level pending queue. */
class NotificationRepository(private val helper: ClipyDatabase) {
    private val db get() = helper.writableDatabase
    private fun row(cursor: Cursor): NotificationEntry {
        fun text(name: String) = cursor.getString(cursor.getColumnIndexOrThrow(name))
        fun integer(name: String) = cursor.getInt(cursor.getColumnIndexOrThrow(name))
        val obj = runCatching { JSONObject(text("extras_json") ?: "{}") }.getOrDefault(JSONObject())
        val extras = obj.keys().asSequence().associateWith { obj.opt(it)?.takeUnless { v -> v == JSONObject.NULL }?.toString() ?: "" }
        return NotificationEntry(text("id"), text("notification_key"), text("package_name"), text("app_name"), text("title"), text("subtitle"),
            text("body"), cursor.getLong(cursor.getColumnIndexOrThrow("post_time")), text("group_key"), integer("is_clearable") == 1,
            integer("is_archived") == 1 || extras["clipyArchived"] == "true", integer("sync_state"), extras)
    }
    private fun values(entry: NotificationEntry): ContentValues = ContentValues().apply {
        put("id", entry.id); put("notification_key", entry.notificationKey); put("package_name", entry.packageName); put("app_name", entry.appName)
        put("title", entry.title); put("subtitle", entry.subtitle); put("body", entry.body); put("post_time", entry.postTime); put("group_key", entry.groupKey)
        put("is_clearable", if (entry.isClearable) 1 else 0); put("is_archived", if (entry.isArchived) 1 else 0); put("sync_state", entry.syncState)
        val extras = entry.extras.toMutableMap().apply { if (entry.isArchived) put("clipyArchived", "true") else remove("clipyArchived") }
        put("extras_json", JSONObject(extras).toString())
    }
    private fun query(where: String? = null, args: Array<String>? = null, limit: Int = 50, offset: Int = 0): List<NotificationEntry> =
        db.query("notifications", null, where, args, null, null, "post_time DESC", "$offset,$limit").use { c -> buildList { while (c.moveToNext()) add(row(c)) } }
    private fun duplicate(a: NotificationEntry, b: NotificationEntry) = a.title.trim() == b.title.trim() &&
        a.subtitle.orEmpty().trim() == b.subtitle.orEmpty().trim() && a.body.trim() == b.body.trim() && a.groupKey == b.groupKey
    fun upsert(entry: NotificationEntry): NotificationUpsert {
        if (entry.title.isBlank() && entry.subtitle.isNullOrBlank() && entry.body.isBlank() && entry.extras.values.all { it.isBlank() }) return NotificationUpsert(false)
        val database = db; database.beginTransaction()
        try {
            val existingId = query("id=?", arrayOf(entry.id), 1).firstOrNull()
            if (existingId != null) {
                if (duplicate(existingId, entry)) { database.setTransactionSuccessful(); return NotificationUpsert(false) }
                database.update("notifications", values(entry), "id=?", arrayOf(entry.id)); database.setTransactionSuccessful(); return NotificationUpsert(true)
            }
            val replaced = mutableListOf<NotificationEntry>()
            if (!entry.notificationKey.isNullOrEmpty()) {
                query("notification_key=?", arrayOf(entry.notificationKey), 1).firstOrNull()?.let { existing ->
                    if (duplicate(existing, entry)) { database.setTransactionSuccessful(); return NotificationUpsert(false) }
                    if (entry.packageName == "com.tencent.mm") {
                        if (!existing.isArchived) database.update("notifications", values(existing.copy(notificationKey = "clipy-archived:${existing.id}", isArchived = true)), "id=?", arrayOf(existing.id))
                    } else { replaced += existing; database.delete("notifications", "id=?", arrayOf(existing.id)) }
                }
            }
            if (query("package_name=?", arrayOf(entry.packageName), 50).any { duplicate(it, entry) }) {
                database.setTransactionSuccessful(); return NotificationUpsert(false)
            }
            database.insertWithOnConflict("notifications", null, values(entry), SQLiteDatabase.CONFLICT_REPLACE).also { check(it != -1L) }
            // Same cap, applied per insert so a native process restart cannot indefinitely postpone cleanup.
            database.execSQL("DELETE FROM notifications WHERE post_time < (SELECT post_time FROM notifications ORDER BY post_time DESC LIMIT 1 OFFSET 5000)")
            database.setTransactionSuccessful(); return NotificationUpsert(true, replaced)
        } finally { database.endTransaction() }
    }
    fun count(): Int = DatabaseUtils.queryNumEntries(db, "notifications").toInt()
    fun packageCount(): Int = DatabaseUtils.longForQuery(db, "SELECT COUNT(DISTINCT package_name) FROM notifications", null).toInt()
    fun groups(offset: Int = 0, limit: Int = 20): List<NotificationGroup> = db.rawQuery(
        "SELECT package_name,app_name,COUNT(*),MAX(post_time) FROM notifications GROUP BY package_name ORDER BY MAX(post_time) DESC LIMIT ? OFFSET ?", arrayOf(limit.toString(), offset.toString())).use { c ->
        buildList { while (c.moveToNext()) add(NotificationGroup(c.getString(0), c.getString(1), c.getInt(2), c.getLong(3))) }
    }
    fun byPackage(packageName: String, offset: Int = 0, limit: Int = 50) = query("package_name=?", arrayOf(packageName), limit, offset)
    fun page(offset: Int = 0, limit: Int = 50) = query(limit = limit, offset = offset)
    fun packages(): Set<String> = db.rawQuery("SELECT DISTINCT package_name FROM notifications", null).use { c -> buildSet { while (c.moveToNext()) add(c.getString(0)) } }
    fun remove(id: String) { db.delete("notifications", "id=?", arrayOf(id)) }
    fun removeKey(key: String) { db.delete("notifications", "notification_key=?", arrayOf(key)) }
    fun clear() { db.delete("notifications", null, null) }
    fun markSynced(id: String) { db.update("notifications", ContentValues().apply { put("sync_state", 1) }, "id=?", arrayOf(id)) }
    fun enqueue(entry: NotificationEntry) {
        val content = entry.json().toString()
        db.insertWithOnConflict("pending_notification_sync", null, ContentValues().apply {
            put("notification_id", entry.id); put("content", content); put("hash", entry.id); put("created_at", System.currentTimeMillis())
        }, SQLiteDatabase.CONFLICT_REPLACE).also { check(it != -1L) }
        cleanPending()
    }
    fun removePending(id: String) { db.delete("pending_notification_sync", "notification_id=?", arrayOf(id)) }
    fun hasPending(): Boolean = db.rawQuery("SELECT 1 FROM pending_notification_sync LIMIT 1", null).use { it.moveToFirst() }
    fun pendingIds(): Set<String> = db.rawQuery("SELECT notification_id FROM pending_notification_sync ORDER BY created_at ASC", null).use { c -> buildSet { while (c.moveToNext()) add(c.getString(0)) } }
    fun pending(): List<Pair<String, String>> = db.rawQuery("SELECT hash,content FROM pending_notification_sync ORDER BY created_at ASC", null).use { c -> buildList { while (c.moveToNext()) add(c.getString(0) to c.getString(1)) } }
    fun pendingItem(id: String): Pair<String, String>? = db.rawQuery("SELECT hash,content FROM pending_notification_sync WHERE notification_id=?", arrayOf(id)).use {
        if (it.moveToFirst()) it.getString(0) to it.getString(1) else null
    }
    fun unsynced(): List<NotificationEntry> = db.query("notifications", null, "sync_state=0 AND post_time>=?",
        arrayOf((System.currentTimeMillis() - 2 * 24 * 3600 * 1000L).toString()), null, null, "post_time ASC", "200").use { c ->
        buildList { while (c.moveToNext()) add(row(c)) }
    }
    fun cleanPending() {
        db.delete("pending_notification_sync", "created_at < ?", arrayOf((System.currentTimeMillis() - 7 * 24 * 3600 * 1000L).toString()))
        db.execSQL("DELETE FROM pending_notification_sync WHERE notification_id NOT IN (SELECT notification_id FROM pending_notification_sync ORDER BY created_at DESC LIMIT 500)")
    }
}
