package com.clipyclone.nativeandroid.data

import android.content.ContentValues
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import com.clipyclone.nativeandroid.sync.MAX_FRAME_BYTES

data class PendingFrame(val peerId: String, val hash: String, val type: String, val data: ByteArray, val enqueuedAt: Long)

/** Existing pending_sync rows remain byte-for-byte usable across the language migration. */
class PendingSyncRepository(private val helper: ClipyDatabase) {
    companion object { const val TTL_MS = 24 * 3600 * 1000L; const val MAX_PER_PEER = 500 }
    fun clearAll() { helper.writableDatabase.delete("pending_sync", null, null) }
    fun enqueue(frame: PendingFrame, now: Long = System.currentTimeMillis()): Boolean {
        if (frame.peerId.isEmpty() || frame.hash.isEmpty()) return false
        require(frame.data.size <= MAX_FRAME_BYTES + 4)
        val db = helper.writableDatabase
        db.beginTransaction()
        try {
            db.delete("pending_sync", "enqueue_at < ?", arrayOf((now - TTL_MS).toString()))
            val existing = DatabaseUtils.longForQuery(db, "SELECT COUNT(*) FROM pending_sync WHERE peer_id=? AND hash=?", arrayOf(frame.peerId, frame.hash))
            val count = DatabaseUtils.longForQuery(db, "SELECT COUNT(*) FROM pending_sync WHERE peer_id=?", arrayOf(frame.peerId))
            if (existing == 0L && count >= MAX_PER_PEER) { db.setTransactionSuccessful(); return false }
            db.insertWithOnConflict("pending_sync", null, ContentValues().apply {
                put("peer_id", frame.peerId); put("hash", frame.hash); put("type", frame.type)
                put("data", frame.data); put("enqueue_at", frame.enqueuedAt)
            }, SQLiteDatabase.CONFLICT_REPLACE).also { check(it != -1L) }
            db.setTransactionSuccessful()
            return true
        } finally { db.endTransaction() }
    }
    fun fetchDue(peerId: String, now: Long = System.currentTimeMillis()): List<PendingFrame> =
        helper.readableDatabase.query("pending_sync", null, "peer_id=? AND enqueue_at>=?",
            arrayOf(peerId, (now - TTL_MS).toString()), null, null, "enqueue_at ASC").use { c ->
            buildList {
                while (c.moveToNext()) add(PendingFrame(peerId, c.getString(c.getColumnIndexOrThrow("hash")),
                    c.getString(c.getColumnIndexOrThrow("type")), c.getBlob(c.getColumnIndexOrThrow("data")),
                    c.getLong(c.getColumnIndexOrThrow("enqueue_at"))))
            }
        }
    fun hasType(peerId: String, type: String): Boolean = helper.readableDatabase.rawQuery(
        "SELECT 1 FROM pending_sync WHERE peer_id=? AND type=? LIMIT 1", arrayOf(peerId, type)).use { it.moveToFirst() }
    fun dueHashes(peerId: String, now: Long = System.currentTimeMillis()): List<String> = helper.readableDatabase.rawQuery(
        "SELECT hash FROM pending_sync WHERE peer_id=? AND enqueue_at>=? ORDER BY enqueue_at ASC",
        arrayOf(peerId, (now - TTL_MS).toString())).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
    fun frame(peerId: String, hash: String): PendingFrame? = helper.readableDatabase.rawQuery(
        "SELECT type,data,enqueue_at FROM pending_sync WHERE peer_id=? AND hash=?", arrayOf(peerId, hash)).use { c ->
        if (!c.moveToFirst()) null else PendingFrame(peerId, hash, c.getString(0), c.getBlob(1), c.getLong(2))
    }
    fun remove(peerId: String, hash: String): Int = helper.writableDatabase.delete("pending_sync", "peer_id=? AND hash=?", arrayOf(peerId, hash))
    fun removePeer(peerId: String) { helper.writableDatabase.delete("pending_sync", "peer_id=?", arrayOf(peerId)) }
    fun hasPending(peerId: String): Boolean = helper.readableDatabase.rawQuery("SELECT 1 FROM pending_sync WHERE peer_id=? LIMIT 1", arrayOf(peerId)).use { it.moveToFirst() }
    fun counts(): Map<String, Int> = helper.readableDatabase.rawQuery("SELECT peer_id,COUNT(*) FROM pending_sync GROUP BY peer_id", null).use { c ->
        buildMap { while (c.moveToNext()) put(c.getString(0), c.getInt(1)) }
    }
    fun cleanOld(now: Long = System.currentTimeMillis(), maxRows: Int = 2000) {
        require(maxRows >= 0)
        val db = helper.writableDatabase
        db.beginTransaction()
        try {
            db.delete("pending_sync", "enqueue_at < ?", arrayOf((now - TTL_MS).toString()))
            val count = DatabaseUtils.queryNumEntries(db, "pending_sync")
            if (count > maxRows) db.execSQL("DELETE FROM pending_sync WHERE rowid IN (SELECT rowid FROM pending_sync ORDER BY enqueue_at ASC LIMIT ?)", arrayOf(count - maxRows))
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
}
