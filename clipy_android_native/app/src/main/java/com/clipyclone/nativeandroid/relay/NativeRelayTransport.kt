package com.clipyclone.nativeandroid.relay

import android.util.Base64
import com.clipyclone.nativeandroid.relay.sdk.Crypto
import com.clipyclone.nativeandroid.relay.sdk.RelayClient
import com.clipyclone.nativeandroid.relay.sdk.RelayGroups
import com.clipyclone.nativeandroid.relay.sdk.RelayJournal
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.selects.select
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun <T> CompletableFuture<T>.awaitRelay(): T = suspendCancellableCoroutine { continuation ->
    whenComplete { value, error ->
        if (continuation.isActive) {
            if (error == null) continuation.resume(value)
            else continuation.resumeWithException(error.cause ?: error)
        }
    }
    continuation.invokeOnCancellation { cancel(true) }
}

enum class RelayControl { DISABLED, CONNECTING, READY, RETRYING }
data class RelayLocalIdentity(val peerId: String, val name: String, val port: Int, val addresses: List<String>)

/** Online-only relay presence and encrypted stream transport, matching SyncRelayClient. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class NativeRelayTransport(
    ownerScope: CoroutineScope,
    private val journalDirectory: File,
    private val config: suspend () -> JSONObject?,
    private val local: () -> RelayLocalIdentity,
    private val hasSession: (String) -> Boolean,
    private val tryLan: suspend (String, String, Int) -> Unit,
    private val adopt: suspend (String, String, Socket, Boolean) -> Boolean,
    private val state: (RelayControl) -> Unit,
    private val allowLocalTest: Boolean = false,
) {
    private class Tunnel(val inbound: Boolean) {
        var stream: RelayClient.Stream? = null
        var local: Socket? = null
        var bridge: Socket? = null
        val closed = AtomicBoolean()
        fun close() {
            if (!closed.compareAndSet(false, true)) return
            runCatching { local?.close() }; runCatching { bridge?.close() }; runCatching { stream?.close() }
        }
    }
    private class Session(val epoch: Long, val settings: JSONObject) {
        lateinit var client: RelayClient
        val metadata = java.util.concurrent.ConcurrentHashMap<String, JSONObject>()
        val tunnels = java.util.concurrent.ConcurrentHashMap<String, Tunnel>()
        val refreshLock = kotlinx.coroutines.sync.Mutex()
        fun close() { if (::client.isInitialized) client.close(); tunnels.values.forEach { it.close() }; tunnels.clear() }
    }
    private val scope = CoroutineScope(SupervisorJob(ownerScope.coroutineContext[Job]) + Dispatchers.Default +
        CoroutineExceptionHandler { _, _ -> active?.close() })
    private val io = Dispatchers.IO.limitedParallelism(132)
    private val epoch = AtomicLong()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val lock = Any()
    private var loop: Job? = null
    @Volatile private var desired = false
    @Volatile private var active: Session? = null
    private val http = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(12, TimeUnit.SECONDS).writeTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false).followSslRedirects(false).build()
    private var journal: RelayJournal? = null
    private fun current(session: Session) = desired && epoch.get() == session.epoch && active === session

    fun start() {
        synchronized(lock) {
            desired = true
            if (loop?.isCompleted == false) return
            lateinit var job: Job
            job = scope.launch(start = CoroutineStart.LAZY) {
                try { runLoop() }
                finally {
                    synchronized(lock) { if (loop === job) loop = null }
                    if (desired && scope.isActive) start()
                }
            }
            loop = job; job.start()
        }
    }
    fun stop() {
        val previous = synchronized(lock) {
            desired = false; epoch.incrementAndGet()
            val value = active; active = null
            loop?.cancel(); state(RelayControl.DISABLED)
            value
        }
        previous?.close()
    }
    private fun publish(value: RelayControl, version: Long) = synchronized(lock) {
        if (desired && epoch.get() == version) state(value)
    }
    fun restart() {
        epoch.incrementAndGet(); active?.close()
        wake.trySend(Unit)
        if (desired) start()
    }
    suspend fun refresh() {
        val session = active
        if (session == null || !current(session)) { if (desired) { wake.trySend(Unit); start() }; return }
        refresh(session)
    }
    suspend fun ensurePeer(lanPeer: String) {
        val session = active
        if (session != null && current(session)) {
            session.metadata.entries.firstOrNull { RelayConfiguration.lanPeer(it.key, it.value) == lanPeer }?.let { entry ->
                announce(session, entry.key)
                if (local().peerId < lanPeer) scope.launch { open(session, entry.key, entry.value) }
            }
        }
        refresh()
    }
    private suspend fun runLoop() {
        var retry = 1L
        while (desired && currentCoroutineContext().isActive) {
            wake.tryReceive()
            val version = epoch.get()
            publish(RelayControl.CONNECTING, version)
            var session: Session? = null
            try {
                val settings = config()
                if (!desired || version != epoch.get()) continue
                if (settings == null) { publish(RelayControl.DISABLED, version); wake.receive(); continue }
                val connected = Session(version, settings)
                session = connected
                active = connected
                val trusted = settings.getJSONObject("trusted_peers")
                val crypto = Crypto("clipy", settings.getString("group"), settings.getString("device"), settings.getString("secret_key"),
                    trusted.keys().asSequence().associateWith { trusted.getString(it) })
                val ready = CompletableDeferred<Unit>()
                val closed = CompletableDeferred<Unit>()
                val events = Channel<JSONObject>(256)
                val persistedJournal = withContext(io) { journal ?: RelayJournal(journalDirectory).also { journal = it } }
                connected.client = RelayClient(http, crypto, object : RelayClient.Listener {
                    override fun onReady() { ready.complete(Unit) }
                    override fun onEvent(event: JSONObject) { if (!events.trySend(event).isSuccess) connected.close() }
                    override fun onClosed(error: Throwable?) {
                        if (!ready.isCompleted) ready.completeExceptionally(error ?: IllegalStateException("Relay closed"))
                        closed.complete(Unit); events.close()
                    }
                }, persistedJournal)
                val endpoint = settings.getString("url")
                require(RelayConfiguration.validUrl(endpoint) ||
                    RelayEndpointPolicy.forApp(allowLocalTest, "com.clipyclone.clipy_android.nativepreview").allowsCleartext(endpoint)) { "WSS required" }
                connected.client.connect(endpoint, settings.getString("token"), allowLocalTest)
                withTimeout(12000) { ready.await() }
                if (!current(connected)) continue
                retry = 1
                publish(RelayControl.READY, version)
                coroutineScope {
                    val refreshJob = launch { while (current(connected)) { runCatching { refresh(connected) }; delay(30000) } }
                    try { for (event in events) { if (!current(connected)) break; event(connected, event) } }
                    finally { refreshJob.cancel(); events.cancel() }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Never log credentials, public roster URLs with tokens, or private payloads. */ }
            finally { session?.close(); if (active === session) active = null }
            if (desired) {
                publish(RelayControl.RETRYING, version)
                if (version == epoch.get()) {
                    withTimeoutOrNull(retry * 1000) { wake.receive() }
                    retry = (retry * 2).coerceAtMost(30)
                } else retry = 1
            }
        }
    }
    private suspend fun announce(session: Session, peer: String) {
        if (!current(session) || !session.settings.getJSONObject("trusted_peers").has(peer)) return
        val info = local()
        val data = JSONObject().put("type", "clipy.presence").put("peerId", info.peerId).put("name", info.name)
            .put("port", info.port).put("addresses", JSONArray(info.addresses.take(8)))
        withContext(io) { if (current(session)) session.client.sendOnline(peer, data.toString().toByteArray(Charsets.UTF_8)) }
    }
    private suspend fun refresh(session: Session) {
        if (!current(session)) return
        session.metadata.forEach { (peer, info) ->
            val id = RelayConfiguration.lanPeer(peer, info)
            if (id != null && !hasSession(id) && local().peerId < id) scope.launch { open(session, peer, info) }
        }
        if (!session.refreshLock.tryLock()) return
        try {
            val result = withTimeout(3000) { session.client.peers().awaitRelay() }
            val peers = result.getJSONArray("peers")
            for (i in 0 until peers.length()) announce(session, peers.getJSONObject(i).getString("device"))
        } catch (cancelled: TimeoutCancellationException) { if (current(session)) restart() }
        finally { session.refreshLock.unlock() }
    }
    private suspend fun event(session: Session, event: JSONObject) {
        when (event.optString("type")) {
            "group.changed" -> {
                val group = session.settings.optJSONObject("group_entry")
                if (group != null && event.optInt("revision") > RelayGroups.unpack(group).getInt("revision")) restart()
            }
            "peer.up" -> scope.launch { runCatching { announce(session, event.getJSONObject("identity").getString("device")) } }
            "peer.down" -> {
                val peer = event.getJSONObject("identity").getString("device")
                session.metadata.remove(peer); session.tunnels.remove(peer)?.close()
            }
            "message" -> {
                if (event.optBoolean("offline")) return
                val peer = event.getString("from")
                val info = JSONObject(String(Base64.decode(event.getString("data"), Base64.DEFAULT), Charsets.UTF_8))
                val addresses = info.optJSONArray("addresses") ?: return
                val port = info.opt("port")
                if (info.optString("type") != "clipy.presence" || addresses.length() > 8 || port !is Number || port.toInt() !in 1..65535) return
                val lanPeer = RelayConfiguration.lanPeer(peer, info) ?: return
                if (lanPeer == local().peerId) return
                val first = session.metadata.put(peer, info) == null
                if (first) announce(session, peer)
                if (local().peerId < lanPeer) scope.launch { open(session, peer, info) }
            }
            "stream.open" -> {
                val peer = event.getString("from")
                val lanPeer = RelayConfiguration.lanPeer(peer, session.metadata[peer])
                if (lanPeer == null || hasSession(lanPeer) || local().peerId < lanPeer || session.tunnels.containsKey(peer)) {
                    session.client.rejectStream(event); return
                }
                val tunnel = Tunnel(true)
                if (session.tunnels.putIfAbsent(peer, tunnel) != null) { session.client.rejectStream(event); return }
                scope.launch {
                    try { tunnel.stream = session.client.acceptStream(event).awaitRelay(); bridge(session, peer, lanPeer, tunnel) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { }
                    finally { tunnel.close(); session.tunnels.remove(peer, tunnel) }
                }
            }
        }
    }
    private suspend fun open(session: Session, peer: String, info: JSONObject) {
        val id = RelayConfiguration.lanPeer(peer, info) ?: return
        if (!current(session) || hasSession(id)) return
        val tunnel = Tunnel(false)
        if (session.tunnels.putIfAbsent(peer, tunnel) != null) return
        try {
            val addresses = info.getJSONArray("addresses")
            for (index in 0 until minOf(2, addresses.length())) {
                val host = addresses.optString(index)
                val parts = host.split('.').map { it.toIntOrNull() }
                if (parts.size != 4 || parts.any { it == null || it !in 0..255 }) continue
                val a = parts[0]!!; val b = parts[1]!!
                if (a != 10 && !(a == 172 && b in 16..31) && !(a == 192 && b == 168)) continue
                tryLan(id, host, info.getInt("port"))
            }
            if (!current(session) || tunnel.closed.get() || hasSession(id)) return
            tunnel.stream = session.client.openStream(peer).awaitRelay()
            bridge(session, peer, id, tunnel)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { }
        finally { tunnel.close(); session.tunnels.remove(peer, tunnel) }
    }
    private suspend fun bridge(session: Session, relayId: String, lanId: String, tunnel: Tunnel) = withContext(io) {
        val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        try {
            tunnel.local = Socket("127.0.0.1", listener.localPort)
            tunnel.bridge = listener.accept()
        } finally { listener.close() }
        if (!current(session) || tunnel.closed.get() || hasSession(lanId)) return@withContext
        val stream = requireNotNull(tunnel.stream)
        val socket = requireNotNull(tunnel.bridge)
        coroutineScope {
            // Start pumping BEFORE awaiting the v3 handshake adopted by the main manager.
            val upload = async(io) {
                val buffer = ByteArray(65519)
                val input = socket.getInputStream()
                while (current(session) && !tunnel.closed.get()) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    stream.send(buffer.copyOf(count), false)
                }
            }
            val download = async(io) {
                val output = socket.getOutputStream()
                while (current(session) && !stream.receivedFinal()) { output.write(stream.receive()); output.flush() }
            }
            try {
                if (!adopt(lanId, "relay:$relayId", requireNotNull(tunnel.local), tunnel.inbound)) return@coroutineScope
                select<Unit> { upload.onAwait { }; download.onAwait { } }
            } finally { tunnel.close(); upload.cancel(); download.cancel() }
        }
    }
}
