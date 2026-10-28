package com.clipyclone.nativeandroid.sync

import android.content.Context
import android.os.SystemClock
import com.clipyclone.nativeandroid.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

 data class SyncPeer(val peerId: String, val name: String, val host: String, val port: Int, val discovered: Boolean)
data class SyncState(
    val initialized: Boolean = false,
    val settings: SyncSettings = SyncSettings("", "Android", 5566, false, emptySet(), emptySet()),
    val peers: List<SyncPeer> = emptyList(), val localAddresses: List<String> = emptyList(),
    val listening: Boolean = false, val hasLanSession: Boolean = false, val hasRelaySession: Boolean = false,
    val connectedPeerIds: Set<String> = emptySet(),
    val discovery: DiscoveryProgress = DiscoveryProgress(), val pending: Map<String, Int> = emptyMap(),
    val manualPeers: List<String> = emptyList(), val error: String? = null,
)

/** Application-owned orchestration. UI never owns sockets, retry jobs, or persisted pending frames. */
class NativeSyncManager(
    private val context: Context,
    private val settingsStore: SyncSettingsStore = SyncSettingsStore(context),
    private val databaseFile: File = File(context.filesDir, "clipy.db"),
    private val addresses: () -> List<LocalIPv4> = NativeDiscovery::localAddresses,
    private val publishHistory: (HistoryWrite) -> Unit = {},
    private val handleOtherFrame: suspend (LanPeer, SyncEnvelope) -> Unit = { _, _ -> },
    private val onPeerDisconnected: suspend (LanPeer) -> Unit = {},
    private val onStopped: suspend () -> Unit = {},
    private val onStarted: suspend (SyncSettings) -> Unit = {},
    private val onPeerConnected: suspend (LanPeer) -> Unit = {},
    private val flushNotificationPending: suspend () -> Unit = {},
    private val refreshRelay: suspend () -> Unit = {},
    private val requestRelayPeer: suspend (String) -> Unit = {},
    private val hasActiveTransfers: () -> Boolean = { false },
    private val logger: suspend (String, String) -> Unit = { _, _ -> },
) {
    private class Run {
        var failure: (Throwable) -> Unit = {}
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, error -> failure(error) })
        lateinit var transport: NativeLanTransport
        lateinit var receiver: HistorySyncReceiver
        val receipts = TextDeliveryReceipts(scope)
        val discovery = DiscoveryRefreshCoordinator(scope)
        val scanLock = Mutex()
        val discovered = ConcurrentHashMap<String, PeerEndpoint>()
        val inFlight = ConcurrentHashMap<Pair<String, String>, Long>()
        val flushLocks = ConcurrentHashMap<String, Mutex>()
        val fetchRequested = ConcurrentHashMap<String, Long>()
        val fetchResponded = ConcurrentHashMap<String, Long>()
        val dialLock = Mutex()
        val dials = mutableMapOf<String, Deferred<LanPeer?>>()
        val reconnectLock = Any()
        val reconnects = mutableMapOf<String, Job>()
        val backoff = mutableMapOf<String, Long>()
        val failures = AtomicInteger()
        var lastAutoScan = 0L
    }
    private val lifecycle = Mutex()
    private val initialization = Mutex()
    private val databaseLock = Mutex()
    private val tickLock = Mutex()
    private val settingsRevision = java.util.concurrent.atomic.AtomicLong()
    private val mutable = MutableStateFlow(SyncState())
    val state = mutable.asStateFlow()
    val crypto = SyncCrypto()
    val diagnostics = NativeDiagnostics()
    @Volatile private var run: Run? = null
    private fun current(value: Run) = run === value && value.scope.isActive && mutable.value.settings.enabled

    private suspend fun <T> database(block: (ClipyDatabase) -> T): T = withContext(Dispatchers.IO) {
        databaseLock.withLock { ClipyDatabase(context, databaseFile).use(block) }
    }
    suspend fun initialize() = initialization.withLock {
        if (mutable.value.initialized) return@withLock
        val settings = withContext(Dispatchers.IO) {
            settingsStore.initialize { ClipyDatabase(context, databaseFile).use { PendingSyncRepository(it).clearAll() } }
        }
        // Data migration must complete before the UI observes initialized=true, including sticky-service startup.
        database { it.writableDatabase }
        mutable.update { it.copy(initialized = true, settings = settings) }
        refreshState()
    }
    suspend fun ensureStarted() {
        initialize()
        lifecycle.withLock {
            if (!mutable.value.settings.enabled || run?.transport?.listening?.value == true) return@withLock
            startInternal()
        }
    }
    suspend fun setEnabled(enabled: Boolean) {
        initialize()
        lifecycle.withLock {
            val previous = mutable.value.settings.enabled
            settingsRevision.incrementAndGet()
            withContext(Dispatchers.IO) { settingsStore.setEnabled(enabled) }
            mutable.update { it.copy(settings = it.settings.copy(enabled = enabled), error = null) }
            try {
                if (enabled && run?.transport?.listening?.value != true) startInternal()
                else if (!enabled) stopInternal()
            } catch (e: Exception) {
                withContext(NonCancellable + Dispatchers.IO) { settingsStore.setEnabled(previous) }
                mutable.update { it.copy(settings = it.settings.copy(enabled = previous), error = "bindFailed") }
                throw e
            }
        }
        refreshState()
    }
    suspend fun saveConnection(name: String, port: Int): Boolean {
        initialize()
        lifecycle.withLock {
            settingsRevision.incrementAndGet()
            val changed = withContext(Dispatchers.IO) { settingsStore.saveConnection(name, port) }
            mutable.update { it.copy(settings = it.settings.copy(name = name.trim(), port = port)) }
            if (changed && mutable.value.settings.enabled) {
                try { startInternal() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { mutable.update { it.copy(error = "bindFailed", listening = false) } }
            }
        }
        refreshState()
        return !mutable.value.settings.enabled || mutable.value.listening
    }
    /** Used by test/process owners; persisted enabled flag is retained for sticky restart. */
    suspend fun shutdown() = lifecycle.withLock { stopInternal() }

    private suspend fun startInternal() {
        stopInternal()
        val value = Run()
        value.failure = { if (current(value)) mutable.update { it.copy(error = "syncTaskFailed") } }
        value.transport = NativeLanTransport(
            onFrame = { peer, envelope -> if (current(value)) receive(value, peer, envelope) },
            onConnected = { peer -> if (current(value)) connected(value, peer) },
            onDisconnected = { peer -> if (current(value)) disconnected(value, peer) },
            onReplaced = { peer -> if (current(value)) onPeerDisconnected(peer) },
            allowLanUpgrade = { !hasActiveTransfers() },
            onError = { kind, peer ->
                if (current(value)) {
                    mutable.update { it.copy(error = kind) }
                    if (peer != null) diagnostics.noteError(peer, kind)
                    if (kind != "connectFailed" && kind != "handshakeFailed") value.scope.launch { logger("warning", "sync.$kind peer=${peer?.take(8) ?: "listener"}") }
                }
            },
        )
        value.receiver = HistorySyncReceiver(value.scope, crypto, SqliteHistorySyncStore(context, databaseFile,
            historyLimit = { (context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).all["flutter.historyLimit"] as? Number)?.toInt() ?: 1000 }),
            acknowledge = { peer, hash -> if (current(value)) value.transport.send(peer, envelope(SyncType.ACK, hash = hash)) },
            publish = { if (current(value)) publishHistory(it) },
            onError = { if (current(value)) mutable.update { it.copy(error = "historyPersistFailed") } })
        run = value
        try {
            val settings = mutable.value.settings
            value.transport.start(settings.peerId, settings.name, settings.port)
            mutable.update { it.copy(listening = true, error = null) }
            value.scope.launch { value.transport.listening.collect { bound -> if (current(value)) mutable.update { it.copy(listening = bound) } } }
            value.scope.launch { scan(value, full = false, explicit = false) }
            value.scope.launch { onStarted(settings) }
            logger("info", "Native sync listening on port ${settings.port}")
        } catch (e: Exception) {
            run = null; value.receiver.close(); value.receipts.cancelAll(); value.scope.cancel()
            withContext(NonCancellable) { value.transport.stop() }
            mutable.update { it.copy(listening = false) }
            throw e
        }
    }
    private suspend fun stopInternal() = withContext(NonCancellable) {
        val old = run
        run = null
        if (old != null) {
            old.discovery.reset(); old.receiver.close(); old.receipts.cancelAll()
            old.transport.stop(); old.scope.cancel()
            onStopped()
        }
        mutable.update { it.copy(listening = false, hasLanSession = false, hasRelaySession = false, connectedPeerIds = emptySet(), discovery = DiscoveryProgress(),
            peers = it.peers.filter { p -> p.peerId in it.settings.authorizedPeers }.map { p -> p.copy(discovered = false) }) }
    }
    private fun envelope(type: String, hash: String? = null, payload: String? = null): SyncEnvelope {
        val settings = mutable.value.settings
        return SyncEnvelope(type, settings.peerId, name = settings.name, hash = hash, payload = payload)
    }
    private suspend fun refreshState(expected: Run? = null) {
        val revision = settingsRevision.get()
        val snapshot = withContext(Dispatchers.IO) { Triple(settingsStore.read(), settingsStore.endpoints(), settingsStore.manualPeers()) }
        val local = withContext(Dispatchers.IO) { addresses().map { it.address }.distinct() }
        val counts = database { PendingSyncRepository(it).counts() }
        if (revision != settingsRevision.get() || (expected != null && !current(expected))) return
        val active = run
        val discovered = active?.discovered?.toMap() ?: emptyMap()
        val endpoints = snapshot.second.associateBy { it.peerId }
        val connections = active?.transport?.peers?.value ?: emptyList()
        val peers = (snapshot.first.authorizedPeers + discovered.keys).map { id ->
            val endpoint = discovered[id] ?: endpoints[id]
            SyncPeer(id, endpoint?.name ?: id.take(8), endpoint?.host ?: "", endpoint?.port ?: snapshot.first.port, id in discovered)
        }.sortedWith(compareByDescending<SyncPeer> { it.discovered }.thenBy { it.peerId })
        mutable.update { it.copy(settings = snapshot.first, peers = peers, localAddresses = local,
            hasLanSession = connections.any { p -> !p.host.startsWith("relay:") },
            hasRelaySession = connections.any { p -> p.host.startsWith("relay:") }, connectedPeerIds = connections.map { p -> p.peerId }.toSet(),
            pending = counts, manualPeers = snapshot.third) }
    }
    private suspend fun connected(value: Run, peer: LanPeer) {
        val endpoint = PeerEndpoint(peer.peerId, peer.name, peer.host, peer.port, System.currentTimeMillis() / 1000.0)
        value.discovered[peer.peerId] = endpoint
        diagnostics.noteSessionUp(peer.peerId, peer.name, peer.host)
        if (!peer.host.startsWith("relay:") && peer.port in 1..65535) withContext(Dispatchers.IO) { settingsStore.rememberEndpoint(endpoint) }
        synchronized(value.reconnectLock) { value.reconnects.remove(peer.peerId)?.cancel(); value.backoff[peer.peerId] = 1000 }
        value.failures.set(0)
        refreshState(value)
        if (!current(value)) return
        flushPending(value, peer.peerId)
        if (peer.peerId in mutable.value.settings.clipboardPeers) requestHistory(value, peer.peerId)
        if (current(value)) onPeerConnected(peer)
        logger("info", "Session up peer=${peer.peerId.take(8)} route=${if (peer.host.startsWith("relay:")) "relay" else "LAN"}")
    }
    private suspend fun disconnected(value: Run, peer: LanPeer) {
        onPeerDisconnected(peer)
        diagnostics.noteSessionDown(peer.peerId)
        logger("info", "Session down peer=${peer.peerId.take(8)}")
        value.inFlight.keys.removeAll { it.first == peer.peerId }
        value.receiver.flushPeer(peer.peerId)
        refreshState(value)
        if (peer.isClient) scheduleReconnect(value, peer.peerId)
    }
    private suspend fun receive(value: Run, peer: LanPeer, frame: SyncEnvelope) {
        diagnostics.noteReceived(peer.peerId)
        when (frame.type) {
            SyncType.HISTORY, SyncType.HISTORY_DIRECT -> value.receiver.receive(peer.peerId, frame)
            SyncType.ACK, SyncType.NOTIF_ACK -> frame.hash?.let { hash ->
                value.receipts.acknowledge(peer.peerId, hash)
                diagnostics.noteAck(peer.peerId)
                value.inFlight.remove(peer.peerId to hash)
                database { PendingSyncRepository(it).remove(peer.peerId, hash) }
                refreshState(value)
                if (frame.type == SyncType.NOTIF_ACK) handleOtherFrame(peer, frame)
            }
            SyncType.HISTORY_FETCH -> respondHistory(value, peer.peerId)
            else -> handleOtherFrame(peer, frame)
        }
    }
    suspend fun sendText(text: String, toPeerId: String): Boolean {
        val value = run ?: return false
        if (!current(value) || text.isEmpty()) return false
        val hash = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
        val frame = SyncProtocol.encode(envelope(SyncType.HISTORY_DIRECT, hash, crypto.encryptText(text)))
        return value.receipts.send(toPeerId, hash) {
            val accepted = database { PendingSyncRepository(it).enqueue(PendingFrame(toPeerId, hash, SyncType.HISTORY_DIRECT, frame, System.currentTimeMillis())) }
            check(accepted) { "Pending queue full" }
            if (current(value)) {
                ensurePeer(value, toPeerId, "direct")
                flushPending(value, toPeerId)
                refreshState(value)
            }
        }
    }
    suspend fun broadcastText(text: String, hash: String = ContentHash.text(text)) {
        val value = run ?: return
        if (!current(value)) return
        val frame = SyncProtocol.encode(envelope(SyncType.HISTORY, hash, crypto.encryptText(text)))
        for (peer in mutable.value.settings.clipboardPeers) {
            if (!current(value)) return
            val queued = database { PendingSyncRepository(it).enqueue(PendingFrame(peer, hash, SyncType.HISTORY, frame, System.currentTimeMillis())) }
            if (queued) value.scope.launch { ensurePeer(value, peer, "deliver"); flushPending(value, peer) }
        }
        refreshState(value)
    }
    suspend fun fileChannel(peer: String, timeoutMs: Long = 8000): SyncChannel? {
        val value = run ?: return null
        if (!current(value)) return null
        return withTimeoutOrNull(timeoutMs) {
            ensurePeer(value, peer, "direct")
            if (!current(value)) return@withTimeoutOrNull null
            value.transport.peers.first { peers -> !current(value) || peers.any { it.peerId == peer } }
            val captured = value.transport.channel(peer) ?: return@withTimeoutOrNull null
            SyncChannel(captured.peer, { current(value) && captured.current() },
                { frame -> if (current(value)) captured.write(frame) else false })
        }
    }

    fun hasSession(peer: String): Boolean = run?.transport?.peers?.value?.any { it.peerId == peer } == true
    suspend fun tryLan(peer: String, host: String, port: Int) {
        val value = run ?: return
        if (validIPv4(host) && port in 1..65535) dial(value, DiscoveryTarget(host, port, peer, "direct"))
    }
    suspend fun adoptRelaySocket(peer: String, host: String, socket: java.net.Socket, inbound: Boolean): Boolean {
        val value = run
        if (value == null || !current(value)) { socket.close(); return false }
        return value.transport.adoptRelaySocket(socket, peer, host, inbound) != null
    }
    suspend fun broadcastNotification(type: String, content: String, hash: String) {
        val value = run ?: return
        if (!current(value)) return
        val wire = when (type) {
            "notification/post" -> SyncType.NOTIF_POST
            "notification/dismiss" -> SyncType.NOTIF_DISMISS
            "notification/clear_all" -> SyncType.NOTIF_CLEAR
            "notification/ack" -> SyncType.NOTIF_ACK
            "notification/config" -> SyncType.NOTIF_CONFIG
            else -> type
        }
        // ACKs require an explicit recipient; use sendNotificationAck instead of fanout.
        if (wire == SyncType.NOTIF_ACK) return
        val env = envelope(wire, hash.ifEmpty { null }, if (content.isEmpty()) null else crypto.encryptText(content))
        val frame = SyncProtocol.encode(env)
        val targets = if (wire == SyncType.NOTIF_ACK) value.transport.peers.value.map { it.peerId }.toSet() else mutable.value.settings.notificationPeers
        for (peer in targets) {
            if (!current(value)) return
            if (wire == SyncType.NOTIF_POST && hash.isNotEmpty()) {
                val queued = database { PendingSyncRepository(it).enqueue(PendingFrame(peer, hash, wire, frame, System.currentTimeMillis())) }
                if (queued) value.scope.launch { ensurePeer(value, peer, "deliver"); flushPending(value, peer) }
            } else if (value.transport.sendEncoded(peer, frame)) diagnostics.noteSent(peer)
        }
        refreshState(value)
    }
    suspend fun sendNotificationAck(toPeerId: String, hash: String) {
        val value = run ?: return
        if (hash.isNotEmpty() && current(value) && value.transport.send(toPeerId, envelope(SyncType.NOTIF_ACK, hash))) diagnostics.noteSent(toPeerId)
    }

    suspend fun sendOnConnection(peer: LanPeer, envelope: SyncEnvelope): Boolean {
        val value = run ?: return false
        val target = value.transport.channel(peer.peerId) ?: return false
        return target.peer.connectionId == peer.connectionId && current(value) && target.write(envelope)
    }
    suspend fun sendEnvelope(peer: String, envelope: SyncEnvelope): Boolean = run?.transport?.send(peer, envelope) ?: false

    private suspend fun flushPending(value: Run, peer: String, retryStale: Boolean = false) {
        value.flushLocks.getOrPut(peer) { Mutex() }.withLock {
            if (!current(value) || value.transport.peers.value.none { it.peerId == peer }) return@withLock
            val hashes = database { PendingSyncRepository(it).dueHashes(peer) }
            val settings = mutable.value.settings
            for (hash in hashes) {
                if (!current(value)) return@withLock
                val frame = database { PendingSyncRepository(it).frame(peer, hash) } ?: continue
                val allowed = when (frame.type) {
                    SyncType.HISTORY -> peer in settings.clipboardPeers
                    SyncType.HISTORY_DIRECT -> true
                    SyncType.NOTIF_POST, SyncType.NOTIF_DISMISS, SyncType.NOTIF_CLEAR, SyncType.NOTIF_CONFIG -> peer in settings.notificationPeers
                    else -> true
                }
                if (!allowed) continue
                val key = peer to frame.hash
                if (retryStale && frame.enqueuedAt <= System.currentTimeMillis() - 45000) value.inFlight.remove(key)
                val mark = SystemClock.elapsedRealtime()
                if (value.inFlight.putIfAbsent(key, mark) != null) continue
                // Mark before write: a fast ACK must never be followed by a stale in-flight mark.
                if (!value.transport.sendEncoded(peer, frame.data)) {
                    value.inFlight.remove(key, mark); scheduleReconnect(value, peer); break
                }
                diagnostics.noteSent(peer)
            }
        }
    }
    private suspend fun requestHistory(value: Run, peer: String) {
        val now = SystemClock.elapsedRealtime()
        val last = value.fetchRequested[peer]
        if (last != null && now - last < 15 * 60 * 1000L) return
        value.fetchRequested[peer] = now
        value.receiver.beginCatchUp(peer)
        value.transport.send(peer, envelope(SyncType.HISTORY_FETCH))
    }
    private suspend fun respondHistory(value: Run, peer: String) {
        if (peer !in mutable.value.settings.clipboardPeers) return
        val now = SystemClock.elapsedRealtime()
        val last = value.fetchResponded[peer]
        if (last != null && now - last < 30000) return
        value.fetchResponded[peer] = now
        val texts = database { HistoryRepository(it).page(filter = HistoryFilter.TEXT, limit = 200) }
        for (entry in texts.asReversed()) {
            if (!current(value)) return
            val hash = entry.hash ?: continue
            value.transport.send(peer, envelope(SyncType.HISTORY, hash, crypto.encryptText(entry.value)))
        }
    }
    suspend fun updateCapabilities(peer: String, clipboard: Boolean, notifications: Boolean) {
        initialize()
        settingsRevision.incrementAndGet()
        withContext(Dispatchers.IO) { settingsStore.setCapabilities(peer, clipboard, notifications) }
        refreshState()
        run?.let { value -> value.scope.launch {
            scan(value, full = false, explicit = false); flushPending(value, peer)
            if (notifications && current(value)) flushNotificationPending()
        } }
    }
    suspend fun addManualPeer(host: String, port: Int) {
        initialize(); withContext(Dispatchers.IO) { settingsStore.addManualPeer(host, port) }; refreshState()
        run?.let { dial(it, DiscoveryTarget(host, port, null, "direct")) }
    }
    suspend fun removeManualPeer(endpoint: String) {
        withContext(Dispatchers.IO) { settingsStore.removeManualPeer(endpoint) }; refreshState()
    }
    suspend fun refreshDiscovery(automatic: Boolean = false) {
        ensureStarted()
        val value = run ?: return
        refreshRelay()
        value.discovery.refresh(automatic, { value.transport.peers.value.isNotEmpty() }) { full ->
            scan(value, full, explicit = true, prune = !automatic && full)
        }
    }
    private suspend fun scan(value: Run, full: Boolean, explicit: Boolean, prune: Boolean = false) = value.scanLock.withLock {
        if (!current(value)) return@withLock
        val data = withContext(Dispatchers.IO) { Triple(settingsStore.endpoints(), settingsStore.manualPeers(), addresses()) }
        if (!current(value)) return@withLock
        if (prune) {
            val live = value.transport.peers.value.map { it.peerId }.toSet()
            value.discovered.keys.removeAll { it !in live }
        }
        val targets = NativeDiscovery.plan(mutable.value.settings, data.first, data.second, data.third, value.transport.peers.value, full, explicit)
        var lastProgress = 0L
        val progressLock = Any()
        try {
            NativeDiscovery.scan(targets, current = { current(value) }, progress = { done, total ->
                synchronized(progressLock) {
                    val now = SystemClock.elapsedRealtime()
                    if (current(value) && (done == 0 || done == total || now - lastProgress >= 100)) {
                        lastProgress = now
                        mutable.update { it.copy(discovery = DiscoveryProgress(true, done, total)) }
                    }
                }
            }, probe = { dial(value, it, if (full) 800 else 3000) })
            if (prune && current(value)) withContext(Dispatchers.IO) {
                settingsStore.pruneEndpoints(value.transport.peers.value.filter { it.port in 1..65535 }.map {
                    PeerEndpoint(it.peerId, it.name, it.host, it.port, System.currentTimeMillis() / 1000.0)
                })
            }
        } finally {
            if (current(value)) { mutable.update { it.copy(discovery = it.discovery.copy(running = false)) }; refreshState(value) }
        }
    }
    private suspend fun dial(value: Run, target: DiscoveryTarget, timeout: Int = 3000): LanPeer? {
        if (!current(value)) return null
        if (target.reason !in setOf("scan", "direct") && target.peerId !in mutable.value.settings.authorizedPeers) return null
        value.transport.peers.value.firstOrNull { it.host == target.host }?.let { return it }
        val key = "${target.host}:${target.port}"
        val task = value.dialLock.withLock {
            value.dials[key] ?: value.scope.async(start = CoroutineStart.LAZY) {
                try { if (current(value)) value.transport.connect(target.host, target.port, target.peerId, timeout) else null }
                finally { value.dialLock.withLock { value.dials.remove(key) } }
            }.also { value.dials[key] = it }
        }
        task.start()
        val result = task.await()
        if (result == null && target.reason !in setOf("scan", "direct") && target.peerId in mutable.value.settings.authorizedPeers) {
            if (value.failures.incrementAndGet() >= 2) {
                synchronized(value.reconnectLock) {
                    val now = SystemClock.elapsedRealtime()
                    if (now - value.lastAutoScan >= 600000 || value.lastAutoScan == 0L) {
                        value.lastAutoScan = now
                        value.scope.launch { scan(value, full = true, explicit = false) }
                    }
                }
            }
        }
        return result
    }
    private suspend fun ensurePeer(value: Run, peer: String, reason: String) {
        if (!current(value) || value.transport.peers.value.any { it.peerId == peer }) return
        if (reason !in setOf("scan", "direct") && peer !in mutable.value.settings.authorizedPeers) return
        val cached = withContext(Dispatchers.IO) { settingsStore.endpoints().firstOrNull { it.peerId == peer } }
        val endpoint = value.discovered[peer]?.takeIf { !it.host.startsWith("relay:") } ?: cached
        if (endpoint != null) dial(value, DiscoveryTarget(endpoint.host, endpoint.port, peer, reason))
        if (current(value) && !hasSession(peer)) requestRelayPeer(peer)
    }
    private fun scheduleReconnect(value: Run, peer: String) = synchronized(value.reconnectLock) {
        if (!current(value) || value.reconnects.containsKey(peer)) return@synchronized
        val wait = value.backoff[peer] ?: 1000
        value.backoff[peer] = (wait * 2).coerceAtMost(30000)
        lateinit var job: Job
        job = value.scope.launch(start = CoroutineStart.LAZY) {
            try {
                delay(wait)
                val direct = database { PendingSyncRepository(it).hasType(peer, SyncType.HISTORY_DIRECT) }
                ensurePeer(value, peer, if (direct) "direct" else "reconnect")
            } finally { synchronized(value.reconnectLock) { if (value.reconnects[peer] === job) value.reconnects.remove(peer) } }
        }
        value.reconnects[peer] = job; job.start()
    }
    /** Called only by the existing adaptive foreground-service tick (30s busy / 90s idle). */
    suspend fun tick(): Long {
        if (!tickLock.tryLock()) return 30000
        try { return tickOnce() } finally { tickLock.unlock() }
    }
    private suspend fun tickOnce(): Long {
        ensureStarted()
        val value = run ?: return 90000
        val peers = mutable.value.settings.authorizedPeers + database { PendingSyncRepository(it).counts().keys }
        coroutineScope {
            val slots = kotlinx.coroutines.sync.Semaphore(12)
            peers.map { peer -> launch {
                slots.acquire()
                try {
                    if (current(value)) {
                        val direct = database { PendingSyncRepository(it).hasType(peer, SyncType.HISTORY_DIRECT) }
                        ensurePeer(value, peer, if (direct) "direct" else "syncTick")
                        flushPending(value, peer, retryStale = true)
                    }
                } finally { slots.release() }
            } }.joinAll()
        }
        database { PendingSyncRepository(it).cleanOld() }
        if (current(value)) flushNotificationPending()
        refreshState(value)
        val connected = value.transport.peers.value.map { it.peerId }.toSet()
        return if (mutable.value.pending.isNotEmpty() || mutable.value.settings.authorizedPeers.any { it !in connected }) 30000 else 90000
    }
    suspend fun networkChanged() {
        ensureStarted()
        val value = run ?: return
        value.transport.probeConnections()
        scan(value, full = false, explicit = false)
    }
}
