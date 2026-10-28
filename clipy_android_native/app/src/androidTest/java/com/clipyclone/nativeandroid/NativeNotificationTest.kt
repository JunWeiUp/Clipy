package com.clipyclone.nativeandroid

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.notifications.*
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class NativeNotificationTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun entry(id: String, body: String, pkg: String = "com.tencent.mm", key: String = "slot") = NotificationEntry(
        id, key, pkg, "Fixture App", "Conversation", null, body, System.currentTimeMillis(), "group")
    private fun <T> fixture(block: (File, NotificationRepository) -> T): T {
        val file = File(context.cacheDir, "notifications-${UUID.randomUUID()}.db")
        try { return ClipyDatabase(context, file).use { block(file, NotificationRepository(it)) } }
        finally { SQLiteDatabase.deleteDatabase(file) }
    }
    @Test fun wechatArchivesOldSnapshotsButOtherAppsReplaceAndDeduplicateContent() = fixture { _, repo ->
        assertTrue(repo.upsert(entry("first", "first message")).accepted)
        assertTrue(repo.upsert(entry("second", "second message")).accepted)
        val rows = repo.byPackage("com.tencent.mm")
        assertEquals(2, rows.size)
        assertTrue(rows.single { it.id == "first" }.isArchived)
        assertEquals("clipy-archived:first", rows.single { it.id == "first" }.notificationKey)
        assertFalse(repo.upsert(entry("duplicate", "second message")).accepted)
        assertTrue(repo.upsert(entry("other-first", "one", "example.chat")).accepted)
        val result = repo.upsert(entry("other-next", "two", "example.chat"))
        assertEquals(listOf("other-first"), result.replaced.map { it.id })
        assertEquals(1, repo.byPackage("example.chat").size)
        assertEquals(2, repo.groups().size)
    }
    @Test fun remoteNotificationCommitsBeforeAckAndDuplicatesAreAcknowledged() = runBlocking {
        val name = "notification-manager-${UUID.randomUUID()}"; val file = File(context.cacheDir, "$name.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val acks = mutableListOf<Pair<String, String>>()
        val crypto = SyncCrypto()
        val manager = NativeNotificationManager(context, scope, crypto, { _, _, _ -> fail("Remote posts must not rebroadcast") }, { peer, id ->
            ClipyDatabase(context, file).use { assertEquals(1, NotificationRepository(it).count()) }
            acks += peer to id
        }, file, attachListener = false, preferences = prefs)
        try {
            val notification = entry("remote-id", "remote fixture")
            val frame = SyncEnvelope(SyncType.NOTIF_POST, "peer", payload = crypto.encryptText(notification.json().toString()))
            manager.receive("peer", frame); manager.receive("peer", frame)
            assertEquals(listOf("peer" to "remote-id", "peer" to "remote-id"), acks)
        } finally { manager.close(); scope.cancel(); context.deleteSharedPreferences(name); SQLiteDatabase.deleteDatabase(file) }
    }
    @Test fun failedRemoteStoreWithholdsAck() = runBlocking {
        val name = "notification-failure-${UUID.randomUUID()}"; val file = File(context.cacheDir, "$name.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); var acknowledged = false
        val crypto = SyncCrypto(); val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        ClipyDatabase(context, file).use { it.writableDatabase.execSQL("CREATE TRIGGER fail_notification BEFORE INSERT ON notifications BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
        val manager = NativeNotificationManager(context, scope, crypto, { _, _, _ -> }, { _, _ -> acknowledged = true }, file, false, prefs)
        try {
            manager.receive("peer", SyncEnvelope(SyncType.NOTIF_POST, "peer", payload = crypto.encryptText(entry("no-ack", "blocked").json().toString())))
            assertFalse(acknowledged)
        } finally { manager.close(); scope.cancel(); context.deleteSharedPreferences(name); SQLiteDatabase.deleteDatabase(file) }
    }
    @Test fun nativePostsPersistPendingBeforeBroadcastAndAckMarksSynced() = runBlocking {
        val name = "notification-local-${UUID.randomUUID()}"; val file = File(context.cacheDir, "$name.db")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val broadcasts = mutableListOf<Triple<String, String, String>>()
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE).apply { edit().putBoolean("flutter.notificationSyncEnabled", true).commit() }
        val manager = NativeNotificationManager(context, scope, SyncCrypto(), { type, content, hash ->
            if (type == SyncType.NOTIF_POST) ClipyDatabase(context, file).use { assertTrue(hash in NotificationRepository(it).pendingIds()) }
            broadcasts += Triple(type, content, hash)
        }, { _, _ -> }, file, false, prefs)
        try {
            fun post(body: String) = JSONObject().put("key", "same-slot").put("packageName", "example.chat").put("appName", "Example")
                .put("title", "Title").put("body", body).put("postTime", System.currentTimeMillis())
            manager.ingestPosted(post("one")); manager.ingestPosted(post("two"))
            assertEquals(listOf(SyncType.NOTIF_POST, SyncType.NOTIF_DISMISS, SyncType.NOTIF_POST), broadcasts.map { it.first })
            val id = broadcasts.last().third
            manager.receive("peer", SyncEnvelope(SyncType.NOTIF_ACK, "peer", hash = id))
            ClipyDatabase(context, file).use { db ->
                val repo = NotificationRepository(db)
                assertFalse(repo.hasPending()); assertEquals(1, repo.page().single().syncState)
            }
        } finally { manager.close(); scope.cancel(); context.deleteSharedPreferences(name); SQLiteDatabase.deleteDatabase(file) }
    }
}
