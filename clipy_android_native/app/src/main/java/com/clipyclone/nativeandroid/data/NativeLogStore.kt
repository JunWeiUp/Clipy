package com.clipyclone.nativeandroid.data

import android.content.ContentValues
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class NativeLogRecord(val id: Long, val level: String, val message: String, val createdAt: Long) {
    val formatted: String get() = "[${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(createdAt))}] [${level.uppercase(Locale.ROOT)}] $message"
}

/** Existing app_logs schema; caller logs metadata only, never clipboard text or credentials. */
class NativeLogStore(private val context: Context, private val file: File = File(context.filesDir, "clipy.db")) {
    private val writes = Mutex()
    private val changes = MutableStateFlow(0L)
    val revision = changes.asStateFlow()
    suspend fun append(level: String, message: String) = withContext(Dispatchers.IO) {
        writes.withLock {
            ClipyDatabase(context, file).use { helper ->
                val db = helper.writableDatabase
                db.beginTransaction()
                try {
                    db.insertOrThrow("app_logs", null, ContentValues().apply {
                        put("level", level); put("message", message); put("created_at", System.currentTimeMillis())
                    })
                    db.execSQL("DELETE FROM app_logs WHERE id NOT IN (SELECT id FROM app_logs ORDER BY id DESC LIMIT 2000)")
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            }
            changes.update { it + 1 }
        }
    }
    suspend fun page(offset: Int = 0, limit: Int = 100): List<NativeLogRecord> = withContext(Dispatchers.IO) {
        require(offset >= 0 && limit > 0)
        ClipyDatabase(context, file).use { helper ->
            helper.readableDatabase.rawQuery("SELECT id,level,message,created_at FROM app_logs ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",
                arrayOf(limit.toString(), offset.toString())).use { cursor ->
                buildList { while (cursor.moveToNext()) add(NativeLogRecord(cursor.getLong(0), cursor.getString(1), cursor.getString(2), cursor.getLong(3))) }
            }
        }
    }
    suspend fun clear() = withContext(Dispatchers.IO) {
        writes.withLock { ClipyDatabase(context, file).use { it.writableDatabase.delete("app_logs", null, null) }; changes.update { it + 1 } }
    }
}
