package com.clipyclone.nativeandroid

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.ServerSocket
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class NativeSyncManagerTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private class Fixture(val context: Context) {
        val name = "manager-${UUID.randomUUID()}"
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val store = SyncSettingsStore(prefs)
        val file = File(context.cacheDir, "$name.db")
        val writes = Channel<HistoryWrite>(Channel.UNLIMITED)
        val manager = NativeSyncManager(context, store, file, addresses = { emptyList() }, publishHistory = { writes.trySend(it) })
        val id get() = manager.state.value.settings.peerId
        val port get() = manager.state.value.settings.port
        suspend fun initialize(label: String) {
            manager.initialize()
            val port = ServerSocket(0).use { it.localPort }
            manager.saveConnection(label, port)
        }
        fun rows() = ClipyDatabase(context, file).use { HistoryRepository(it).page(limit = 1000) }
        fun pending() = ClipyDatabase(context, file).use { PendingSyncRepository(it).counts() }
        suspend fun close() { manager.shutdown(); writes.close(); context.deleteSharedPreferences(name); SQLiteDatabase.deleteDatabase(file) }
    }
    private suspend fun eventually(predicate: () -> Boolean) = withTimeout(5000) { while (!predicate()) delay(20) }

    @Test fun directTextIsDurableBeforeSuccessWithoutReciprocalAuthorization() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            a.initialize("Sender"); b.initialize("Receiver")
            a.manager.setEnabled(true); b.manager.setEnabled(true)
            a.manager.addManualPeer("127.0.0.1", b.port)
            withTimeout(5000) { a.manager.state.first { it.hasLanSession && it.peers.any { p -> p.peerId == b.id } } }
            assertTrue(a.manager.sendText("native manager fixture 世界", b.id))
            assertEquals("native manager fixture 世界", b.rows().single().value)
            eventually { a.pending().isEmpty() }
            assertTrue(a.manager.state.value.settings.authorizedPeers.isEmpty())
            assertTrue(b.manager.state.value.settings.authorizedPeers.isEmpty())
            a.manager.setEnabled(false)
            assertFalse(a.manager.state.value.listening); assertFalse(a.store.read().enabled)
            assertFalse(a.manager.sendText("disabled", b.id))
        } finally { a.close(); b.close() }
    }

    @Test fun offlineAuthorizedHistoryIsQueuedThenFlushedAfterReconnect() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            a.initialize("Sender"); b.initialize("Receiver")
            a.store.rememberEndpoint(PeerEndpoint(b.id, "Receiver", "127.0.0.1", b.port, System.currentTimeMillis() / 1000.0))
            a.manager.updateCapabilities(b.id, clipboard = true, notifications = false)
            a.manager.setEnabled(true)
            a.manager.broadcastText("queued while offline")
            assertEquals(1, a.pending()[b.id])
            b.manager.setEnabled(true)
            a.manager.tick()
            eventually { b.rows().any { it.value == "queued while offline" } && a.pending().isEmpty() }
            assertTrue(b.manager.state.value.settings.authorizedPeers.isEmpty())
        } finally { a.close(); b.close() }
    }

    @Test fun fetchReplayKeepsExistingRowsAndCopiesNewestNewItem() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            a.initialize("Source"); b.initialize("Catch-up")
            ClipyDatabase(context, a.file).use {
                HistoryRepository(it).saveText("older", System.currentTimeMillis() - 10000)
                HistoryRepository(it).saveText("newer", System.currentTimeMillis() - 5000)
            }
            ClipyDatabase(context, b.file).use { HistoryRepository(it).saveText("older", System.currentTimeMillis() - 10000) }
            val old = b.rows().single()
            a.manager.updateCapabilities(b.id, true, false); b.manager.updateCapabilities(a.id, true, false)
            a.manager.setEnabled(true); b.manager.setEnabled(true)
            b.manager.addManualPeer("127.0.0.1", a.port)
            val write = withTimeout(7000) { b.writes.receive() }
            assertEquals("newer", write.clipboardText)
            assertEquals(old, b.rows().first { it.value == "older" })
            assertEquals(2, b.rows().size)
            assertTrue(a.pending().isEmpty()); assertTrue(b.pending().isEmpty())
        } finally { a.close(); b.close() }
    }

    @Test fun noOpConnectionSaveKeepsSessionAndChangedPortRetainsIdentity() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            a.initialize("A"); b.initialize("B")
            a.manager.setEnabled(true); b.manager.setEnabled(true)
            a.manager.addManualPeer("127.0.0.1", b.port)
            withTimeout(5000) { b.manager.state.first { it.hasLanSession } }
            assertTrue(b.manager.saveConnection("B", b.port))
            assertTrue(b.manager.state.value.hasLanSession)
            val id = b.id
            assertTrue(b.manager.saveConnection("Name only", b.port))
            assertTrue(b.manager.state.value.listening)
            assertEquals(id, b.id)
            val nextPort = ServerSocket(0).use { it.localPort }
            assertTrue(b.manager.saveConnection("Renamed B", nextPort))
            assertEquals(id, b.id); assertEquals(nextPort, b.port)
            assertEquals("Renamed B", b.store.read().name)
            assertTrue(b.manager.state.value.listening)
        } finally { a.close(); b.close() }
    }
}
