package com.clipyclone.nativeandroid

import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class HistoryReceiverTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val crypto = SyncCrypto()
    private fun envelope(text: String) = SyncEnvelope(SyncType.HISTORY, "remote-fixture", hash = ContentHash.text(text), payload = crypto.encryptText(text))
    private fun rows(file: File) = ClipyDatabase(context, file).use { HistoryRepository(it).page() }

    @Test fun ackSeesCommittedDataAndDuplicateDoesNotRewriteClipboard() = runBlocking {
        val file = File(context.cacheDir, "receive-${UUID.randomUUID()}.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val seenAtAck = mutableListOf<String>()
        val writes = mutableListOf<HistoryWrite>()
        val receiver = HistorySyncReceiver(scope, crypto, SqliteHistorySyncStore(context, file),
            acknowledge = { _, _ -> seenAtAck += rows(file).single().value }, publish = { writes += it })
        try {
            receiver.receive("peer", envelope("saved before ack"))
            val original = rows(file).single()
            receiver.receive("peer", envelope("saved before ack"))
            assertEquals(listOf("saved before ack", "saved before ack"), seenAtAck)
            assertEquals(original.id, rows(file).single().id)
            assertEquals("saved before ack", writes.first().clipboardText)
            assertNull(writes.last().clipboardText)
            assertFalse(writes.last().changed)
        } finally { receiver.close(); scope.cancel(); SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun sqlFailureWithholdsAckAndPreservesExistingHistory() = runBlocking {
        val file = File(context.cacheDir, "receive-failure-${UUID.randomUUID()}.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var acks = 0; var errors = 0
        try {
            ClipyDatabase(context, file).use { helper ->
                HistoryRepository(helper).saveText("kept")
                helper.writableDatabase.execSQL("CREATE TRIGGER fail_remote BEFORE INSERT ON clipboard_history BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            }
            val receiver = HistorySyncReceiver(scope, crypto, SqliteHistorySyncStore(context, file),
                acknowledge = { _, _ -> acks++ }, publish = {}, onError = { errors++ })
            try { receiver.receive("peer", envelope("must not ack")) } finally { receiver.close() }
            assertEquals(0, acks); assertEquals(1, errors)
            assertEquals("kept", rows(file).single().value)
        } finally { scope.cancel(); SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun fetchReplayPreservesExistingPositionsAndCopiesOnlyNewestNewText() = runBlocking {
        val file = File(context.cacheDir, "fetch-${UUID.randomUUID()}.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val acks = Channel<String>(Channel.UNLIMITED)
        val published = Channel<HistoryWrite>(Channel.UNLIMITED)
        val receiver = HistorySyncReceiver(scope, crypto, SqliteHistorySyncStore(context, file),
            acknowledge = { _, hash -> acks.send(hash!!) }, publish = { published.trySend(it) }, debounceMs = 30, maxWaitMs = 100)
        try {
            ClipyDatabase(context, file).use { helper ->
                HistoryRepository(helper).saveText("one", System.currentTimeMillis() - 10000)
                HistoryRepository(helper).saveText("two", System.currentTimeMillis() - 5000)
            }
            val before = rows(file)
            receiver.beginCatchUp("peer")
            receiver.receive("peer", envelope("one")); receiver.receive("peer", envelope("two"))
            withTimeout(2000) { repeat(2) { acks.receive() } }
            val replay = published.receive()
            assertFalse(replay.changed); assertNull(replay.clipboardText)
            assertEquals(before, rows(file))
            receiver.beginCatchUp("peer")
            receiver.receive("peer", envelope("one")); receiver.receive("peer", envelope("new three"))
            withTimeout(2000) { repeat(2) { acks.receive() } }
            assertEquals("new three", published.receive().clipboardText)
            assertEquals(3, rows(file).size)
            assertEquals(before.map { it.id }, rows(file).drop(1).map { it.id })
        } finally { receiver.close(); scope.cancel(); acks.close(); published.close(); SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun stopDiscardsUncommittedCatchUpWithoutLateAck() = runBlocking {
        val file = File(context.cacheDir, "stop-fetch-${UUID.randomUUID()}.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val acks = Channel<String>(Channel.UNLIMITED)
        val receiver = HistorySyncReceiver(scope, crypto, SqliteHistorySyncStore(context, file),
            acknowledge = { _, hash -> acks.send(hash ?: "") }, publish = {}, debounceMs = 30, maxWaitMs = 100)
        try {
            receiver.beginCatchUp("peer"); receiver.receive("peer", envelope("not committed")); receiver.close()
            delay(150)
            assertTrue(acks.tryReceive().isFailure); assertTrue(rows(file).isEmpty())
        } finally { receiver.close(); scope.cancel(); acks.close(); SQLiteDatabase.deleteDatabase(file) }
    }
}
