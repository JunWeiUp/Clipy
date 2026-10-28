package com.clipyclone.nativeandroid

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class NativeLanTransportTest {
    private val leftId = "00000000-0000-0000-0000-000000000001"
    private val rightId = "00000000-0000-0000-0000-000000000002"

    @Test fun encryptedTextUsesARealSocketAndOnlyMatchingAckCompletesReceipt() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val receipts = TextDeliveryReceipts(owner, 3000)
        val crypto = SyncCrypto()
        var committed = false
        lateinit var right: NativeLanTransport
        val left = NativeLanTransport(onFrame = { peer, env ->
            if (env.type == SyncType.ACK) receipts.acknowledge(peer.peerId, env.hash ?: "")
        })
        right = NativeLanTransport(onFrame = { peer, env ->
            assertEquals("fixture text 世界", crypto.decryptText(env.payload!!))
            // The application handler must complete persistence before sending this ACK.
            committed = true
            right.send(peer.peerId, SyncEnvelope(SyncType.ACK, rightId, hash = env.hash))
        })
        try {
            left.start(leftId, "Left", 0); val port = right.start(rightId, "Right", 0)
            assertNotNull(left.connect("127.0.0.1", port, rightId))
            val result = receipts.send(rightId, "fixture-hash") {
                assertTrue(left.send(rightId, SyncEnvelope(SyncType.HISTORY_DIRECT, leftId,
                    hash = "fixture-hash", payload = crypto.encryptText("fixture text 世界"))))
            }
            assertTrue(result); assertTrue(committed); assertEquals(0, receipts.size)
        } finally { left.stop(); right.stop(); receipts.cancelAll(); owner.cancel() }
    }

    @Test fun crossedConnectionsConvergeAndStopRemovesAllSessions() = runBlocking {
        val left = NativeLanTransport({ _, _ -> }); val right = NativeLanTransport({ _, _ -> })
        try {
            var lp = 0; var rp = 0
            repeat(4) {
                lp = left.start(leftId, "Left", lp); rp = right.start(rightId, "Right", rp)
                awaitAll(async { left.connect("127.0.0.1", rp, rightId) }, async { right.connect("127.0.0.1", lp, leftId) })
                withTimeout(3000) {
                    left.peers.first { it.size == 1 && !it.single().inbound }
                    right.peers.first { it.size == 1 && it.single().inbound }
                }
                left.stop(); right.stop()
                assertTrue(left.peers.value.isEmpty()); assertFalse(left.listening.value)
                assertTrue(right.peers.value.isEmpty())
            }
        } finally { left.stop(); right.stop() }
    }

    @Test fun latestProtocolRejectsV2InsteadOfDowngrading() = runBlocking {
        val rejected = CompletableDeferred<Unit>()
        val transport = NativeLanTransport({ _, _ -> }, onError = { error, _ -> if (error == "versionMismatch") rejected.complete(Unit) })
        try {
            val port = transport.start(leftId, "Left", 0)
            withContext(Dispatchers.IO) {
                Socket("127.0.0.1", port).use { raw ->
                    raw.soTimeout = 3000
                    assertNotNull(SyncProtocol.readBody(raw.getInputStream()))
                    raw.getOutputStream().write(SyncProtocol.encode(SyncEnvelope(SyncType.HELLO, rightId, v = 2)))
                    withTimeout(3000) { rejected.await() }
                    assertEquals(-1, raw.getInputStream().read())
                }
            }
            assertTrue(transport.peers.value.isEmpty())
        } finally { transport.stop() }
    }

    @Test fun expectedIdentityMismatchDoesNotAdoptPeer() = runBlocking {
        val left = NativeLanTransport({ _, _ -> }); val right = NativeLanTransport({ _, _ -> })
        try {
            left.start(leftId, "Left", 0); val port = right.start(rightId, "Right", 0)
            assertNull(left.connect("127.0.0.1", port, "different-id"))
            assertTrue(left.peers.value.isEmpty())
        } finally { left.stop(); right.stop() }
    }

    @Test fun stopCancelsAnUnfinishedHandshakeAndAllowsRestart() = runBlocking {
        val transport = NativeLanTransport({ _, _ -> })
        val server = ServerSocket(0)
        try {
            transport.start(leftId, "Left", 0)
            val task = async { runCatching { transport.connect("127.0.0.1", server.localPort) }.getOrNull() }
            val accepted = withContext(Dispatchers.IO) { server.accept() }
            accepted.use {
                withContext(Dispatchers.IO) { assertNotNull(SyncProtocol.readBody(it.getInputStream())) }
                transport.stop()
                withTimeout(1000) { assertNull(task.await()) }
                assertTrue(transport.peers.value.isEmpty())
                assertTrue(transport.start(leftId, "Restart", 0) > 0)
            }
        } finally { server.close(); transport.stop() }
    }

    @Test fun handshakeHasAnAbsoluteDeadlineEvenWhenBytesKeepArriving() = runBlocking {
        val transport = NativeLanTransport({ _, _ -> })
        try {
            val port = transport.start(leftId, "Left", 0)
            withContext(Dispatchers.IO) {
                Socket("127.0.0.1", port).use { raw ->
                    raw.soTimeout = 3500
                    SyncProtocol.readBody(raw.getInputStream())
                    raw.getOutputStream().write(java.nio.ByteBuffer.allocate(4).putInt(100).array())
                    val started = android.os.SystemClock.elapsedRealtime()
                    val trickle = launch(Dispatchers.IO) {
                        try { repeat(10) { raw.getOutputStream().write(' '.code); delay(400) } }
                        catch (_: java.io.IOException) { }
                    }
                    assertEquals(-1, raw.getInputStream().read())
                    assertTrue(android.os.SystemClock.elapsedRealtime() - started < 3200)
                    trickle.cancelAndJoin()
                }
            }
            assertTrue(transport.peers.value.isEmpty())
        } finally { transport.stop() }
    }

    @Test fun duplicateSendsShareReceiptAndWrongPeerCannotConfirmIt() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val receipts = TextDeliveryReceipts(scope, 1000)
        val dispatched = CompletableDeferred<Unit>()
        val count = AtomicInteger()
        try {
            val a = async { receipts.send(rightId, "hash") { count.incrementAndGet(); dispatched.complete(Unit) } }
            dispatched.await()
            val b = async(start = CoroutineStart.UNDISPATCHED) { receipts.send(rightId, "hash") { count.incrementAndGet() } }
            receipts.acknowledge(leftId, "hash")
            assertEquals(1, receipts.size)
            receipts.acknowledge(rightId, "hash")
            assertTrue(a.await()); assertTrue(b.await()); assertEquals(1, count.get())
            val stopped = async(start = CoroutineStart.UNDISPATCHED) { receipts.send(rightId, "other") { } }
            receipts.cancelAll(); assertFalse(stopped.await()); assertEquals(0, receipts.size)
        } finally { receipts.cancelAll(); scope.cancel() }
    }
}
