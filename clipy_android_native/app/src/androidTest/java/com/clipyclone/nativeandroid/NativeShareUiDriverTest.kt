package com.clipyclone.nativeandroid

import android.content.Context
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.clipy_android.ClipyApplication
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Opt-in UI driver: real MainActivity + real encrypted loopback file receiver, manual UI taps. */
@RunWith(AndroidJUnit4::class)
class NativeShareUiDriverTest {
    @Test fun partialFailureThenManualRetrySendsOnlyFailedFile() = runBlocking<Unit> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("shareUiDriver") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(context.packageName.endsWith(".nativepreview"))
        val app = context.applicationContext as ClipyApplication
        app.sync.initialize()
        val before = app.sync.state.value.settings
        assertFalse("Isolated UI fixture requires LAN initially off", before.enabled)
        assertTrue("No personal peers may be configured", before.authorizedPeers.isEmpty())
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val keys = listOf("syncEnabled", "deviceName", "syncPort", "clipboardSyncPeerIds", "notificationSyncPeerIds", "authorizedPeerIds", "manualSyncPeers", "clipy.peerEndpoints.v2").map { "flutter.$it" }
        val saved = keys.associateWith { prefs.all[it] }
        val name = "share-ui-${UUID.randomUUID()}"
        val root = File(context.cacheDir, name).apply { mkdirs() }
        val db = File(root, "data.db")
        val peerPrefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val storage = ReceivedFileStore(context, db, downloads = null, privateDirectory = File(root, "received"))
        val attempts = ConcurrentHashMap<String, Int>()
        val finished = CompletableDeferred<Unit>()
        lateinit var files: NativeFileTransfer
        lateinit var peer: NativeSyncManager
        peer = NativeSyncManager(context, SyncSettingsStore(peerPrefs), db, addresses = { emptyList() },
            handleOtherFrame = { sender, frame ->
                if (frame.type == SyncType.FILE_META) {
                    val meta = JSONObject(peer.crypto.decryptText(frame.payload!!)!!)
                    attempts.merge(meta.getString("name"), 1) { a, b -> a + b }
                    android.util.Log.i("ClipyShareUiFixture", "metadata=${meta.getString("name")} attempt=${attempts[meta.getString("name")]}")
                }
                files.receive(sender, frame)
            }, onPeerDisconnected = { files.disconnected(it) }, onStopped = { files.reset() })
        files = NativeFileTransfer(scope, { peer.state.value.settings.let { it.peerId to it.name } }, peer.crypto, storage,
            { peer.fileChannel(it) }, { sender, frame ->
                val ack = JSONObject(peer.crypto.decryptText(frame.payload!!)!!)
                if (!ack.optBoolean("ok")) {
                    ClipyDatabase(context, db).use { it.writableDatabase.execSQL("DROP TRIGGER IF EXISTS fail_second_file") }
                    android.util.Log.i("ClipyShareUiFixture", "phase=second-file-rejected-retry-now")
                }
                peer.sendOnConnection(sender, frame)
            }, { record ->
                android.util.Log.i("ClipyShareUiFixture", "committed=${record.name}")
                if (record.name == "two.bin") finished.complete(Unit)
            })
        try {
            peer.initialize(); peer.saveConnection("Parity file receiver", ServerSocket(0).use { it.localPort })
            ClipyDatabase(context, db).use { it.writableDatabase.execSQL("CREATE TRIGGER fail_second_file BEFORE INSERT ON file_transfers WHEN NEW.file_name='two.bin' BEGIN SELECT RAISE(ABORT, 'fixture second file failure'); END") }
            peer.setEnabled(true)
            app.sync.saveConnection(before.name, ServerSocket(0).use { it.localPort })
            app.sync.setEnabled(true)
            app.sync.addManualPeer("127.0.0.1", peer.state.value.settings.port)
            withTimeout(5000) { app.sync.state.first { it.peers.any { p -> p.peerId == peer.state.value.settings.peerId && p.discovered } } }
            context.contentResolver.call(Uri.parse("content://${ShareFixtureProvider.AUTHORITY}"), "launchMultipleShare", "nativepreview", null)
            android.util.Log.i("ClipyShareUiFixture", "phase=ready-manual-select-send-and-retry")
            withTimeout(10 * 60 * 1000L) { finished.await() }
            assertEquals(1, attempts["one.bin"]); assertEquals(2, attempts["two.bin"])
            val records = storage.page()
            assertEquals(2, records.size)
            for (record in records) assertArrayEquals(ShareFixtureProvider.bytes(record.name.substringBefore('.')), File(record.path).readBytes())
            android.util.Log.i("ClipyShareUiFixture", "PASS first-file-once second-file-twice exact-bytes")
            delay(3000) // allow real UI to consume ACK and close before fixture cleanup
        } finally {
            app.sync.setEnabled(false); peer.shutdown(); files.reset(); scope.cancel()
            val editor = prefs.edit()
            for ((key, value) in saved) when (value) {
                null -> editor.remove(key)
                is Boolean -> editor.putBoolean(key, value)
                is String -> editor.putString(key, value)
                is Int -> editor.putInt(key, value)
                is Long -> editor.putLong(key, value)
                is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
            }
            check(editor.commit()); app.sync.saveConnection(before.name, before.port)
            context.deleteSharedPreferences(name); root.deleteRecursively()
        }
    }
}
