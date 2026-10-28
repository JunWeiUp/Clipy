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
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.RandomAccessFile
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class NativeFileTransferTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private class Fixture(val context: Context, idle: Long = 120000) {
        val name = "files-${UUID.randomUUID()}"
        val root = File(context.cacheDir, name).apply { mkdirs() }
        val db = File(root, "data.db")
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val storage = ReceivedFileStore(context, db, downloads = null, privateDirectory = File(root, "received"))
        val acks = Channel<SyncEnvelope>(Channel.UNLIMITED)
        val committed = Channel<ReceivedFile>(Channel.UNLIMITED)
        var notificationFailure = false
        lateinit var files: NativeFileTransfer
        val manager = NativeSyncManager(context, SyncSettingsStore(prefs), db, addresses = { emptyList() },
            handleOtherFrame = { peer, frame -> files.receive(peer, frame) },
            onPeerDisconnected = { files.disconnected(it) }, onStopped = { files.reset() })
        init {
            files = NativeFileTransfer(scope, { manager.state.value.settings.let { it.peerId to it.name } }, manager.crypto, storage,
                { manager.fileChannel(it) }, { peer, frame -> acks.send(frame); manager.sendOnConnection(peer, frame) },
                { committed.trySend(it); if (notificationFailure) throw SecurityException("fixture permission denied") }, idle)
        }
        val id get() = manager.state.value.settings.peerId
        val port get() = manager.state.value.settings.port
        suspend fun initialize() { manager.initialize(); manager.saveConnection(name, ServerSocket(0).use { it.localPort }) }
        suspend fun close() { manager.shutdown(); files.reset(); scope.cancel(); acks.close(); committed.close(); context.deleteSharedPreferences(name); root.deleteRecursively() }
        suspend fun parts() = storage.directory().listFiles()?.filter { it.name.endsWith(".part") } ?: emptyList()
    }
    private suspend fun connect(a: Fixture, b: Fixture) {
        a.initialize(); b.initialize(); a.manager.setEnabled(true); b.manager.setEnabled(true)
        a.manager.addManualPeer("127.0.0.1", b.port)
        withTimeout(5000) { a.manager.state.first { it.hasLanSession && it.peers.any { p -> p.peerId == b.id } } }
    }
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun peer() = LanPeer(UUID.randomUUID().toString(), "Fixture sender", "127.0.0.1", 5566, true, false)
    private fun meta(fixture: Fixture, peer: LanPeer, id: String, name: String, bytes: ByteArray, declaredHash: String = hash(bytes), size: Long = bytes.size.toLong(), chunks: Int = if (bytes.isEmpty()) 0 else 1) = SyncEnvelope(
        SyncType.FILE_META, peer.peerId, name = peer.name,
        payload = fixture.manager.crypto.encryptText(JSONObject().put("fileId", id).put("name", name).put("size", size)
            .put("chunkSize", FILE_CHUNK_BYTES).put("chunks", chunks).put("sha256", declaredHash).toString()))
    private fun chunk(fixture: Fixture, peer: LanPeer, id: String, bytes: ByteArray, index: Int = 0) = SyncEnvelope(
        SyncType.FILE_CHUNK, peer.peerId, msgId = id, payload = fixture.manager.crypto.encryptBytes(ByteBuffer.allocate(bytes.size + 4).putInt(index).put(bytes).array()))
    private suspend fun ack(fixture: Fixture): JSONObject = withTimeout(5000) {
        JSONObject(fixture.manager.crypto.decryptText(fixture.acks.receive().payload!!)!!)
    }
    private suspend fun eventually(block: suspend () -> Boolean) = withTimeout(5000) { while (!block()) delay(20) }

    @Test fun simultaneousBidirectionalMultichunkFilesCommitBeforeAcknowledgement() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            connect(a, b)
            val bytesA = ByteArray(3 * FILE_CHUNK_BYTES + 71) { (it % 251).toByte() }
            val bytesB = ByteArray(2 * FILE_CHUNK_BYTES + 123) { ((it * 3) % 253).toByte() }
            val sourceA = File(a.root, "alpha.bin").apply { writeBytes(bytesA) }
            val sourceB = File(b.root, "beta.bin").apply { writeBytes(bytesB) }
            val results = withTimeout(15000) { awaitAll(async { a.files.send(sourceA, b.id) }, async { b.files.send(sourceB, a.id) }) }
            assertEquals(listOf(true, true), results)
            assertArrayEquals(bytesB, File(a.storage.page().single().path).readBytes())
            assertArrayEquals(bytesA, File(b.storage.page().single().path).readBytes())
            assertTrue(a.parts().isEmpty()); assertTrue(b.parts().isEmpty())
            ClipyDatabase(context, a.db).use { assertTrue(PendingSyncRepository(it).counts().isEmpty()) }
            ClipyDatabase(context, b.db).use { assertTrue(PendingSyncRepository(it).counts().isEmpty()) }
        } finally { a.close(); b.close() }
    }

    @Test fun emptyFilesDuplicatesAndNotificationFailureStillHaveCorrectReceipts() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            connect(a, b); b.notificationFailure = true
            val existing = File(b.storage.directory(), "empty.txt").apply { writeText("keep existing") }
            val source = File(a.root, "empty.txt").apply { writeBytes(byteArrayOf()) }
            assertTrue(a.files.send(source, b.id)); assertTrue(a.files.send(source, b.id))
            val records = b.storage.page()
            assertEquals(2, records.size); assertEquals(2, records.map { it.path }.toSet().size)
            assertEquals(setOf("empty (2).txt", "empty (3).txt"), records.map { File(it.path).name }.toSet())
            assertTrue(records.all { it.size == 0L && File(it.path).isFile })
            assertEquals("keep existing", existing.readText())
        } finally { a.close(); b.close() }
    }

    @Test fun checksumFailureAndStorageFailureWithholdSuccessAndRemoveParts() = runBlocking {
        val b = Fixture(context)
        try {
            b.initialize(); val peer = peer(); val bytes = "bad checksum fixture".toByteArray()
            b.files.receive(peer, meta(b, peer, "wrong-hash", "bad.txt", bytes, "0".repeat(64)))
            b.files.receive(peer, chunk(b, peer, "wrong-hash", bytes))
            assertEquals("hashMismatch", ack(b).getString("error"))
            eventually { b.parts().isEmpty() }
            assertTrue(b.storage.page().isEmpty())
            ClipyDatabase(context, b.db).use { it.writableDatabase.execSQL("CREATE TRIGGER fail_file BEFORE INSERT ON file_transfers BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
            b.files.receive(peer, meta(b, peer, "write-failure", "failed.txt", bytes))
            b.files.receive(peer, chunk(b, peer, "write-failure", bytes))
            assertEquals("ioError", ack(b).getString("error"))
            eventually { b.storage.directory().listFiles()?.isEmpty() == true }
            assertTrue(b.storage.page().isEmpty())
        } finally { b.close() }
    }

    @Test fun badOrderOversizeAndRemotePathNamesStayWithinManagedDirectory() = runBlocking {
        val b = Fixture(context)
        try {
            b.initialize(); val peer = peer(); val bytes = byteArrayOf(7)
            b.files.receive(peer, meta(b, peer, "large", "large.bin", bytes, size = FILE_MAX_BYTES + 1))
            assertEquals("tooLarge", ack(b).getString("error"))
            b.files.receive(peer, meta(b, peer, "order", "order.bin", bytes))
            b.files.receive(peer, chunk(b, peer, "order", bytes, index = 1))
            assertFalse(ack(b).getBoolean("ok")); assertTrue(b.parts().isEmpty())
            b.files.receive(peer, meta(b, peer, "../../remote-id", "../unsafe/name.bin", bytes))
            b.files.receive(peer, chunk(b, peer, "../../remote-id", bytes))
            assertTrue(ack(b).getBoolean("ok"))
            val record = b.storage.page().single()
            assertEquals(b.storage.directory().canonicalFile, requireNotNull(File(record.path).parentFile).canonicalFile)
            assertEquals("_unsafe_name.bin", record.name)
            assertArrayEquals(bytes, File(record.path).readBytes())
        } finally { b.close() }
    }

    @Test fun idleTimeoutAndDisconnectCleanUpPartialFilesAndProgress() = runBlocking {
        val b = Fixture(context, idle = 100)
        try {
            b.initialize(); val peer = peer(); val bytes = byteArrayOf(1)
            b.files.receive(peer, meta(b, peer, "idle", "idle.bin", bytes))
            eventually { b.parts().isEmpty() && b.files.active.value.isEmpty() }
            b.files.receive(peer, meta(b, peer, "disconnect", "disconnect.bin", bytes))
            b.files.disconnected(peer)
            assertTrue(b.parts().isEmpty()); assertTrue(b.files.active.value.isEmpty())
            assertTrue(b.storage.page().isEmpty())
        } finally { b.close() }
    }

    @Test fun stoppingSyncAbortsARealTransferWithoutPublishingIncompleteData() = runBlocking {
        val a = Fixture(context); val b = Fixture(context)
        try {
            connect(a, b)
            val source = File(a.root, "interrupted.bin")
            RandomAccessFile(source, "rw").use { it.setLength(64L * FILE_CHUNK_BYTES) }
            val sending = async { a.files.send(source, b.id) }
            withTimeout(15000) { a.files.active.first { it.values.any { p -> p.outgoing && p.transferred >= FILE_CHUNK_BYTES } } }
            a.manager.setEnabled(false)
            assertFalse(withTimeout(5000) { sending.await() })
            eventually { b.parts().isEmpty() && b.files.active.value.isEmpty() }
            assertTrue(b.storage.page().isEmpty())
        } finally { a.close(); b.close() }
    }

    @Test fun retentionDeletesOnlyManagedOldReceiptsAndDirectoryFallbackWorks() = runBlocking {
        val b = Fixture(context)
        try {
            b.initialize()
            val outside = File(b.root, "outside.txt").apply { writeText("must survive") }
            ClipyDatabase(context, b.db).use { helper -> helper.writableDatabase.execSQL(
                "INSERT INTO file_transfers(file_name,file_path,file_size,sender_name,created_at) VALUES('outside',?,1,'Fixture',0)", arrayOf(outside.path)) }
            repeat(21) { index ->
                val part = b.storage.createPart().apply { writeText("file $index") }
                b.storage.publish(part, "file-$index.txt", part.length(), "Fixture")
            }
            assertEquals(20, b.storage.page(limit = 100).size)
            assertFalse(File(b.storage.directory(), "file-0.txt").exists())
            assertEquals("must survive", outside.readText())
            val notDirectory = File(b.root, "not-directory").apply { writeText("file") }
            val fallback = ReceivedFileStore(context, b.db, notDirectory, File(b.root, "fallback"))
            assertEquals(File(b.root, "fallback").canonicalFile, fallback.directory())
        } finally { b.close() }
    }
}
