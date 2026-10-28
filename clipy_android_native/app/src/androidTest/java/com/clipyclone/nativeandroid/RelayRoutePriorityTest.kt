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
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class RelayRoutePriorityTest {
    private val aId = "00000000-0000-0000-0000-000000000001"
    private val bId = "00000000-0000-0000-0000-000000000002"
    private suspend fun tunnel(a: NativeLanTransport, b: NativeLanTransport) = withContext(Dispatchers.IO) {
        val pair = ServerSocket(0).use { listener ->
            val client = Socket("127.0.0.1", listener.localPort)
            client to listener.accept()
        }
        try {
            coroutineScope {
                awaitAll(async { a.adoptRelaySocket(pair.first, bId, "relay:fixture-b", false) },
                    async { b.adoptRelaySocket(pair.second, aId, "relay:fixture-a", true) })
            }
        } catch (error: Throwable) { pair.first.close(); pair.second.close(); throw error }
    }
    @Test fun lanReplacesRelayOnlyWhenTransfersAreIdleAndRelayCannotReplaceLan() = runBlocking {
        val transferring = AtomicBoolean(true)
        val a = NativeLanTransport({ _, _ -> }, allowLanUpgrade = { !transferring.get() })
        val b = NativeLanTransport({ _, _ -> }, allowLanUpgrade = { !transferring.get() })
        try {
            a.start(aId, "A", 0); val bPort = b.start(bId, "B", 0)
            assertTrue(tunnel(a, b).all { it != null })
            val relay = requireNotNull(a.channel(bId))
            assertTrue(relay.peer.host.startsWith("relay:"))
            assertNull(a.connect("127.0.0.1", bPort, bId))
            assertTrue(relay.current())
            transferring.set(false)
            assertNotNull(a.connect("127.0.0.1", bPort, bId))
            withTimeout(3000) {
                a.peers.first { it.size == 1 && !it.single().host.startsWith("relay:") }
                b.peers.first { it.size == 1 && !it.single().host.startsWith("relay:") }
            }
            assertFalse(relay.current())
            val lan = requireNotNull(a.channel(bId))
            assertTrue(tunnel(a, b).all { it == null })
            assertTrue(lan.current())
            assertEquals(lan.peer.connectionId, a.channel(bId)?.peer?.connectionId)
        } finally { a.stop(); b.stop() }
    }
}
