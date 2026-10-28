package com.clipyclone.nativeandroid.sync

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.clipyclone.nativeandroid.data.ClipyDatabase
import com.clipyclone.nativeandroid.data.ContentHash
import com.clipyclone.nativeandroid.data.HistoryRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/** The order of items in a replay is oldest-first, just as the current Mac sender emits it. */
data class RemoteHistoryText(val text: String, val hash: String)
data class HistoryWrite(val changed: Boolean, val clipboardText: String?, val remoteHashes: List<String>, val lastText: String? = clipboardText)
fun interface HistorySyncStore { suspend fun store(items: List<RemoteHistoryText>, replay: Boolean): HistoryWrite }

class SqliteHistorySyncStore(
    private val context: Context, private val file: File = File(context.filesDir, "clipy.db"),
    private val historyLimit: () -> Int = { 1000 },
) : HistorySyncStore {
    private val mutex = Mutex()
    override suspend fun store(items: List<RemoteHistoryText>, replay: Boolean): HistoryWrite = withContext(Dispatchers.IO) {
        mutex.withLock {
            ClipyDatabase(context, file).use { helper ->
                val db = helper.writableDatabase
                var latestText: String? = null
                val newHashes = mutableListOf<String>()
                var changed = false
                db.beginTransaction()
                try {
                    for (item in items) {
                        if (item.text.isEmpty()) continue
                        val hash = item.hash.ifEmpty { ContentHash.text(item.text) }
                        if (!replay) {
                            val latest = db.rawQuery("SELECT content_hash FROM clipboard_history ORDER BY created_at DESC,id DESC LIMIT 1", null)
                                .use { if (it.moveToFirst()) it.getString(0) else null }
                            newHashes += hash
                            if (latest == hash) continue
                            db.delete("clipboard_history", "content_hash=?", arrayOf(hash))
                        }
                        val row = db.insertWithOnConflict("clipboard_history", null, ContentValues().apply {
                            put("content_hash", hash); put("item_type", "text"); put("item_value", item.text)
                            put("source_app", "Remote Sync"); put("created_at", System.currentTimeMillis())
                        }, if (replay) SQLiteDatabase.CONFLICT_IGNORE else SQLiteDatabase.CONFLICT_ABORT)
                        if (row != -1L) {
                            changed = true; latestText = item.text
                            if (replay) newHashes += hash
                        } else if (!replay) error("History insert failed")
                    }
                    if (changed) HistoryRepository(helper).trimToLimit(historyLimit())
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
                HistoryWrite(changed, latestText, newHashes, if (replay) latestText else items.lastOrNull { it.text.isNotEmpty() }?.text)
            }
        }
    }
}

/** Persists before ACK; coalesces history.fetch without touching existing rows or clipboard. */
class HistorySyncReceiver(
    private val scope: CoroutineScope, private val crypto: SyncCrypto, private val storage: HistorySyncStore,
    private val acknowledge: suspend (String, String?) -> Unit,
    private val publish: (HistoryWrite) -> Unit,
    private val onError: () -> Unit = {},
    private val debounceMs: Long = 2000, private val maxWaitMs: Long = 8000,
) {
    private class Batch {
        val items = mutableListOf<RemoteHistoryText>()
        var chars = 0
        var debounce: Job? = null
        var deadline: Job? = null
    }
    private val lock = Any()
    private val batches = mutableMapOf<String, Batch>()
    @Volatile private var closed = false

    fun beginCatchUp(peerId: String) {
        val next = Batch()
        val previous = synchronized(lock) {
            if (closed) return
            val old = batches.put(peerId, next)
            next.deadline = scope.launch(start = CoroutineStart.LAZY) { delay(maxWaitMs); flush(peerId, next) }
            old
        }
        previous?.let {
            it.debounce?.cancel(); it.deadline?.cancel()
            if (it.items.isNotEmpty()) scope.launch { persist(peerId, it.items.toList(), replay = true) }
        }
        next.deadline?.start()
    }

    suspend fun receive(peerId: String, envelope: SyncEnvelope) {
        if (closed || envelope.v != SYNC_VERSION || envelope.type !in setOf(SyncType.HISTORY, SyncType.HISTORY_DIRECT)) return
        val text = envelope.payload?.let(crypto::decryptText) ?: return
        if (text.isEmpty()) return
        val item = RemoteHistoryText(text, envelope.hash ?: "")
        val buffered = synchronized(lock) {
            val batch = batches[peerId]
            if (closed) true
            else if (batch == null) false
            else {
                // The shipping receiver permits one final frame past this threshold, then withholds excess ACKs.
                if (batch.chars < 8 * 1024 * 1024) { batch.items += item; batch.chars += text.length }
                batch.debounce?.cancel()
                batch.debounce = scope.launch(start = CoroutineStart.LAZY) { delay(debounceMs); flush(peerId, batch) }
                batch.debounce!!.start()
                true
            }
        }
        if (!buffered) persist(peerId, listOf(item), replay = false)
    }
    suspend fun flushPeer(peer: String) {
        val batch = synchronized(lock) { batches[peer] } ?: return
        flush(peer, batch)
    }
    private suspend fun flush(peer: String, expected: Batch) {
        val batch = synchronized(lock) { if (batches[peer] === expected) batches.remove(peer) else null } ?: return
        // Do not cancel the coroutine currently performing the flush.
        val me = currentCoroutineContext()[Job]
        if (batch.debounce !== me) batch.debounce?.cancel()
        if (batch.deadline !== me) batch.deadline?.cancel()
        persist(peer, batch.items.toList(), replay = true)
    }
    private suspend fun persist(peer: String, items: List<RemoteHistoryText>, replay: Boolean) {
        if (closed || items.isEmpty()) return
        try {
            val result = storage.store(items, replay)
            if (closed) return
            // Callback only publishes state/schedules a clipboard write, never waits for platform UI.
            runCatching { publish(result) }
            for (item in items) {
                if (closed) return
                if (!replay || item.hash.isNotEmpty()) acknowledge(peer, item.hash.ifEmpty { null })
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { onError() /* no ACK on any storage failure */ }
    }
    fun close() {
        val pending = synchronized(lock) { closed = true; batches.values.toList().also { batches.clear() } }
        pending.forEach { it.debounce?.cancel(); it.deadline?.cancel(); it.items.clear() }
    }
}
