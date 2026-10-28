package com.clipyclone.nativeandroid

import android.app.ActivityManager
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.clipyclone.clipy_android.ClipyApplication
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.ServerSocket
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class NativeServiceLifecycleTest {
    @Suppress("DEPRECATION")
    @Test fun foregroundServiceReceivesAfterActivityClosesAndStopsWhenDisabled() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as ClipyApplication
        app.sync.initialize()
        val before = app.sync.state.value.settings
        val prefs = app.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
        val cacheKey = "flutter.clipy.peerEndpoints.v2"
        val cacheBefore = prefs.getString(cacheKey, null)
        // Never interrupt an intentionally configured emulator/phone session.
        assumeTrue(!before.enabled && before.authorizedPeers.isEmpty())
        val text = "native FGS fixture ${UUID.randomUUID()}"
        val hash = ContentHash.text(text)
        val acknowledged = CompletableDeferred<Unit>()
        val clientId = UUID.randomUUID().toString()
        val client = NativeLanTransport({ _, frame -> if (frame.type == SyncType.ACK && frame.hash == hash) acknowledged.complete(Unit) })
        var activity: android.app.Activity? = null
        var previousClipboard: android.content.ClipData? = null
        var restoreClipboard = false
        // Explicit fixture option: wake our own window using the public Activity API.
        // Never change system input/security settings or dismiss a secure keyguard.
        val wake = InstrumentationRegistry.getArguments().getString("wakeForForegroundTest") == "true"
            && !app.getSystemService(android.app.KeyguardManager::class.java).isDeviceSecure
        val lifecycle = ActivityLifecycleMonitorRegistry.getInstance()
        val onCreated = ActivityLifecycleCallback { candidate, stage ->
            if (wake && candidate is MainActivity && stage == Stage.CREATED) {
                candidate.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                if (android.os.Build.VERSION.SDK_INT >= 27) candidate.setTurnScreenOn(true)
                else {
                    @Suppress("DEPRECATION")
                    candidate.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
                }
            }
        }
        fun serviceRunning() = app.getSystemService(ActivityManager::class.java).getRunningServices(100)
            .any { it.service.className == "com.clipyclone.clipy_android.ClipySyncForegroundService" && it.foreground }
        try {
            instrumentation.runOnMainSync { lifecycle.addLifecycleCallback(onCreated) }
            // MainActivity is singleTask. Reusing a task restored before this test's
            // activity monitor starts cannot satisfy startActivitySync's creation wait.
            activity = instrumentation.startActivitySync(Intent(app, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            if (wake) {
                withTimeout(5000) { while (activity?.hasWindowFocus() != true) delay(50) }
                instrumentation.runOnMainSync {
                    previousClipboard = app.getSystemService(android.content.ClipboardManager::class.java).primaryClip
                }
                // A borrowed content-URI grant may expire when the clipboard changes.
                // Never overwrite a personal rich clipboard that cannot be restored exactly.
                assumeTrue("Keep the existing rich clipboard untouched", previousClipboard?.let { clip ->
                    (0 until clip.itemCount).all { clip.getItemAt(it).uri == null && clip.getItemAt(it).intent == null }
                } ?: true)
                restoreClipboard = true
            }
            val port = ServerSocket(0).use { it.localPort }
            assertTrue(app.sync.saveConnection("Foreground fixture", port))
            app.setSyncEnabled(true)
            withTimeout(10000) { while (!serviceRunning()) delay(30) }
            assertTrue(app.sync.state.value.listening)
            instrumentation.runOnMainSync { activity?.finish() }
            activity = null
            client.start(clientId, "Fixture sender", 0)
            assertNotNull(client.connect("127.0.0.1", port, before.peerId))
            assertTrue(client.send(before.peerId, SyncEnvelope(SyncType.HISTORY_DIRECT, clientId, hash = hash, payload = SyncCrypto().encryptText(text))))
            withTimeout(5000) { acknowledged.await() }
            ClipyDatabase(app).use { helper ->
                assertEquals(text, HistoryRepository(helper).page(query = text).single().value)
            }
            assertTrue(serviceRunning())
            app.setSyncEnabled(false)
            withTimeout(5000) { while (serviceRunning()) delay(30) }
            assertFalse(app.sync.state.value.listening)
        } finally {
            instrumentation.runOnMainSync { lifecycle.removeLifecycleCallback(onCreated) }
            activity?.let { instrumentation.runOnMainSync { it.finish() } }
            client.stop()
            app.setSyncEnabled(false)
            app.sync.saveConnection(before.name, before.port)
            if (restoreClipboard) instrumentation.runOnMainSync {
                val clipboard = app.getSystemService(android.content.ClipboardManager::class.java)
                previousClipboard?.let(clipboard::setPrimaryClip) ?: run {
                    if (android.os.Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
                    else clipboard.setPrimaryClip(android.content.ClipData.newPlainText("", ""))
                }
            }
            prefs.edit().apply { if (cacheBefore == null) remove(cacheKey) else putString(cacheKey, cacheBefore) }.commit()
            ClipyDatabase(app).use { it.writableDatabase.delete("clipboard_history", "content_hash=?", arrayOf(hash)) }
        }
    }
}
