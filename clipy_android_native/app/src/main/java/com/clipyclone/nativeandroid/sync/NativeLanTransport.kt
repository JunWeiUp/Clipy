package com.clipyclone.nativeandroid.sync

import android.os.SystemClock
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/** A confirmed LAN peer. Authorization is intentionally owned by the sending service. */
data class LanPeer(val peerId: String, val name: String, val host: String, val port: Int,
                   val inbound: Boolean, val isClient: Boolean, val connectionId: String = java.util.UUID.randomUUID().toString())

data class SyncChannel(val peer: LanPeer, val current: () -> Boolean, val write: suspend (SyncEnvelope) -> Boolean)

/**
 * Owns one server, bounded sockets, one read coroutine per session, and one 30s heartbeat.
 * start/stop serialize; stop closes sockets BEFORE cancelling IO jobs, unblocking every read.
 * A read holds at most one <=2MiB frame; writes serialize per socket. No UI owns this object.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeLanTransport(
    private val onFrame: suspend (LanPeer, SyncEnvelope) -> Unit,
    private val onConnected: suspend (LanPeer) -> Unit = {},
    private val onDisconnected: suspend (LanPeer) -> Unit = {},
    private val onError: (String, String?) -> Unit = { _, _ -> },
    private val onReplaced: suspend (LanPeer) -> Unit = {},
    private val allowLanUpgrade: () -> Boolean = { true },
) {
    private class Session(val peer: LanPeer, val socket: Socket) {
        val writer = Mutex()
        @Volatile var lastPong = SystemClock.elapsedRealtime()
        @Volatile var pongRevision = 0L
    }
    private class Run(val id: String, val name: String, val server: ServerSocket, onFailure: (Throwable) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, error -> onFailure(error) })
        val io = Dispatchers.IO.limitedParallelism(132)
        val sockets = ConcurrentHashMap.newKeySet<Socket>()
        val sessions = mutableMapOf<String, Session>()
        var acceptJob: Job? = null
    }
    private val lifecycle = Mutex()
    private val lock = Any()
    @Volatile private var run: Run? = null
    private val mutablePeers = MutableStateFlow<List<LanPeer>>(emptyList())
    private val mutableListening = MutableStateFlow(false)
    val peers = mutablePeers.asStateFlow()
    val listening = mutableListening.asStateFlow()
    val localPort: Int get() = run?.server?.localPort ?: 0

    suspend fun start(peerId: String, name: String, port: Int): Int = lifecycle.withLock {
        require(peerId.isNotEmpty() && port in 0..65535)
        stopRun()
        val server = ServerSocket()
        try {
            withContext(Dispatchers.IO) { server.reuseAddress = true; server.bind(InetSocketAddress("0.0.0.0", port)) }
        } catch (e: Exception) { server.close(); throw e }
        val current = Run(peerId, name, server) { if (run?.server === server) onError("transportTaskFailed", null) }
        synchronized(lock) { run = current; mutableListening.value = true }
        current.acceptJob = current.scope.launch(current.io) { acceptLoop(current) }
        current.scope.launch { heartbeat(current) }
        server.localPort
    }
    suspend fun stop() = lifecycle.withLock { stopRun() }
    private suspend fun stopRun() {
        val old = synchronized(lock) {
            val previous = run; run = null; mutablePeers.value = emptyList(); mutableListening.value = false
            previous?.sessions?.clear(); previous
        } ?: return
        runCatching { old.server.close() }
        old.sockets.forEach { runCatching { it.close() } }
        old.sockets.clear()
        old.scope.cancel()
        // An accept may have returned just before stop but not yet registered its socket.
        // Wait for that single owner to close any such accepted socket before rebinding.
        withContext(NonCancellable) { old.acceptJob?.join() }
    }
    private fun current(value: Run) = run === value && value.scope.isActive

    private suspend fun acceptLoop(value: Run) {
        try {
            while (current(value)) {
                val socket = value.server.accept().apply { reuseAddress = true }
                if (!track(value, socket)) { socket.close(); continue }
                value.scope.launch(value.io) { handshake(value, socket, inbound = true, expectedId = null) }
            }
        } catch (e: Exception) {
            if (current(value)) { mutableListening.value = false; onError("listenerClosed", null) }
        }
    }
    private fun track(value: Run, socket: Socket): Boolean = synchronized(lock) {
        if (!current(value) || value.sockets.size >= 128) false else value.sockets.add(socket)
    }

    suspend fun connect(host: String, port: Int, expectedId: String? = null, timeoutMs: Int = 3000): LanPeer? {
        require(port in 1..65535 && timeoutMs > 0)
        val value = run ?: return null
        val socket = Socket().apply { reuseAddress = true }
        if (!track(value, socket)) { socket.close(); return null }
        val task = value.scope.async(value.io) {
            try {
                socket.connect(InetSocketAddress(host, port), timeoutMs)
                ensureActive()
                handshake(value, socket, inbound = false, expectedId = expectedId)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { discard(value, socket); onError("connectFailed", expectedId); null }
        }
        return try { task.await() }
        catch (cancelled: CancellationException) { discard(value, socket); task.cancel(); throw cancelled }
    }

    /** Relay SDK bridges provide a connected local socket carrying the unchanged v3 byte stream. */
    suspend fun adoptRelaySocket(socket: Socket, expectedPeerId: String, host: String, inbound: Boolean): LanPeer? {
        require(host.startsWith("relay:") && expectedPeerId.isNotEmpty())
        val value = run ?: run { socket.close(); return null }
        if (!track(value, socket)) { socket.close(); return null }
        val task = value.scope.async(value.io) { handshake(value, socket, inbound, expectedPeerId, host) }
        return try { task.await() }
        catch (cancelled: CancellationException) { discard(value, socket); task.cancel(); throw cancelled }
    }

    private suspend fun handshake(value: Run, socket: Socket, inbound: Boolean, expectedId: String?, hostOverride: String? = null): LanPeer? {
        val adopted = java.util.concurrent.atomic.AtomicBoolean(false)
        // Socket read timeouts reset after each byte; this enforces the whole handshake deadline.
        val deadline = value.scope.launch { delay(2000); if (!adopted.get()) discard(value, socket) }
        try {
            if (!current(value)) return null
            socket.reuseAddress = true
            socket.tcpNoDelay = true
            socket.soTimeout = 2000
            socket.sendBufferSize = 4 * 1024 * 1024
            socket.receiveBufferSize = 4 * 1024 * 1024
            val hello = SyncEnvelope(SyncType.HELLO, value.id, name = value.name, port = value.server.localPort, sessionPolicy = SESSION_POLICY)
            socket.getOutputStream().write(SyncProtocol.encode(hello))
            val body = SyncProtocol.readBody(socket.getInputStream(), MAX_HANDSHAKE_BYTES) ?: return null
            val envelope = SyncProtocol.decode(body) ?: return null
            if (envelope.v != SYNC_VERSION) { onError("versionMismatch", expectedId); return null }
            if (envelope.type != SyncType.HELLO && envelope.type != SyncType.WELCOME) return null
            if (envelope.peerId.isEmpty() || envelope.peerId == value.id || (expectedId != null && envelope.peerId != expectedId)) return null
            if (envelope.type == SyncType.HELLO) socket.getOutputStream().write(SyncProtocol.encode(
                SyncEnvelope(SyncType.WELCOME, value.id, name = value.name, port = value.server.localPort, sessionPolicy = SESSION_POLICY)))
            val peer = LanPeer(envelope.peerId, envelope.name ?: envelope.peerId,
                hostOverride ?: socket.inetAddress.hostAddress ?: "", envelope.port ?: value.server.localPort, inbound, value.id < envelope.peerId)
            val session = Session(peer, socket)
            socket.soTimeout = 0
            var replaced: Session? = null
            val accepted = synchronized(lock) {
                if (!current(value) || socket.isClosed) false else {
                    val old = value.sessions[peer.peerId]
                    val incomingRelay = peer.host.startsWith("relay:")
                    val previousRelay = old?.peer?.host?.startsWith("relay:") == true
                    if (old != null && incomingRelay && !previousRelay) false
                    else if (old != null && !incomingRelay && previousRelay && !allowLanUpgrade()) false
                    else if (old != null && incomingRelay == previousRelay && !SyncProtocol.shouldReplace(envelope.sessionPolicy, value.id, peer.peerId, old.peer.inbound, inbound)) false
                    else {
                        // Replace atomically so crossed handshakes cannot see a vacant slot.
                        value.sessions[peer.peerId] = session
                        old?.let { replaced = it; discard(value, it.socket) }
                        mutablePeers.value = value.sessions.values.map { it.peer }
                        true
                    }
                }
            }
            if (!accepted) return null
            adopted.set(true)
            deadline.cancel()
            replaced?.let { old -> value.scope.launch { onReplaced(old.peer) } }
            value.scope.launch(value.io) { readLoop(value, session) }
            value.scope.launch {
                if (isSessionCurrent(value, session)) try { onConnected(peer) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { onError("connectedHandlerFailed", peer.peerId) }
            }
            return peer
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { if (current(value)) onError("handshakeFailed", expectedId); return null }
        finally { deadline.cancel(); if (!adopted.get()) discard(value, socket) }
    }
    private fun isSessionCurrent(value: Run, session: Session): Boolean = synchronized(lock) {
        current(value) && value.sessions[session.peer.peerId] === session
    }
    private suspend fun readLoop(value: Run, session: Session) {
        try {
            val input = session.socket.getInputStream()
            while (isSessionCurrent(value, session)) {
                val body = SyncProtocol.readBody(input) ?: break
                val env = SyncProtocol.decode(body) ?: continue
                if (env.v != SYNC_VERSION) { onError("badEnvelope", session.peer.peerId); continue }
                if (!isSessionCurrent(value, session)) break
                when (env.type) {
                    SyncType.PING -> sendSession(value, session, SyncProtocol.encode(SyncEnvelope(SyncType.PONG, value.id)))
                    SyncType.PONG -> { session.lastPong = SystemClock.elapsedRealtime(); session.pongRevision++ }
                    SyncType.HELLO, SyncType.WELCOME -> Unit
                    else -> onFrame(session.peer, env)
                }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { if (current(value)) onError("sessionReadFailed", session.peer.peerId) }
        finally { closeSession(value, session) }
    }

    fun channel(peerId: String): SyncChannel? {
        val value = run ?: return null
        val session = synchronized(lock) { value.sessions[peerId] } ?: return null
        return SyncChannel(session.peer, { isSessionCurrent(value, session) },
            { envelope -> sendSession(value, session, SyncProtocol.encode(envelope)) })
    }

    suspend fun send(peerId: String, envelope: SyncEnvelope): Boolean = sendEncoded(peerId, SyncProtocol.encode(envelope))
    suspend fun sendEncoded(peerId: String, frame: ByteArray): Boolean {
        require(frame.size in 5..MAX_FRAME_BYTES + 4)
        val value = run ?: return false
        val session = synchronized(lock) { value.sessions[peerId] } ?: return false
        return sendSession(value, session, frame)
    }
    private suspend fun sendSession(value: Run, session: Session, frame: ByteArray): Boolean = withContext(value.io) {
        try {
            session.writer.withLock {
                if (!isSessionCurrent(value, session)) return@withLock false
                session.socket.getOutputStream().write(frame)
                true
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { closeSession(value, session); false }
    }
    private fun discard(value: Run, socket: Socket) {
        runCatching { socket.close() }
        value.sockets.remove(socket)
    }
    private fun closeSession(value: Run, session: Session) {
        val removed = synchronized(lock) {
            if (!isSessionCurrent(value, session)) false else {
                value.sessions.remove(session.peer.peerId)
                mutablePeers.value = value.sessions.values.map { it.peer }
                true
            }
        }
        discard(value, session.socket)
        if (removed && current(value)) value.scope.launch { onDisconnected(session.peer) }
    }
    suspend fun probeConnections(graceMs: Long = 4000) {
        val value = run ?: return
        val sessions = synchronized(lock) { value.sessions.values.toList() }
        for (session in sessions) {
            val revision = session.pongRevision
            if (sendSession(value, session, SyncProtocol.encode(SyncEnvelope(SyncType.PING, value.id)))) {
                value.scope.launch {
                    delay(graceMs)
                    if (isSessionCurrent(value, session) && session.pongRevision == revision) closeSession(value, session)
                }
            }
        }
    }

    private suspend fun heartbeat(value: Run) {
        while (current(value)) {
            delay(30000)
            val sessions = synchronized(lock) { value.sessions.values.toList() }
            for (session in sessions) {
                if (SystemClock.elapsedRealtime() - session.lastPong > 90000) closeSession(value, session)
                else value.scope.launch { sendSession(value, session, SyncProtocol.encode(SyncEnvelope(SyncType.PING, value.id))) }
            }
        }
    }
}
