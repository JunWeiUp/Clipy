package com.clipyclone.clipy_android

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import org.json.JSONObject

/**
 * 离线缓冲库：当 Flutter MethodChannel 不可用（锁屏 / 进程被回收 /
 * Activity 重建期间）时，[ClipyNotificationListenerService] 收到的通知会落盘到这里。
 *
 * Dart 端 [NotificationManager] 在 `init()` 时通过 MethodChannel
 * `drainNativePendingPosts` 一次性拉走并清空整表 —— 之后这些通知走标准的
 * `_handleNotificationPosted` 路径，由 Dart 侧 `pending_notification_sync`
 * 接管"是否已同步给 Mac"的状态。
 *
 * 设计要点：
 * - 使用 Android 内置 SQLiteDatabase，零额外依赖。
 * - 独立的库文件 `clipy_native_pending.db`，与 Dart sqflite 的 `clipy.db`
 *   物理隔离，避免跨引擎/跨进程写同一文件的锁与迁移风险。
 * - 单一职责：只缓冲"还没交给 Dart 的通知"，Dart 消费后即清空。
 *   不承担 ack/已同步状态的维护（那是 Dart `pending_notification_sync` 的职责）。
 */
object NativePendingPostStore {

    private const val TAG = "ClipyNPS"
    private const val DB_NAME = "clipy_native_pending.db"
    private const val TABLE = "native_pending_posts"
    private const val MAX_ROWS = 200

    @Volatile
    private var db: SQLiteDatabase? = null

    private val lock = Any()

    private fun open(context: Context): SQLiteDatabase {
        db?.let { return it }
        synchronized(lock) {
            db?.let { return it }
            val ctx = context.applicationContext
            val dbFile = ctx.getDatabasePath(DB_NAME)
            dbFile.parentFile?.mkdirs()
            val opened = ctx.openOrCreateDatabase(DB_NAME, Context.MODE_PRIVATE, null)
            opened.enableWriteAheadLogging()
            opened.execSQL(
                """
                CREATE TABLE IF NOT EXISTS $TABLE (
                    rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                    payload_json TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                )
                """.trimIndent()
            )
            db = opened
            return opened
        }
    }

    /**
     * 追加一条通知 JSON。在 [ClipyNotificationListenerService.emitNotificationPosted]
     * 的冷路径（channel == null）调用。
     */
    fun insert(context: Context, payloadJson: String) {
        try {
            val database = open(context)
            val now = System.currentTimeMillis()
            database.execSQL(
                "INSERT INTO $TABLE (payload_json, created_at) VALUES (?, ?)",
                arrayOf<Any>(payloadJson, now),
            )
            trimLocked(database)
        } catch (e: Exception) {
            Log.e(TAG, "insert failed", e)
        }
    }

    /**
     * 读出并清空全部缓冲。在 Dart [NotificationManager.init] 拉取时调用。
     * 使用事务保证"读后即删"的原子性，不会因中途异常丢数据。
     */
    fun drainAll(context: Context): List<String> {
        return try {
            val database = open(context)
            val out = ArrayList<String>()
            database.beginTransaction()
            try {
                database.rawQuery("SELECT payload_json FROM $TABLE ORDER BY rowid ASC", null)
                    .use { c ->
                        val idx = c.getColumnIndexOrThrow("payload_json")
                        while (c.moveToNext()) {
                            out.add(c.getString(idx))
                        }
                    }
                database.execSQL("DELETE FROM $TABLE")
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
            out
        } catch (e: Exception) {
            Log.e(TAG, "drainAll failed", e)
            emptyList()
        }
    }

    /** 返回当前缓冲条数（诊断用）。 */
    fun count(context: Context): Int {
        return try {
            val database = open(context)
            database.rawQuery("SELECT COUNT(*) FROM $TABLE", null).use { c ->
                if (c.moveToFirst()) c.getInt(0) else 0
            }
        } catch (e: Exception) {
            0
        }
    }

    /**
     * 保留最新 [MAX_ROWS] 条，防止异常情况下无界增长。
     * 由 [insert] 内部调用，调用方需已持有 [database] 引用（处于同一写路径）。
     */
    private fun trimLocked(database: SQLiteDatabase) {
        database.execSQL(
            """
            DELETE FROM $TABLE
            WHERE rowid NOT IN (
                SELECT rowid FROM $TABLE ORDER BY rowid DESC LIMIT $MAX_ROWS
            )
            """.trimIndent()
        )
    }
}
