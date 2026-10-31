package com.clipyclone.nativeandroid.relay

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.junweiup.commonrelay.Crypto
import io.github.junweiup.commonrelay.RelayGroups
import com.clipyclone.nativeandroid.sync.NativeLanTransport
import com.clipyclone.nativeandroid.sync.SyncCrypto
import com.clipyclone.nativeandroid.sync.SyncEnvelope
import com.clipyclone.nativeandroid.sync.SyncType
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Requires a temporary local common-relay server and adb reverse; never reads app credentials. */
@RunWith(AndroidJUnit4::class)
class RelayLiveInteropTest {
    @Test fun realServerGroupFlowsAndClipyV3ThroughEncryptedSdkStreams() = runBlocking<Unit> {
        val url = InstrumentationRegistry.getArguments().getString("relayTestUrl")
        assumeTrue("Pass relayTestUrl for the isolated SDK server", !url.isNullOrBlank())
        val address = requireNotNull(url)
        require(address.startsWith("ws://127.0.0.1:"))
        val proofRun = UUID.randomUUID().toString().take(8)
        android.util.Log.i("ClipyRelayInterop", "START local fixture run=$proofRun")
        fun device(label: String): RelayGroups {
            val secret = Crypto.hex(Crypto.random(32))
            val id = "$label-${UUID.randomUUID().toString().take(8)}"
            val public = Crypto("clipy", "", id, secret, emptyMap()).publicKey()
            return RelayGroups(JSONObject().put("url", address).put("app", "clipy").put("device", id)
                .put("secret_key", secret).put("public_key", public).put("trusted_peers", JSONObject()), true)
        }
        val owner = device("owner"); val manual = device("manual"); val automatic = device("auto")
        try {
            withContext(Dispatchers.IO) {
                owner.prepareCreate("Native migration fixture", "Owner"); owner.create()
                val invitation = owner.invite("manual", true)
                val decoded = manual.resolveInvitation(invitation.getString("short_link"))
                manual.config.put("group", decoded.getString("group"))
                manual.join(decoded, "Manual guest")
                assertFalse(manual.finishJoin())
                val request = owner.pending(invitation)
                assertNotNull(request)
                owner.approve(invitation, request, false)
                assertTrue(manual.finishJoin())
                owner.refresh()
                assertEquals(2, RelayGroups.unpack(owner.config.getJSONObject("group_entry")).getJSONArray("members").length())
                manual.rename(manual.config.getString("device"), "Renamed guest")
                owner.refresh()
                val afterRename = RelayGroups.unpack(owner.config.getJSONObject("group_entry")).getJSONArray("members")
                assertTrue((0 until afterRename.length()).any { afterRename.getJSONObject(it).getString("name") == "Renamed guest" })
                owner.remove(manual.config.getString("device"))
                assertThrows(Exception::class.java) { manual.refresh() }
                val autoInvitation = owner.invite("auto", true)
                val autoDecoded = automatic.resolveInvitation(autoInvitation.getString("short_link"))
                automatic.config.put("group", autoDecoded.getString("group"))
                automatic.join(autoDecoded, "Automatic guest")
                assertTrue(automatic.finishJoin())
                owner.refresh()
            }
            exchangeThroughNativeRelay(owner.config, automatic.config)
            withContext(Dispatchers.IO) {
                automatic.prepareExit(false); automatic.exit()
                val remaining = owner.refresh().getJSONObject("state").getJSONArray("members")
                assertEquals(1, remaining.length())
                owner.prepareExit(true); owner.exit()
            }
            android.util.Log.i("ClipyRelayInterop", "PASS manual+auto groups and 1MiB v3 SDK stream/ACK run=$proofRun")
        } finally {
            withContext(NonCancellable + Dispatchers.IO) { runCatching { owner.prepareExit(true); owner.exit() } }
        }
    }

    private suspend fun exchangeThroughNativeRelay(first: JSONObject, second: JSONObject) = coroutineScope {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "relay-live-${UUID.randomUUID()}").apply { mkdirs() }
        val firstId = "00000000-0000-0000-0000-000000000001"
        val secondId = "00000000-0000-0000-0000-000000000002"
        val received = CompletableDeferred<String>()
        val acknowledged = CompletableDeferred<Unit>()
        val crypto = SyncCrypto()
        lateinit var secondLan: NativeLanTransport
        val firstLan = NativeLanTransport(onFrame = { _, frame -> if (frame.type == SyncType.ACK && frame.hash == "relay-fixture") acknowledged.complete(Unit) })
        secondLan = NativeLanTransport(onFrame = { peer, frame ->
            if (frame.type == SyncType.HISTORY_DIRECT) {
                received.complete(crypto.decryptText(requireNotNull(frame.payload)) ?: "invalid ciphertext")
                secondLan.send(peer.peerId, SyncEnvelope(SyncType.ACK, secondId, hash = frame.hash))
            }
        })
        var firstRelay: NativeRelayTransport? = null; var secondRelay: NativeRelayTransport? = null
        try {
            firstLan.start(firstId, "Sender", 0); secondLan.start(secondId, "Receiver", 0)
            firstRelay = NativeRelayTransport(scope, File(directory, "first"), { JSONObject(first.toString()) },
                { RelayLocalIdentity(firstId, "Sender", firstLan.localPort, emptyList()) },
                { id -> firstLan.peers.value.any { it.peerId == id } }, { _, _, _ -> fail("No LAN addresses in this fixture") },
                { id, host, socket, inbound -> firstLan.adoptRelaySocket(socket, id, host, inbound) != null }, {}, allowLocalTest = true)
            secondRelay = NativeRelayTransport(scope, File(directory, "second"), { JSONObject(second.toString()) },
                { RelayLocalIdentity(secondId, "Receiver", secondLan.localPort, emptyList()) },
                { id -> secondLan.peers.value.any { it.peerId == id } }, { _, _, _ -> fail("No LAN addresses in this fixture") },
                { id, host, socket, inbound -> secondLan.adoptRelaySocket(socket, id, host, inbound) != null }, {}, allowLocalTest = true)
            firstRelay.start(); secondRelay.start()
            withTimeout(20000) {
                firstLan.peers.first { peers -> peers.any { it.peerId == secondId && it.host.startsWith("relay:") } }
                secondLan.peers.first { peers -> peers.any { it.peerId == firstId && it.host.startsWith("relay:") } }
            }
            val text = "Native relay fixture 世界 " + "x".repeat(1024 * 1024)
            assertTrue(firstLan.send(secondId, SyncEnvelope(SyncType.HISTORY_DIRECT, firstId, hash = "relay-fixture", payload = crypto.encryptText(text))))
            val result = withTimeout(20000) { received.await() }
            assertEquals(text.length, result.length)
            fun digest(value: String) = Crypto.hex(java.security.MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)))
            assertEquals(digest(text), digest(result))
            withTimeout(5000) { acknowledged.await() }
        } finally {
            firstRelay?.stop(); secondRelay?.stop(); firstLan.stop(); secondLan.stop()
            scope.cancel(); withContext(NonCancellable) { scope.coroutineContext[Job]?.join() }
            directory.deleteRecursively()
        }
    }
}
