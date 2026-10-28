package com.clipyclone.nativeandroid

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.clipy_android.ClipyApplication
import com.clipyclone.nativeandroid.data.ClipyDatabase
import com.clipyclone.nativeandroid.data.NotificationRepository
import com.clipyclone.nativeandroid.sync.*
import com.clipyclone.nativeandroid.notifications.NotificationEntry
import com.clipyclone.nativeandroid.data.PendingSyncRepository
import java.net.ServerSocket
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Requires adb-granted listener access and test-APK POST_NOTIFICATIONS on the isolated emulator. */
@RunWith(AndroidJUnit4::class)
class NativeNotificationSystemTest {
    private companion object {
        // API 26 PackageManagerService batches DONT_KILL_APP component changes for 10s
        // (android-8.0.0_r1 BROADCAST_DELAY). Recovery first attempts soft rebind for 2s;
        // allow the system broadcast to arrive, while keeping post/store/ACK deadlines unchanged.
        const val LISTENER_RECOVERY_TIMEOUT_MS = 20_000L
    }
    @Test fun realListenerCollectsOnlyTheFixtureAndReceivesSystemRemovalWithoutAnActivity() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val app = context.applicationContext as ClipyApplication
        app.sync.initialize(); app.notifications.initialize()
        assertFalse("Keep LAN disabled: this fixture must not reach any external device", app.sync.state.value.settings.enabled)
        assertTrue("Grant nativepreview listener access before this test", app.notifications.platform.status().permission)
        val preferences = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val keys = listOf("flutter.notificationSyncEnabled", "flutter.notificationCollectedPackages", "flutter.notificationSyncedPackages")
        val previous = keys.associateWith { preferences.all[it] }
        val token = UUID.randomUUID().toString()
        val provider = Uri.parse("content://${ShareFixtureProvider.AUTHORITY}")
        val packageName = instrumentation.context.packageName
        var id: String? = null
        try {
            preferences.edit().putBoolean(keys[0], true)
                .putString(keys[1], FlutterStringLists.encode(listOf(packageName)))
                .putString(keys[2], FlutterStringLists.encode(listOf(packageName))).commit()
            app.notifications.reloadPreferences()
            app.notifications.setEnabled(true) // real enable path also refreshes/rebinds without an Activity
            android.util.Log.i("ClipyNlsFixture", "phase=await-listener pid=${android.os.Process.myPid()}")
            withTimeout(LISTENER_RECOVERY_TIMEOUT_MS) { while (!app.notifications.platform.status().connected) delay(50) }
            android.util.Log.i("ClipyNlsFixture", "phase=listener-connected")
            context.contentResolver.call(provider, "postNotification", token, null)
            android.util.Log.i("ClipyNlsFixture", "phase=posted-waiting-for-persistence")
            val entry = withTimeout(10000) {
                var found = app.notifications.forPackage(packageName).firstOrNull { it.body == "Newest fixture $token" }
                while (found == null) { delay(30); found = app.notifications.forPackage(packageName).firstOrNull { it.body == "Newest fixture $token" } }
                found
            }
            id = entry.id
            assertEquals(packageName, entry.packageName)
            assertEquals("Native NLS fixture", entry.title)
            assertEquals("Fixture subtitle", entry.subtitle)
            assertNotNull(entry.notificationKey)
            ClipyDatabase(context).use { assertTrue(entry.id in NotificationRepository(it).pendingIds()) }
            context.contentResolver.call(provider, "cancelNotification", token, null)
            withTimeout(5000) { while (app.notifications.forPackage(packageName).any { it.id == entry.id }) delay(30) }
        } finally {
            runCatching { context.contentResolver.call(provider, "cancelNotification", token, null) }
            app.notifications.setEnabled(false)
            app.notifications.awaitCollectionIdle()
            ClipyDatabase(context).use { helper ->
                helper.writableDatabase.delete("notifications", "package_name=? AND (id LIKE ? OR body LIKE ?)", arrayOf(packageName, "%$token%", "%$token%"))
                helper.writableDatabase.delete("pending_notification_sync", "notification_id LIKE ?", arrayOf("%$token%"))
                id?.let { NotificationRepository(helper).removePending(it) }
            }
            val edit = preferences.edit()
            previous.forEach { (key, value) -> restore(edit, key, value) }
            check(edit.commit())
            app.notifications.reloadPreferences()
        }
    }
    @Test fun realListenerMirrorsToAnIsolatedV3PeerAndAcknowledgementClearsQueues() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val app = context.applicationContext as ClipyApplication
        app.sync.initialize(); app.notifications.initialize()
        val before = app.sync.state.value.settings
        assertFalse("Fixture requires disabled LAN", before.enabled)
        assertTrue("Fixture requires no configured sharing targets", before.authorizedPeers.isEmpty())
        ClipyDatabase(context).use {
            assertFalse("Fixture must not forward existing notification data", NotificationRepository(it).hasPending())
            assertTrue("Fixture requires no pre-existing sends", PendingSyncRepository(it).counts().isEmpty())
        }
        assertTrue(app.notifications.platform.status().permission)
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val keys = listOf("notificationSyncEnabled", "notificationCollectedPackages", "notificationSyncedPackages", "syncEnabled", "deviceName", "syncPort",
            "clipboardSyncPeerIds", "notificationSyncPeerIds", "authorizedPeerIds", "manualSyncPeers", "clipy.peerEndpoints.v2").map { "flutter.$it" }
        val previous = keys.associateWith { prefs.all[it] }
        val token = UUID.randomUUID().toString(); val peerId = UUID.randomUUID().toString()
        val packageName = instrumentation.context.packageName; val provider = Uri.parse("content://${ShareFixtureProvider.AUTHORITY}")
        val delivered = CompletableDeferred<NotificationEntry>(); val crypto = SyncCrypto()
        lateinit var peer: NativeLanTransport
        peer = NativeLanTransport(onFrame = { sender, frame ->
            if (frame.type == SyncType.NOTIF_POST) {
                val entry = NotificationEntry.fromJson(org.json.JSONObject(crypto.decryptText(frame.payload!!)!!))
                delivered.complete(entry)
                if (entry.packageName == packageName && entry.body == "Newest fixture $token") {
                    peer.send(sender.peerId, SyncEnvelope(SyncType.NOTIF_ACK, peerId, hash = entry.id))
                }
            }
        })
        try {
            prefs.edit().putBoolean("flutter.notificationSyncEnabled", true)
                .putString("flutter.notificationCollectedPackages", FlutterStringLists.encode(listOf(packageName)))
                .putString("flutter.notificationSyncedPackages", FlutterStringLists.encode(listOf(packageName))).commit()
            app.notifications.reloadPreferences()
            app.notifications.setEnabled(true)
            android.util.Log.i("ClipyNlsFixture", "phase=await-listener-wire pid=${android.os.Process.myPid()}")
            withTimeout(LISTENER_RECOVERY_TIMEOUT_MS) { while (!app.notifications.platform.status().connected) delay(30) }
            android.util.Log.i("ClipyNlsFixture", "phase=listener-connected-wire")
            val peerPort = peer.start(peerId, "NLS loopback fixture", 0)
            val localPort = ServerSocket(0).use { it.localPort }
            app.sync.saveConnection("NLS fixture", localPort)
            app.sync.updateCapabilities(peerId, clipboard = false, notifications = true)
            app.sync.setEnabled(true) // no foreground-service notification is posted by this fixture
            app.sync.addManualPeer("127.0.0.1", peerPort)
            context.contentResolver.call(provider, "postNotification", token, null)
            android.util.Log.i("ClipyNlsFixture", "phase=posted-waiting-for-wire")
            val entry = withTimeout(10000) { delivered.await() }
            assertEquals(packageName, entry.packageName); assertEquals("Newest fixture $token", entry.body)
            assertEquals("Native NLS fixture", entry.title)
            withTimeout(5000) {
                while (true) {
                    val done = ClipyDatabase(context).use { db ->
                        NotificationRepository(db).let { repo -> !repo.hasPending() && repo.byPackage(packageName).any { it.id == entry.id && it.syncState == 1 } } && PendingSyncRepository(db).counts().isEmpty()
                    }
                    if (done) break
                    delay(30)
                }
            }
        } finally {
            runCatching { context.contentResolver.call(provider, "cancelNotification", token, null) }
            app.notifications.setEnabled(false); app.notifications.awaitCollectionIdle()
            app.sync.setEnabled(false); peer.stop()
            app.sync.updateCapabilities(peerId, clipboard = false, notifications = false)
            ClipyDatabase(context).use { db ->
                db.writableDatabase.delete("notifications", "package_name=? AND (id LIKE ? OR body LIKE ?)", arrayOf(packageName, "%$token%", "%$token%"))
                db.writableDatabase.delete("pending_notification_sync", "notification_id LIKE ?", arrayOf("%$token%"))
                PendingSyncRepository(db).removePeer(peerId)
            }
            val editor = prefs.edit(); previous.forEach { (key, value) -> restore(editor, key, value) }; check(editor.commit())
            app.sync.saveConnection(before.name, before.port)
            app.notifications.reloadPreferences()
        }
    }

    /** Driver opt-in: seed only test-package collection + enabled=true BEFORE process creation. */
    @Test fun coldStartRecoversAnAlreadyEnabledListenerWithoutAnActivityOrEnableCall() = runBlocking<Unit> {
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("notificationColdStartFixture") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val app = context.applicationContext as ClipyApplication
        val packageName = instrumentation.context.packageName
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        assertTrue(prefs.getBoolean("flutter.notificationSyncEnabled", false))
        val preparedPid = context.getSharedPreferences("native_nls_fixture_backup", Context.MODE_PRIVATE).getInt("preparePid", -1)
        assertTrue("Use the cold fixture prepare driver first", preparedPid > 0)
        assertNotEquals("Cold-start fixture must run in a different process", preparedPid, android.os.Process.myPid())
        assertEquals(listOf(packageName), FlutterStringLists.decode(prefs.all["flutter.notificationCollectedPackages"]))
        assertEquals(listOf(packageName), FlutterStringLists.decode(prefs.all["flutter.notificationSyncedPackages"]))
        assertFalse(prefs.getBoolean("flutter.syncEnabled", false))
        val token = UUID.randomUUID().toString(); val provider = Uri.parse("content://${ShareFixtureProvider.AUTHORITY}")
        try {
            // initialize is the exact Application cold-start API, not a UI toggle or forced reconnect.
            app.notifications.initialize()
            assertTrue(app.notifications.state.value.enabled)
            assertTrue(app.notifications.platform.status().permission)
            android.util.Log.i("ClipyNlsFixture", "phase=cold-start-await-listener pid=${android.os.Process.myPid()}")
            withTimeout(LISTENER_RECOVERY_TIMEOUT_MS) { while (!app.notifications.platform.status().connected) delay(30) }
            context.contentResolver.call(provider, "postNotification", token, null)
            withTimeout(10000) { while (app.notifications.forPackage(packageName).none { it.body == "Newest fixture $token" }) delay(30) }
            android.util.Log.i("ClipyNlsFixture", "phase=cold-start-persisted")
        } finally {
            runCatching { context.contentResolver.call(provider, "cancelNotification", token, null) }
            app.notifications.setEnabled(false); app.notifications.awaitCollectionIdle()
            ClipyDatabase(context).use { db ->
                db.writableDatabase.delete("notifications", "package_name=? AND (id LIKE ? OR body LIKE ?)", arrayOf(packageName, "%$token%", "%$token%"))
                db.writableDatabase.delete("pending_notification_sync", "notification_id LIKE ?", arrayOf("%$token%"))
            }
            // The adb fixture driver restores its exact pre-test preference backup after this process exits.
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun restore(editor: SharedPreferences.Editor, key: String, value: Any?) {
        when (value) {
            null -> editor.remove(key)
            is Boolean -> editor.putBoolean(key, value)
            is String -> editor.putString(key, value)
            is Set<*> -> editor.putStringSet(key, value as Set<String>)
            is Long -> editor.putLong(key, value)
            is Int -> editor.putInt(key, value)
            else -> error("Unsupported fixture preference type")
        }
    }
}
