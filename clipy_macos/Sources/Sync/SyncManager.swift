import Foundation
import AppKit
import Network
import CryptoKit

/// Public synchronization facade. Transport, discovery, crypto, and reliability
/// implementation details live in the sibling Sync*.swift extensions.
final class SyncManager: NSObject {
    static let shared = SyncManager()

    var onDevicesChanged: (([String]) -> Void)?
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?

    let syncQueue = DispatchQueue(label: "com.clipy.sync.v2")
    let scanQueue = DispatchQueue(label: "com.clipy.scan.v2", attributes: .concurrent)
    let dialDedupLock = NSLock()
    /// Allocated on first recv — a 64KB buffer used to live here even when
    /// sync was disabled entirely.
    var receiveScratch = Data()

    static let maxFrameLength = 2 * 1024 * 1024
    static let maxHandshakeFrameLength = 64 * 1024
    static let legacySharedSecret = "ClipySyncSecret2026"
    static let keyDerivationSalt = Data("clipy.sync.v2.hkdf".utf8)
    static let keyDerivationInfo = Data("aes-256-gcm".utf8)
    static let defaultPort: UInt16 = 5566
    static let discoveryDebounce: TimeInterval = 0.6
    static let handshakeTimeout: TimeInterval = 2.0
    static let connectTimeout: TimeInterval = 3.0
    static let scanConnectTimeout: TimeInterval = 0.35
    static let pingInterval: TimeInterval = 30
    static let pendingQueueMax = 500
    static let pendingQueueTTL: TimeInterval = 24 * 60 * 60
    static let pendingAckRetryAge: TimeInterval = 120
    static let endpointCacheKey = "clipy.peerEndpoints.v2"
    static let endpointCacheTTL: TimeInterval = 86400
    static let maxReconnectBackoff: TimeInterval = 30
    static let minReconnectInterval: TimeInterval = 2
    static let scanConcurrency = 48
    static let subnetScanCooldown: TimeInterval = 60
    /// Align with Android history.fetch *request* throttle (15 min).
    static let historyFetchThrottle: TimeInterval = 15 * 60

    var displayName: String { PreferencesManager.shared.deviceName }
    var peerId: String { PreferencesManager.shared.syncPeerId }
    var syncPort: UInt16 {
        UInt16(clamping: PreferencesManager.shared.syncPort == 0 ? Int(Self.defaultPort) : PreferencesManager.shared.syncPort)
    }

    let keyLock = NSLock()
    var cachedKeySecret: String?
    var cachedKey: SymmetricKey?

    var discoveredPeers: [String: DiscoveredPeer] = [:]
    let peersLock = NSLock()
    var pendingDiscoveryWork: DispatchWorkItem?
    var isRefreshingDiscovery = false
    let scanStateLock = NSLock()
    var isScanning = false
    var lastScanFinishedAt: Date?
    var serviceGeneration = 0
    var lastDialAt: [String: Date] = [:]
    let dialDedupTTL: TimeInterval = 4

    // Auto-rediscovers a peer whose cached endpoint died (e.g. its DHCP lease
    // moved): after this many consecutive authorized dial failures, fall back
    // to one full /24 scan — throttled so a dead address can't scan on every
    // discovery cycle. Guarded by selfHealLock: dials run on the concurrent
    // scanQueue while adoption runs on syncQueue.
    static let autoRediscoverFailThreshold = 2
    static let autoRediscoverCooldown: TimeInterval = 10 * 60
    let selfHealLock = NSLock()
    var authorizedDialFailStreak = 0
    var lastAutoRediscoverAt: Date?

    /// A full /24 scan writes a dedup entry per dial (~254). They are only
    /// meaningful for `dialDedupTTL` seconds, so drop the stale ones once the
    /// scan finishes instead of keeping the map growing forever.
    func pruneStaleDialTimestamps() {
        let now = Date()
        dialDedupLock.lock()
        lastDialAt = lastDialAt.filter { now.timeIntervalSince($0.value) < 30 }
        dialDedupLock.unlock()
    }

    struct Session {
        let peerId: String
        let host: String
        let port: UInt16
        var fd: Int32
        var readSource: DispatchSourceRead?
        var writer: SyncSocketWriter?
        var historyReplayRows: [Int64] = []
        var buffer = Data()
        var lastPong = Date()
        let isClient: Bool
    }
    var sessions: [String: Session] = [:]
    var reconnectBackoffs: [String: TimeInterval] = [:]
    var pendingReconnects: [String: DispatchWorkItem] = [:]
    var lastReconnectAttempt: [String: Date] = [:]

    var listenFD: Int32 = -1
    var listenSource: DispatchSourceRead?
    var listenerClosing = false
    var listenerStartRequested = false
    var listenerRequestedPort: UInt16?
    var acceptingClients: [Int32: (host: String, buffer: Data, source: DispatchSourceRead)] = [:]
    var inFlightHashes: [String: Set<String>] = [:]
    var lastHistoryFetchResponse: [String: Date] = [:]
    var pingTimer: DispatchSourceTimer?
    var pathMonitor: NWPathMonitor?
    var lastPathStatus: NWPath.Status = .requiresConnection

    // MARK: File transfer state (SyncFileTransfer.swift)
    // incomingFiles / fileAckWaiters are only touched on syncQueue.
    struct IncomingFileState {
        let peerId: String
        let senderName: String
        let fileId: String
        let fileName: String
        let fileSize: Int
        let chunkSize: Int
        let chunkCount: Int
        let sha256: String
        let partURL: URL
        /// Persistent append handle opened at file.meta; closed by
        /// completeChunkedFile / discardIncomingFile.
        var handle: FileHandle?
        var received: Set<Int> = []
        var idleWork: DispatchWorkItem?
    }
    var incomingFiles: [String: IncomingFileState] = [:]
    var fileAckWaiters: [String: (Bool) -> Void] = [:]
    let fileTransferQueue = DispatchQueue(label: "com.clipy.sync.filetransfer")

    // MARK: - Lifecycle

    func start() {
        appLog("SyncManager v2 starting...")
        guard PreferencesManager.shared.isSyncEnabled || NotificationManager.shared.notificationSyncEnabled else { return }
        syncQueue.async { [weak self] in
            guard let self else { return }
            PendingSyncRepository.shared.cleanOld(ttl: Self.pendingQueueTTL)
            self.startListening()
            self.startPingTimer()
            self.startPathMonitoring()
            if PreferencesManager.shared.isSyncEnabled {
                // Authorized cache dial only — full /24 scan is user refresh.
                self.loadEndpointCache()
                self.scheduleDiscovery(immediate: true, scanFullSubnet: false)
            }
        }
    }

    func stop() {
        appLog("SyncManager v2 stopping...")
        scanStateLock.lock(); serviceGeneration &+= 1; scanStateLock.unlock()
        syncQueue.async { [weak self] in
            guard let self else { return }
            self.stopPathMonitoring()
            self.pingTimer?.cancel(); self.pingTimer = nil
            self.pendingDiscoveryWork?.cancel(); self.pendingDiscoveryWork = nil
            self.pendingReconnects.values.forEach { $0.cancel() }
            self.pendingReconnects.removeAll(); self.reconnectBackoffs.removeAll()
            for id in Array(self.sessions.keys) { self.closeSession(peerId: id, scheduleReconnect: false) }
            for (fd, client) in self.acceptingClients { client.source.cancel(); Darwin.close(fd) }
            self.acceptingClients.removeAll()
            self.stopListening()
            self.peersLock.lock(); self.discoveredPeers.removeAll(); self.peersLock.unlock()
            self.notifyPeersChanged()
        }
    }

    func restartService() {
        stop()
        syncQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    /// - Parameters:
    ///   - pruneCache: drop unauthorized ghosts from disk (user refresh button).
    ///   - scanFullSubnet: dial entire /24 (only user refresh).
    func refreshDiscovery(pruneCache: Bool = true, scanFullSubnet: Bool = true) {
        guard PreferencesManager.shared.isSyncEnabled, !isRefreshingDiscovery else { return }
        isRefreshingDiscovery = true
        syncQueue.async { [weak self] in
            guard let self else { return }
            let liveSessions = self.sessions
            var cached: [String: CachedEndpoint] = [:]
            for entry in self.loadEndpointCacheEntries() {
                cached[entry.peerId] = entry
            }
            self.peersLock.lock()
            var kept: [String: DiscoveredPeer] = [:]
            for (id, session) in liveSessions {
                if let existing = self.discoveredPeers[id] { kept[id] = existing }
                else {
                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(session.host), port: NWEndpoint.Port(rawValue: session.port) ?? 5566)
                    kept[id] = DiscoveredPeer(peerId: id, displayName: cached[id]?.name ?? id, endpoint: endpoint, host: session.host, port: session.port)
                }
            }
            self.discoveredPeers = kept
            let keptList = Array(kept.values)
            self.peersLock.unlock()
            if pruneCache {
                self.rewriteEndpointCacheAfterRefresh(livePeers: keptList)
            }
            self.notifyPeersChanged()
            self.scheduleDiscovery(immediate: true, scanFullSubnet: scanFullSubnet)
            self.syncQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.isRefreshingDiscovery = false }
        }
    }

    func triggerCrossBandDiscovery() {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        scheduleDiscovery(immediate: false, scanFullSubnet: false)
    }

    /// Counts a failed proactive dial to an authorized peer (its cached
    /// address is dead — typically the peer moved to a new DHCP lease) and,
    /// once the streak trips the threshold and the cooldown has elapsed,
    /// falls back to a full /24 scan so the peer is re-found without a manual
    /// refresh.
    func noteAuthorizedDialFailure(peerId: String?) {
        guard let peerId, !peerId.isEmpty,
              Set(PreferencesManager.shared.authorizedPeerIds).contains(peerId) else { return }
        var shouldScan = false
        selfHealLock.lock()
        authorizedDialFailStreak += 1
        let streak = authorizedDialFailStreak
        if streak >= Self.autoRediscoverFailThreshold {
            let last = lastAutoRediscoverAt
            if last == nil || Date().timeIntervalSince(last!) >= Self.autoRediscoverCooldown {
                lastAutoRediscoverAt = Date()
                shouldScan = true
            }
        }
        selfHealLock.unlock()
        guard shouldScan else { return }
        appLog("Auto rediscover: \(streak) consecutive authorized dial failures — scanning /24 for missing peers")
        scheduleDiscovery(immediate: true, scanFullSubnet: true)
    }

    func noteSessionEstablished() {
        selfHealLock.lock()
        authorizedDialFailStreak = 0
        selfHealLock.unlock()
    }

    // MARK: - Public queries

    var availablePeers: [DiscoveredPeer] {
        peersLock.lock(); defer { peersLock.unlock() }
        return discoveredPeers.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    var availableDeviceNames: [String] { availablePeers.map(\.displayName) }
    var availableDeviceEntries: [DeviceEntry] {
        let peers = availablePeers
        let counts = peers.reduce(into: [String: Int]()) { $0[$1.displayName, default: 0] += 1 }
        return peers.map {
            DeviceEntry(
                displayName: (counts[$0.displayName] ?? 0) > 1 ? "\($0.displayName) (\($0.peerId.prefix(6)))" : $0.displayName,
                peerId: $0.peerId,
                originalName: $0.displayName
            )
        }
    }
    func enumerateLocalIPv4s() -> [String] { Self.localIPv4Addresses() }

    // MARK: - Broadcast APIs

    func broadcastSync(content: String, hash: String) {
        guard PreferencesManager.shared.isSyncEnabled else { appLog("broadcastSync skipped: sync disabled", level: .warning); return }
        guard let payload = encrypt(content) else { appLog("broadcastSync skipped: encryption failed", level: .warning); return }
        let env = SyncEnvelope.make(type: SyncType.history, peerId: peerId, name: displayName, hash: hash, payload: payload)
        appLog("broadcastSync: history hash \(hash.prefix(8)) to \(clipboardAuthIds()) auth peer(s)")
        fanoutReliable(env, requireAuth: true)
    }

    func broadcastNotificationMessage(type: String, content: String, hash: String) {
        let mapped = mapNotificationType(type)
        guard mapped != nil || type.hasPrefix("notif.") else { appLog("Unknown notification type: \(type)", level: .warning); return }
        guard let payload = encrypt(content) else { return }
        fanoutReliable(SyncEnvelope.make(type: mapped ?? type, peerId: peerId, name: displayName, hash: hash.isEmpty ? nil : hash, payload: payload), requireAuth: true, allowWithoutClipboardSync: true)
    }

    func sendNotificationAck(hash: String, to senderPeerId: String) {
        guard !hash.isEmpty, !senderPeerId.isEmpty else { return }
        sendEnvelope(SyncEnvelope.make(type: SyncType.notifAck, peerId: peerId, hash: hash), to: senderPeerId, reliable: false)
    }

    func sendTextToPeer(_ content: String, hash: String, peerId targetId: String, completion: ((Bool) -> Void)? = nil) {
        guard PreferencesManager.shared.isSyncEnabled, let payload = encrypt(content) else { completion?(false); return }
        // Device-list send: history.direct bypasses mutual authorization on both ends.
        sendEnvelope(
            SyncEnvelope.make(type: SyncType.historyDirect, peerId: peerId, name: displayName, hash: hash, payload: payload),
            to: targetId,
            reliable: true,
            dialReason: "direct",
            completion: completion
        )
    }

    func sendText(_ content: String, hash: String, toDevice targetName: String) {
        guard let peer = availablePeers.first(where: { $0.displayName == targetName }) else { return }
        sendTextToPeer(content, hash: hash, peerId: peer.peerId)
    }
    // File transfer lives in SyncFileTransfer.swift:
    // sendFileToPeer(at:peerId:completion:) / sendFile(at:toDevice:).

    func mapNotificationType(_ apiType: String) -> String? {
        switch apiType {
        case "notification/post": return SyncType.notifPost
        case "notification/dismiss": return SyncType.notifDismiss
        case "notification/clear_all": return SyncType.notifClear
        case "notification/ack": return SyncType.notifAck
        case "notification/config": return SyncType.notifConfig
        default: return nil
        }
    }

    // MARK: - Business dispatch

    func handleFrame(_ data: Data, from remotePeerId: String, host: String) {
        guard let env = decodeEnvelope(data), env.v == SyncEnvelope.version else { return }
        switch env.type {
        case SyncType.ping:
            let pong = SyncEnvelope.make(type: SyncType.pong, peerId: peerId)
            if let data = encodeFrame(pong), let fd = sessions[remotePeerId]?.fd, !sendSessionFrame(fd, data) { appLog("pong send failed to \(remotePeerId.prefix(8))", level: .warning) }
        case SyncType.pong:
            if var session = sessions[remotePeerId] { session.lastPong = Date(); sessions[remotePeerId] = session }
        case SyncType.ack, SyncType.notifAck:
            guard let hash = env.hash else { return }; handleAck(hash: hash, from: remotePeerId)
        case SyncType.history, SyncType.historyDirect:
            // Inbound accept is unilateral: sender's allow-list gates who they push to;
            // receiver does not require reciprocal authorization (same as notifications).
            guard let payload = env.payload, let text = decrypt(payload) else { return }
            DispatchQueue.main.async { [weak self] in
                ClipboardManager.shared.handleRemoteSync(content: text, hash: env.hash ?? "")
                self?.syncQueue.async { self?.replyAck(to: remotePeerId, hash: env.hash) }
            }
        case SyncType.historyFetch:
            // Responding = sending our history: only to clipboard-authorized peers.
            guard clipboardAuthIds().contains(remotePeerId) else {
                appLog("history.fetch from \(remotePeerId.prefix(8)) ignored (not a clipboard sync target)", level: .warning)
                return
            }
            respondToHistoryFetch(from: remotePeerId)
        case SyncType.notifPost:
            guard let payload = env.payload, let text = decrypt(payload) else { return }
            DispatchQueue.main.async { NotificationManager.shared.handleRemoteNotification(text, from: env.peerId) }
        case SyncType.notifDismiss:
            guard let payload = env.payload, let text = decrypt(payload) else { return }
            DispatchQueue.main.async { NotificationManager.shared.handleRemoteDismiss(text) }
        case SyncType.notifClear:
            DispatchQueue.main.async { NotificationManager.shared.handleRemoteClearAll() }
        case SyncType.notifConfig: appLog("Ignored remote notification config", level: .warning)
        case SyncType.fileMeta:
            handleFileMeta(env, from: remotePeerId)
        case SyncType.fileChunk:
            handleFileChunk(env, from: remotePeerId)
        case SyncType.fileAck:
            handleFileAck(env, from: remotePeerId)
        case SyncType.hello, SyncType.welcome:
            if let name = env.name, let port = env.port { recordPeer(peerId: env.peerId, name: name, host: host, port: UInt16(port)) }
        default: break
        }
    }

    func respondToHistoryFetch(from remotePeerId: String) {
        syncQueue.async { [weak self] in
            guard let self else { return }
            if let last = self.lastHistoryFetchResponse[remotePeerId],
               Date().timeIntervalSince(last) < Self.historyFetchThrottle {
                appLog("history.fetch from \(remotePeerId.prefix(8)) ignored (throttled)")
                return
            }
            self.lastHistoryFetchResponse[remotePeerId] = Date()
            self.sessions[remotePeerId]?.historyReplayRows = HistoryRepository.shared.recentTextRowids(limit: 200)
            self.pumpHistoryReplay(for: remotePeerId)
        }
    }

    /// Keep row ids only. Resolve/encode one replay frame when the FIFO drains,
    /// rather than retaining up to 200 full (possibly externalized) texts.
    func pumpHistoryReplay(for peerId: String) {
        guard var session = sessions[peerId], let writer = session.writer else { return }
        while !session.historyReplayRows.isEmpty {
            let rowid = session.historyReplayRows.removeFirst()
            sessions[peerId]?.historyReplayRows = session.historyReplayRows
            guard let entry = HistoryRepository.shared.fetchByRowid(rowid),
                  let text = entry.resolvedText, let payload = encrypt(text),
                  let frame = encodeFrame(SyncEnvelope.make(type: SyncType.history,
                      peerId: self.peerId, name: displayName, port: Int(syncPort),
                      hash: entry.contentHash ?? "", payload: payload)) else { continue }
            if !writer.enqueue(frame) {
                sessions[peerId]?.historyReplayRows.insert(rowid, at: 0)
            }
            return
        }
    }

    // MARK: - Keepalive / path

    func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.sendPings() }
        pingTimer = timer; timer.resume()
    }
    func sendPings() {
        guard let data = encodeFrame(SyncEnvelope.make(type: SyncType.ping, peerId: peerId)) else { return }
        let cutoff = Date().addingTimeInterval(-Self.pingInterval * 3)
        for id in Array(sessions.keys) {
            guard let session = sessions[id] else { continue }
            if session.lastPong < cutoff { closeSession(peerId: id, scheduleReconnect: true, keepaliveDriven: true); continue }
            if !sendSessionFrame(session.fd, data) { appLog("ping send failed to \(id.prefix(8))", level: .warning) }
            retryStalePendingHistory(for: id)
        }
    }
    func startPathMonitoring() {
        stopPathMonitoring()
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let previous = self.lastPathStatus; self.lastPathStatus = path.status
            if path.status == .satisfied && previous != .satisfied {
                appLog("Network path restored; dialing authorized cache")
                self.loadEndpointCache()
                self.scheduleDiscovery(immediate: true, scanFullSubnet: false)
            }
        }
        monitor.start(queue: syncQueue)
    }
    func stopPathMonitoring() { pathMonitor?.cancel(); pathMonitor = nil }

    func notifyPeersChanged() {
        let peers = availablePeers, names = peers.map(\.displayName)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDevicesChanged?(names); self.onPeersChanged?(peers)
            NotificationCenter.default.post(name: .syncAvailableDevicesDidChange, object: self, userInfo: ["devices": names, "peers": peers])
        }
    }
}

extension Notification.Name {
    static let syncAvailableDevicesDidChange = Notification.Name("SyncAvailableDevicesDidChange")
}
