package com.clipyclone.nativeandroid

import android.content.Context
import android.util.Base64
import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.sync.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.*
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SyncSettingsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val local = "00000000-0000-0000-0000-000000000001"
    private val remote = "00000000-0000-0000-0000-000000000002"
    private fun prefsFixture(block: (android.content.SharedPreferences) -> Unit) {
        val name = "sync-fixture-${UUID.randomUUID()}"
        try { block(context.getSharedPreferences(name, Context.MODE_PRIVATE)) }
        finally { context.deleteSharedPreferences(name) }
    }
    @Test fun listCodecReadsRealLegacySerializationAndWritesCurrentJson() {
        val items = arrayListOf(remote, local)
        val bytes = ByteArrayOutputStream().apply { ObjectOutputStream(this).use { it.writeObject(items) } }.toByteArray()
        assertEquals(items, FlutterStringLists.decode(FlutterStringLists.PREFIX + Base64.encodeToString(bytes, Base64.DEFAULT)))
        assertEquals(items, FlutterStringLists.decode(FlutterStringLists.encode(items)))
        assertEquals(items.toSet(), FlutterStringLists.decode(items.toSet())!!.toSet())
    }
    @Test fun initializationPreservesIdentityDataAndUnknownPreferences() = prefsFixture { prefs ->
        prefs.edit().putString("flutter.peerId", local).putString("flutter.appearance", "dark")
            .putString("flutter.authorizedPeerIds", FlutterStringLists.encode(listOf(remote, "legacy-name")))
            .putString("flutter.syncRelayDeviceId", "relay-fixture").putBoolean("flutter.syncEnabled", true).commit()
        var cleared = 0
        val store = SyncSettingsStore(prefs)
        val first = store.initialize { cleared++ }
        assertEquals(local, first.peerId); assertEquals(setOf(remote), first.clipboardPeers)
        assertEquals(setOf(remote), first.notificationPeers); assertTrue(first.enabled)
        assertEquals("dark", prefs.getString("flutter.appearance", null))
        assertEquals("relay-fixture", prefs.getString("flutter.syncRelayDeviceId", null))
        store.initialize { cleared++ }; assertEquals(1, cleared)
    }
    @Test fun connectionValidationDoesNotPartiallySaveAndPortUsesFlutterLong() = prefsFixture { prefs ->
        val store = SyncSettingsStore(prefs); store.initialize { }
        assertTrue(store.saveConnection("  Example Phone  ", 6000))
        assertEquals(6000L, prefs.getLong("flutter.syncPort", 0))
        assertFalse(store.saveConnection("Example Phone", 6000))
        try { store.saveConnection("different", 70000); fail("Invalid port saved") } catch (_: IllegalArgumentException) { }
        assertEquals("Example Phone", store.read().name); assertEquals(6000, store.read().port)
        store.setCapabilities(remote, true, false)
        assertEquals(setOf(remote), store.read().clipboardPeers); assertTrue(store.read().notificationPeers.isEmpty())
        store.addManualPeer("192.0.2.10", 5566); store.addManualPeer("192.0.2.10", 5566)
        assertEquals(listOf("192.0.2.10:5566"), store.manualPeers())
        assertFalse(validIPv4("192.0.2.999"))
    }
    @Test fun pendingQueuePersistsAndAckIsScopedToPeerAndHash() {
        val file = File(context.cacheDir, "pending-fixture-${UUID.randomUUID()}.db")
        val now = System.currentTimeMillis()
        try {
            ClipyDatabase(context, file).use { db ->
                val queue = PendingSyncRepository(db)
                assertTrue(queue.enqueue(PendingFrame(local, "shared", SyncType.HISTORY, byteArrayOf(1, 2), now), now))
                assertTrue(queue.enqueue(PendingFrame(remote, "shared", SyncType.HISTORY, byteArrayOf(3, 4), now), now))
                assertEquals(1, queue.remove(local, "shared"))
                assertTrue(queue.hasPending(remote)); assertFalse(queue.hasPending(local))
            }
            ClipyDatabase(context, file).use { db ->
                val queue = PendingSyncRepository(db)
                assertArrayEquals(byteArrayOf(3, 4), queue.fetchDue(remote, now).single().data)
                queue.cleanOld(now + PendingSyncRepository.TTL_MS + 1)
                assertFalse(queue.hasPending(remote))
            }
        } finally { SQLiteDatabase.deleteDatabase(file) }
    }
    @Test fun pendingQueueCapStillAllowsReplacingAnExistingHash() {
        val file = File(context.cacheDir, "pending-cap-${UUID.randomUUID()}.db")
        val now = System.currentTimeMillis()
        try { ClipyDatabase(context, file).use { db ->
            val queue = PendingSyncRepository(db)
            repeat(500) { assertTrue(queue.enqueue(PendingFrame(remote, "h$it", SyncType.HISTORY, byteArrayOf(1), now), now)) }
            assertFalse(queue.enqueue(PendingFrame(remote, "overflow", SyncType.HISTORY, byteArrayOf(1), now), now))
            assertTrue(queue.enqueue(PendingFrame(remote, "h0", SyncType.HISTORY, byteArrayOf(9), now), now))
            assertEquals(500, queue.counts()[remote])
        } } finally { SQLiteDatabase.deleteDatabase(file) }
    }
}
