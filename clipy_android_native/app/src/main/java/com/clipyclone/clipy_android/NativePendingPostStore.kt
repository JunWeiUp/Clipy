package com.clipyclone.clipy_android

import android.content.Context
import android.database.sqlite.SQLiteDatabase

data class NativePendingPost(val rowId: Long, val payload: String)

/** Existing on-disk inbox, consumed only after the notification repository commits. */
object NativePendingPostStore {
    private val lock = Any()
    private fun <T> database(context: Context, block: (SQLiteDatabase) -> T): T = synchronized(lock) {
        context.applicationContext.openOrCreateDatabase("clipy_native_pending.db", Context.MODE_PRIVATE, null).use { db ->
            db.enableWriteAheadLogging()
            db.execSQL("CREATE TABLE IF NOT EXISTS native_pending_posts(rowid INTEGER PRIMARY KEY AUTOINCREMENT,payload_json TEXT NOT NULL,created_at INTEGER NOT NULL)")
            block(db)
        }
    }
    fun insert(context: Context, payloadJson: String) = database(context) { db ->
        db.execSQL("INSERT INTO native_pending_posts(payload_json,created_at) VALUES(?,?)", arrayOf<Any>(payloadJson, System.currentTimeMillis()))
        db.execSQL("DELETE FROM native_pending_posts WHERE rowid NOT IN (SELECT rowid FROM native_pending_posts ORDER BY rowid DESC LIMIT 200)")
    }
    fun peek(context: Context): List<NativePendingPost> = database(context) { db ->
        db.rawQuery("SELECT rowid,payload_json FROM native_pending_posts ORDER BY rowid ASC", null).use { c ->
            buildList { while (c.moveToNext()) add(NativePendingPost(c.getLong(0), c.getString(1))) }
        }
    }
    fun remove(context: Context, rowId: Long) = database(context) { db -> db.delete("native_pending_posts", "rowid=?", arrayOf(rowId.toString())) }
    fun count(context: Context): Int = database(context) { db -> db.rawQuery("SELECT COUNT(*) FROM native_pending_posts", null).use { it.moveToFirst(); it.getInt(0) } }
}
