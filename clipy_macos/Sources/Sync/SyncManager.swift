import Foundation
import AppKit
import Network
import CryptoKit

// MARK: - Public types

struct DiscoveredPeer {
    let peerId: String
    let displayName: String
    let endpoint: NWEndpoint
    let host: String
    let port: UInt16
}

struct DeviceEntry {
    let displayName: String
    let peerId: String
    let originalName: String
}

// MARK: - Protocol v2

/// Length-prefixed JSON envelope (v2). Not compatible with the legacy SyncMessage format.
private struct SyncEnvelope: Codable {
    var v: Int
    var type: String
    var msgId: String
    var peerId: String
    var name: String?
    var port: Int?
    var ts: TimeInterval
    var hash: String?
    var payload: String?

    static let version = 2

    static func make(
        type: String,
        peerId: String,
        name: String? = nil,
        port: Int? = nil,
        hash: String? = nil,
        payload: String? = nil
    ) -> SyncEnvelope {
        SyncEnvelope(
            v: version,
            type: type,
            msgId: UUID().uuidString,
            peerId: peerId,
            name: name,
            port: port,
            ts: Date().timeIntervalSince1970,
            hash: hash,
            payload: payload
        )
    }
}

private enum SyncType {
    static let hello = "hello"
    static let welcome = "welcome"
    static let history = "history"
    static let notifPost = "notif.post"
    static let notifDismiss = "notif.dismiss"
    static let notifClear = "notif.clear"
    static let notifAck = "notif.ack"
    static let notifConfig = "notif.config"
    static let ping = "ping"
    static let pong = "pong"
    static let ack = "ack"
}

// MARK: - SyncManager

final class SyncManager: NSObject {
    static let shared = SyncManager()

    var onDevicesChanged: (([String]) -> Void)?
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?

    private let syncQueue = DispatchQueue(label: "com.clipy.sync.v2")
    private let scanQueue = DispatchQueue(label: "com.clipy.scan.v2", attributes: .concurrent)
    private let dialDedupLock = NSLock()

    private static let maxFrameLength = 2 * 1024 * 1024
    private static let hardcodedSecret = "ClipySyncSecret2026"
    private static let defaultPort: UInt16 = 5566
    private static let discoveryDebounce: TimeInterval = 0.6
    private static let handshakeTimeout: TimeInterval = 2.0
    private static let connectTimeout: TimeInterval = 3.0
    private static let scanConnectTimeout: TimeInterval = 0.35
    private static let pingInterval: TimeInterval = 30
    private static let pendingQueueMax = 80
    private static let pendingQueueTTL: TimeInterval = 24 * 60 * 60
    private static let endpointCacheKey = "clipy.peerEndpoints.v2"
    private static let endpointCacheTTL: TimeInterval = 86400
    private static let maxReconnectBackoff: TimeInterval = 30
    private static let minReconnectInterval: TimeInterval = 2
    private static let scanConcurrency = 48

    private var displayName: String { PreferencesManager.shared.deviceName }
    private var peerId: String { PreferencesManager.shared.syncPeerId }
    private var syncPort: UInt16 {
        let p = PreferencesManager.shared.syncPort
        return UInt16(clamping: p == 0 ? Int(Self.defaultPort) : p)
    }

    private var encryptionKey: SymmetricKey {
        let data = Self.hardcodedSecret.data(using: .utf8)!
        return SymmetricKey(data: SHA256.hash(data: data))
    }

    // Discovery
    private var discoveredPeers: [String: DiscoveredPeer] = [:]
    private let peersLock = NSLock()
    private var pendingDiscoveryWork: DispatchWorkItem?
    private var isRefreshingDiscovery = false
    private var lastDialAt: [String: Date] = [:]
    private let dialDedupTTL: TimeInterval = 4

    // Sessions: one live TCP per remote peerId (POSIX fd)
    private struct Session {
        let peerId: String
        let host: String
        let port: UInt16
        var fd: Int32
        var readSource: DispatchSourceRead?
        var buffer = Data()
        var lastPong = Date()
        // Role decided at handshake: the lexicographically smaller peerId is the
        // "client" and owns keepalive-driven reconnects (pong timeout, EOF). This
        // breaks the reconnect storm where both sides independently redial each
        // other after a dropped link. Both endpoints compute the same result
        // from the same two peerIds, so roles align without any protocol change.
        let isClient: Bool
    }
    private var sessions: [String: Session] = [:]
    private var reconnectBackoffs: [String: TimeInterval] = [:]
    private var pendingReconnects: [String: DispatchWorkItem] = [:]
    // Debounce: minimum gap between two reconnect attempts to the same peerId.
    // Caps the data-driven reconnect rate (deliver write failures on both sides)
    // so it can't stack with the client's keepalive reconnect into a storm.
    private var lastReconnectAttempt: [String: Date] = [:]

    // Listener
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var acceptingClients: [Int32: (host: String, buffer: Data, source: DispatchSourceRead)] = [:]

    // Delivery queue
    private struct PendingFrame {
        let peerId: String
        let data: Data
        let type: String
        let hash: String?
        let enqueueAt: Date
    }
    private var pendingQueue: [PendingFrame] = []
    // Per-peer hashes delivered on the current session but not yet ACKed.
    // Prevents a reconnect (new performHandshake → flushPending) from re-sending
    // the whole pending batch before the previous ACK arrives. Cleared on ACK
    // and on session close (so a real disconnect still allows redelivery).
    private var inFlightHashes: [String: Set<String>] = [:]

    // Keepalive
    private var pingTimer: DispatchSourceTimer?

    // Network path
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status = .requiresConnection

    // MARK: - Lifecycle

    func start() {
        appLog("SyncManager v2 starting...")
        let needListen = PreferencesManager.shared.isSyncEnabled ||
            NotificationManager.shared.notificationSyncEnabled
        guard needListen else { return }

        syncQueue.async { [weak self] in
            self?.startListening()
            self?.startPingTimer()
            self?.startPathMonitoring()
            if PreferencesManager.shared.isSyncEnabled {
                self?.loadEndpointCache()
                self?.scheduleDiscovery(immediate: true)
            }
        }
    }

    func stop() {
        appLog("SyncManager v2 stopping...")
        syncQueue.async { [weak self] in
            guard let self else { return }
            self.stopPathMonitoring()
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.pendingDiscoveryWork?.cancel()
            self.pendingDiscoveryWork = nil
            for work in self.pendingReconnects.values { work.cancel() }
            self.pendingReconnects.removeAll()
            self.reconnectBackoffs.removeAll()
            for id in Array(self.sessions.keys) {
                self.closeSession(peerId: id, scheduleReconnect: false)
            }
            for (fd, client) in self.acceptingClients {
                client.source.cancel()
                Darwin.close(fd)
            }
            self.acceptingClients.removeAll()
            self.stopListening()
            self.pendingQueue.removeAll()
            self.peersLock.lock()
            self.discoveredPeers.removeAll()
            self.peersLock.unlock()
            self.notifyPeersChanged()
        }
    }

    func restartService() {
        stop()
        syncQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }

    func refreshDiscovery() {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        guard !isRefreshingDiscovery else { return }
        isRefreshingDiscovery = true
        // Keep peers that still have a live session. Clearing them would hide
        // connected devices forever: rediscovery skips already-connected hosts,
        // so recordPeer is never called again for those sessions.
        syncQueue.async { [weak self] in
            guard let self else { return }
            let liveSessions = self.sessions
            var cacheById: [String: CachedEndpoint] = [:]
            for entry in self.loadEndpointCacheEntries() {
                cacheById[entry.peerId] = entry
            }
            self.peersLock.lock()
            var kept: [String: DiscoveredPeer] = [:]
            for (id, session) in liveSessions {
                if let existing = self.discoveredPeers[id] {
                    kept[id] = existing
                } else {
                    let name = cacheById[id]?.name ?? id
                    let endpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(session.host),
                        port: NWEndpoint.Port(rawValue: session.port) ?? 5566
                    )
                    kept[id] = DiscoveredPeer(
                        peerId: id,
                        displayName: name,
                        endpoint: endpoint,
                        host: session.host,
                        port: session.port
                    )
                }
            }
            self.discoveredPeers = kept
            self.peersLock.unlock()
            self.notifyPeersChanged()
            self.scheduleDiscovery(immediate: true)
            self.syncQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.isRefreshingDiscovery = false
            }
        }
    }

    func triggerCrossBandDiscovery() {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        scheduleDiscovery(immediate: false)
    }

    // MARK: - Public queries

    var availablePeers: [DiscoveredPeer] {
        peersLock.lock()
        defer { peersLock.unlock() }
        return discoveredPeers.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var availableDeviceNames: [String] {
        availablePeers.map(\.displayName)
    }

    var availableDeviceEntries: [DeviceEntry] {
        let peers = availablePeers
        var nameCounts: [String: Int] = [:]
        for peer in peers { nameCounts[peer.displayName, default: 0] += 1 }
        return peers.map { peer in
            let display: String
            if (nameCounts[peer.displayName] ?? 0) > 1 {
                display = "\(peer.displayName) (\(peer.peerId.prefix(6)))"
            } else {
                display = peer.displayName
            }
            return DeviceEntry(displayName: display, peerId: peer.peerId, originalName: peer.displayName)
        }
    }

    func enumerateLocalIPv4s() -> [String] {
        Self.localIPv4Addresses()
    }

    // MARK: - Broadcast APIs

    func broadcastSync(content: String, hash: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        guard let payload = encrypt(content) else { return }
        let env = SyncEnvelope.make(
            type: SyncType.history,
            peerId: peerId,
            name: displayName,
            hash: hash,
            payload: payload
        )
        fanoutReliable(env, requireAuth: true)
    }

    func broadcastNotificationMessage(type: String, content: String, hash: String) {
        let mapped = mapNotificationType(type)
        guard mapped != nil || type.hasPrefix("notif.") else {
            appLog("Unknown notification type: \(type)", level: .warning)
            return
        }
        let wireType = mapped ?? type
        guard let payload = encrypt(content) else { return }
        let env = SyncEnvelope.make(
            type: wireType,
            peerId: peerId,
            name: displayName,
            hash: hash.isEmpty ? nil : hash,
            payload: payload
        )
        // Notifications: push to authorized peers when sync is on; also allow
        // when only notification mirroring needs the listener (still require auth list).
        fanoutReliable(env, requireAuth: true, allowWithoutClipboardSync: true)
    }

    func sendNotificationAck(hash: String) {
        let env = SyncEnvelope.make(
            type: SyncType.notifAck,
            peerId: peerId,
            hash: hash,
            payload: nil
        )
        fanoutReliable(env, requireAuth: false, allowWithoutClipboardSync: true)
    }

    @discardableResult
    func sendTextToPeer(_ content: String, hash: String, peerId targetId: String) -> Bool {
        guard PreferencesManager.shared.isSyncEnabled else { return false }
        guard let payload = encrypt(content) else { return false }
        let env = SyncEnvelope.make(
            type: SyncType.history,
            peerId: peerId,
            name: displayName,
            hash: hash,
            payload: payload
        )
        return sendEnvelope(env, to: targetId, reliable: true)
    }

    func sendText(_ content: String, hash: String, toDevice targetName: String) {
        let peers = availablePeers.filter { $0.displayName == targetName }
        guard let peer = peers.first else { return }
        _ = sendTextToPeer(content, hash: hash, peerId: peer.peerId)
    }

    @discardableResult
    func sendFileToPeer(at url: URL, peerId: String) -> Bool {
        appLog("sendFileToPeer stubbed in sync v2", level: .warning)
        return false
    }

    func sendFile(at url: URL, toDevice targetName: String) {
        appLog("sendFile stubbed in sync v2", level: .warning)
    }

    // MARK: - Type mapping

    private func mapNotificationType(_ apiType: String) -> String? {
        switch apiType {
        case "notification/post": return SyncType.notifPost
        case "notification/dismiss": return SyncType.notifDismiss
        case "notification/clear_all": return SyncType.notifClear
        case "notification/ack": return SyncType.notifAck
        case "notification/config": return SyncType.notifConfig
        default: return nil
        }
    }

    // MARK: - Fanout / send

    private func clipboardAuthIds() -> Set<String> {
        Set(PreferencesManager.shared.clipboardSyncPeerIds)
    }

    private func notificationAuthIds() -> Set<String> {
        Set(PreferencesManager.shared.notificationSyncPeerIds)
    }

    private func authIds(for env: SyncEnvelope) -> Set<String> {
        switch env.type {
        case SyncType.history:
            return clipboardAuthIds()
        case SyncType.notifPost, SyncType.notifDismiss, SyncType.notifClear, SyncType.notifConfig:
            return notificationAuthIds()
        default:
            return Set(PreferencesManager.shared.authorizedPeerIds)
        }
    }

    private func fanoutReliable(
        _ env: SyncEnvelope,
        requireAuth: Bool,
        allowWithoutClipboardSync: Bool = false
    ) {
        if !allowWithoutClipboardSync && !PreferencesManager.shared.isSyncEnabled { return }
        guard let data = encodeFrame(env) else { return }
        let targets: [String]
        peersLock.lock()
        if requireAuth {
            let auth = authIds(for: env)
            targets = discoveredPeers.keys.filter { auth.contains($0) }
        } else {
            targets = Array(discoveredPeers.keys)
        }
        peersLock.unlock()

        if targets.isEmpty {
            // Queue for when peers appear (history / notif with hash)
            if env.type == SyncType.history || env.type == SyncType.notifPost {
                for peerId in authIds(for: env) {
                    enqueuePending(data: data, type: env.type, peerId: peerId, hash: env.hash)
                }
            }
            scheduleDiscovery(immediate: false)
            return
        }

        syncQueue.async { [weak self] in
            guard let self else { return }
            for id in targets {
                self.deliver(data: data, type: env.type, peerId: id, hash: env.hash, reliable: true)
            }
        }
    }

    @discardableResult
    private func sendEnvelope(_ env: SyncEnvelope, to targetId: String, reliable: Bool) -> Bool {
        guard let data = encodeFrame(env) else { return false }
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        syncQueue.async { [weak self] in
            guard let self else { sem.signal(); return }
            ok = self.deliver(data: data, type: env.type, peerId: targetId, hash: env.hash, reliable: reliable)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return ok
    }

    @discardableResult
    private func deliver(data: Data, type: String, peerId: String, hash: String?, reliable: Bool) -> Bool {
        if let session = sessions[peerId] {
            if writeAll(session.fd, data) {
                return true
            }
            appLog("deliver \(type) failed to \(peerId.prefix(8)); queueing\(reliable ? "" : " (unreliable, dropped)")", level: .warning)
        }
        if reliable {
            enqueuePending(data: data, type: type, peerId: peerId, hash: hash)
        }
        // Try dial from cache / discovered peer
        if let peer = peerSnapshot(peerId) {
            dial(host: peer.host, port: peer.port, reason: "deliver")
        } else {
            scheduleDiscovery(immediate: false)
        }
        scheduleReconnect(peerId: peerId)
        return false
    }

    private func enqueuePending(data: Data, type: String, peerId: String, hash: String?) {
        let cutoff = Date().addingTimeInterval(-Self.pendingQueueTTL)
        pendingQueue.removeAll { $0.enqueueAt < cutoff }
        if let hash, !hash.isEmpty {
            pendingQueue.removeAll { $0.peerId == peerId && $0.hash == hash }
        }
        let perPeer = pendingQueue.filter { $0.peerId == peerId }.count
        guard perPeer < Self.pendingQueueMax else { return }
        pendingQueue.append(PendingFrame(
            peerId: peerId, data: data, type: type, hash: hash, enqueueAt: Date()
        ))
    }

    private func flushPending(for peerId: String) {
        let allowClipboard = clipboardAuthIds().contains(peerId)
        let allowNotification = notificationAuthIds().contains(peerId)
        let cutoff = Date().addingTimeInterval(-Self.pendingQueueTTL)
        let due = pendingQueue.filter { frame in
            guard frame.peerId == peerId && frame.enqueueAt >= cutoff else { return false }
            switch frame.type {
            case SyncType.history:
                return allowClipboard
            case SyncType.notifPost, SyncType.notifDismiss, SyncType.notifClear, SyncType.notifConfig:
                return allowNotification
            default:
                return true
            }
        }
        guard !due.isEmpty, let session = sessions[peerId] else { return }
        // Only reliable types (history/notif.post) carry a hash and wait for ACK;
        // they are the ones at risk of redelivery on reconnect.
        let reliable = due.filter { frame in
            (frame.type == SyncType.history || frame.type == SyncType.notifPost)
                && frame.hash != nil
        }
        let dropped = reliable.filter { inFlightHashes[peerId]?.contains($0.hash!) ?? false }.count
        appLog("Flushing \(due.count) pending frame(s) to \(peerId)\(dropped > 0 ? " (skipped \(dropped) in-flight)" : "")")
        for frame in due {
            // Skip hashes already delivered on this session and awaiting ACK.
            if (frame.type == SyncType.history || frame.type == SyncType.notifPost),
               let hash = frame.hash,
               inFlightHashes[peerId]?.contains(hash) ?? false {
                continue
            }
            if writeAll(session.fd, frame.data) {
                if frame.type == SyncType.history || frame.type == SyncType.notifPost {
                    if let hash = frame.hash {
                        if inFlightHashes[peerId] == nil { inFlightHashes[peerId] = [] }
                        inFlightHashes[peerId]?.insert(hash)
                    }
                } else {
                    // fire-and-forget: drop immediately
                    pendingQueue.removeAll { $0.peerId == peerId && $0.data == frame.data }
                }
            } else {
                appLog("flushPending \(frame.type) send failed to \(peerId.prefix(8)); frame retained", level: .warning)
            }
        }
    }

    /// Re-flush pending frames after the user toggles outbound auth for a peer.
    func refreshPendingDelivery(for peerId: String) {
        syncQueue.async { [weak self] in
            self?.flushPending(for: peerId)
        }
    }

    private func handleAck(hash: String) {
        guard !hash.isEmpty else { return }
        let before = pendingQueue.count
        pendingQueue.removeAll { $0.hash == hash }
        if pendingQueue.count != before {
            appLog("ACK cleared pending for hash \(hash.prefix(8))")
        }
        // Clear the in-flight mark so future flushes may redeliver if needed.
        for key in inFlightHashes.keys {
            inFlightHashes[key]?.remove(hash)
        }
    }

    // MARK: - Discovery

    private func scheduleDiscovery(immediate: Bool) {
        pendingDiscoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDiscovery()
        }
        pendingDiscoveryWork = work
        let delay = immediate ? 0.05 : Self.discoveryDebounce
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runDiscovery() {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        let manual = PreferencesManager.shared.manualSyncPeers
        let port = syncPort
        let myIPs = Set(Self.localIPv4Addresses())
        let myPeerId = peerId

        // Surface every local interface so VPN-induced fake LAN subnets (utun/tun
        // carrying 10.8.0.x etc.) are visible. A VPN interface appearing as [LAN]
        // is the tell-tale sign of route hijack starving the real Wi-Fi subnet.
        appLog(Self.diagnoseInterfaces())

        // Manual peers first
        for entry in manual {
            let parts = entry.split(separator: ":")
            guard let host = parts.first.map(String.init), !host.isEmpty else { continue }
            let p: UInt16
            if parts.count >= 2, let parsed = UInt16(parts[1]) {
                p = parsed
            } else {
                p = port
            }
            dial(host: host, port: p, reason: "manual")
        }

        // Cached endpoints
        syncQueue.sync {
            for (id, session) in sessions {
                _ = id
                _ = session
            }
        }
        let cached = loadEndpointCacheEntries()
        for entry in cached where entry.peerId != myPeerId {
            dial(host: entry.host, port: entry.port, reason: "cache")
        }

        // /24 subnet scan
        var candidates: [String] = []
        var subnets = Set<String>()
        for ip in myIPs {
            let parts = ip.split(separator: ".").map(String.init)
            guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { continue }
            guard Self.isLanIPv4(a: a, b: b) else { continue }
            subnets.insert("\(a).\(b).\(c).0/24")
            for d in 1...254 {
                let candidate = "\(a).\(b).\(c).\(d)"
                if myIPs.contains(candidate) { continue }
                candidates.append(candidate)
            }
        }
        candidates = Array(Set(candidates)).sorted()

        // Skip hosts we already have live sessions to
        let connectedHosts: Set<String> = syncQueue.sync {
            Set(sessions.values.map(\.host))
        }
        let toScan = candidates.filter { !connectedHosts.contains($0) }
        let subnetList = subnets.isEmpty ? "<none>" : subnets.sorted().joined(separator: ", ")
        appLog("Subnet scan: \(toScan.count) hosts on :\(port) (subnets: \(subnetList))")

        let stats = ScanStats()
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: Self.scanConcurrency)
        for host in toScan {
            group.enter()
            semaphore.wait()
            scanQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                self.dialOnScanQueue(host: host, port: port, reason: "scan", timeout: Self.scanConnectTimeout, stats: stats)
            }
        }
        _ = group.wait(timeout: .now() + 20)
        appLog("Subnet scan finished: \(stats.summary())")
    }

    private func peerSnapshot(_ id: String) -> DiscoveredPeer? {
        peersLock.lock()
        defer { peersLock.unlock() }
        return discoveredPeers[id]
    }

    // MARK: - Dial / handshake

    private func dial(host: String, port: UInt16, reason: String, timeout: TimeInterval = SyncManager.connectTimeout) {
        // Never block syncQueue on TCP connect/handshake.
        scanQueue.async { [weak self] in
            self?.dialOnScanQueue(host: host, port: port, reason: reason, timeout: timeout, stats: nil)
        }
    }

    private func dialOnScanQueue(host: String, port: UInt16, reason: String, timeout: TimeInterval, stats: ScanStats?) {
        let key = "\(host):\(port)"
        let now = Date()
        dialDedupLock.lock()
        if let last = lastDialAt[key], now.timeIntervalSince(last) < dialDedupTTL, reason == "scan" {
            dialDedupLock.unlock()
            return
        }
        lastDialAt[key] = now
        dialDedupLock.unlock()

        let already: Bool = syncQueue.sync {
            sessions.values.contains { $0.host == host }
        }
        if already { return }

        if let stats = stats, reason == "scan" { stats.recordAttempt() }
        var connFailure: ConnectFailure? = nil
        guard let fd = tcpConnectDiag(host: host, port: port, timeout: timeout, failure: &connFailure) else {
            if let stats = stats, reason == "scan" {
                stats.recordConnectFailure(connFailure ?? .other)
            } else if reason != "scan" {
                appLog("Dial \(reason) \(host):\(port) failed: connect(\(connFailure?.label ?? "unknown"))", level: .warning)
            }
            return
        }
        if let stats = stats, reason == "scan" { stats.recordConnectOk() }

        let isScan = reason == "scan"
        performHandshake(fd: fd, host: host, port: port, inbound: false) { hf in
            if isScan {
                stats?.recordHandshakeFailure(hf)
            } else {
                appLog("Dial \(reason) \(host):\(port) failed: handshake(\(hf.label))", level: .warning)
            }
        }
    }

    private func performHandshake(fd: Int32, host: String, port: UInt16, inbound: Bool, onFailure: ((HandshakeFailure) -> Void)? = nil) {
        let hello = SyncEnvelope.make(
            type: SyncType.hello,
            peerId: peerId,
            name: displayName,
            port: Int(syncPort)
        )
        guard let helloData = encodeFrame(hello), writeAll(fd, helloData) else {
            onFailure?(.writeFail)
            Darwin.close(fd)
            return
        }

        // Wait for welcome (or hello if they dialed us — we reply welcome below for inbound)
        guard let frame = readOneFrame(fd: fd, timeout: Self.handshakeTimeout),
              let env = decodeEnvelope(frame) else {
            onFailure?(.readTimeout)
            Darwin.close(fd)
            return
        }

        if env.v != SyncEnvelope.version {
            onFailure?(.versionMismatch)
            Darwin.close(fd)
            return
        }

        if inbound {
            // Peer sent hello; we already sent hello — expect their hello, reply welcome
            if env.type == SyncType.hello {
                guard env.peerId != peerId, !env.peerId.isEmpty else {
                    onFailure?(.selfHandshake)
                    Darwin.close(fd)
                    return
                }
                let welcome = SyncEnvelope.make(
                    type: SyncType.welcome,
                    peerId: peerId,
                    name: displayName,
                    port: Int(syncPort)
                )
                if let data = encodeFrame(welcome), !writeAll(fd, data) {
                    appLog("welcome send failed (inbound) to \(env.peerId.prefix(8))", level: .warning)
                }
                adoptSession(peerId: env.peerId, name: env.name ?? env.peerId, host: host, port: UInt16(env.port ?? Int(port)), fd: fd)
                return
            }
        }

        // Outbound path: we sent hello, expect welcome (or hello from simultaneous dial)
        if env.type == SyncType.welcome || env.type == SyncType.hello {
            guard env.peerId != peerId, !env.peerId.isEmpty else {
                onFailure?(.selfHandshake)
                Darwin.close(fd)
                return
            }
            if env.type == SyncType.hello {
                let welcome = SyncEnvelope.make(
                    type: SyncType.welcome,
                    peerId: peerId,
                    name: displayName,
                    port: Int(syncPort)
                )
                if let data = encodeFrame(welcome), !writeAll(fd, data) {
                    appLog("welcome send failed (outbound) to \(env.peerId.prefix(8))", level: .warning)
                }
            }
            // Tie-break: if we are lexicographically larger and this is outbound,
            // prefer letting the smaller peer own the link — but keep this session
            // if we don't already have one (firewall-safe).
            adoptSession(
                peerId: env.peerId,
                name: env.name ?? env.peerId,
                host: host,
                port: UInt16(env.port ?? Int(port)),
                fd: fd
            )
            return
        }

        onFailure?(.badType)
        Darwin.close(fd)
    }

    private func adoptSession(peerId: String, name: String, host: String, port: UInt16, fd: Int32) {
        syncQueue.async { [weak self] in
            guard let self else { Darwin.close(fd); return }

            if let existing = self.sessions[peerId] {
                // Keep existing; drop duplicate
                appLog("Duplicate session for \(peerId.prefix(8)), dropping new fd (existing @ \(existing.host))")
                Darwin.close(fd)
                self.recordPeer(peerId: peerId, name: name, host: existing.host, port: existing.port)
                return
            }

            // Close any accepting-client bookkeeping for this fd
            if let client = self.acceptingClients.removeValue(forKey: fd) {
                client.source.cancel()
            }

            var session = Session(peerId: peerId, host: host, port: port, fd: fd,
                                  isClient: self.peerId < peerId)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.syncQueue)
            source.setEventHandler { [weak self] in
                self?.onSessionReadable(peerId: peerId)
            }
            source.setCancelHandler {
                // fd closed in closeSession
            }
            session.readSource = source
            self.sessions[peerId] = session
            source.resume()

            self.reconnectBackoffs[peerId] = 1
            if let work = self.pendingReconnects.removeValue(forKey: peerId) {
                work.cancel()
            }

            self.recordPeer(peerId: peerId, name: name, host: host, port: port)
            self.persistEndpoint(peerId: peerId, name: name, host: host, port: port)
            self.flushPending(for: peerId)
            appLog("Session up with \(name) (\(peerId.prefix(8))) @ \(host):\(port)")
        }
    }

    private func recordPeer(peerId: String, name: String, host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 5566
        )
        let peer = DiscoveredPeer(
            peerId: peerId,
            displayName: name,
            endpoint: endpoint,
            host: host,
            port: port
        )
        peersLock.lock()
        discoveredPeers[peerId] = peer
        let peers = Array(discoveredPeers.values)
        peersLock.unlock()
        PreferencesManager.shared.migrateAuthorizedPeerIds(from: peers)
        notifyPeersChanged()
    }

    private func notifyPeersChanged() {
        let peers = availablePeers
        let names = peers.map(\.displayName)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDevicesChanged?(names)
            self.onPeersChanged?(peers)
            NotificationCenter.default.post(
                name: .syncAvailableDevicesDidChange,
                object: self,
                userInfo: ["devices": names, "peers": peers]
            )
        }
    }

    private func onSessionReadable(peerId: String) {
        guard var session = sessions[peerId] else { return }
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.recv(session.fd, &tmp, tmp.count, 0)
        if n <= 0 {
            appLog("recv \(n == 0 ? "EOF" : "error errno=\(errno)") from \(peerId.prefix(8))")
            closeSession(peerId: peerId, scheduleReconnect: true, keepaliveDriven: true)
            return
        }
        session.buffer.append(contentsOf: tmp.prefix(n))
        sessions[peerId] = session
        drainBuffer(peerId: peerId)
    }

    private func drainBuffer(peerId: String) {
        guard var session = sessions[peerId] else { return }
        while true {
            guard session.buffer.count >= 4 else {
                sessions[peerId] = session
                return
            }
            let length: Int = session.buffer.withUnsafeBytes { raw in
                // loadUnaligned: the buffer is a Data byte array, no 4-byte
                // alignment guarantee — an aligned `load` would be UB on some
                // ISAs. The `count >= 4` guard above makes this safe regardless.
                Int(UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self)))
            }
            guard length > 0, length <= Self.maxFrameLength else {
                closeSession(peerId: peerId, scheduleReconnect: true, keepaliveDriven: true)
                return
            }
            guard session.buffer.count >= 4 + length else {
                sessions[peerId] = session
                return
            }
            let frame = session.buffer.subdata(in: 4..<(4 + length))
            session.buffer.removeSubrange(0..<(4 + length))
            sessions[peerId] = session
            handleFrame(frame, from: peerId, host: session.host)
            guard let again = sessions[peerId] else { return }
            session = again
        }
    }

    private func handleFrame(_ data: Data, from remotePeerId: String, host: String) {
        guard let env = decodeEnvelope(data), env.v == SyncEnvelope.version else { return }

        switch env.type {
        case SyncType.ping:
            let pong = SyncEnvelope.make(type: SyncType.pong, peerId: peerId)
            if let d = encodeFrame(pong), let fd = sessions[remotePeerId]?.fd {
                if !writeAll(fd, d) {
                    appLog("pong send failed to \(remotePeerId.prefix(8))", level: .warning)
                }
            }
        case SyncType.pong:
            if var s = sessions[remotePeerId] {
                s.lastPong = Date()
                sessions[remotePeerId] = s
            }
        case SyncType.ack:
            if let hash = env.hash { handleAck(hash: hash) }
        case SyncType.history:
            guard let payload = env.payload, let text = decrypt(payload) else { return }
            DispatchQueue.main.async {
                ClipboardManager.shared.handleRemoteSync(content: text, hash: env.hash ?? "")
            }
            replyAck(to: remotePeerId, hash: env.hash)
        case SyncType.notifPost:
            guard let payload = env.payload, let text = decrypt(payload) else { return }
            DispatchQueue.main.async {
                NotificationManager.shared.handleRemoteNotification(text, from: env.peerId)
            }
        case SyncType.notifDismiss:
            guard let payload = env.payload, let text = decrypt(payload) else { return }
            DispatchQueue.main.async {
                NotificationManager.shared.handleRemoteDismiss(text)
            }
        case SyncType.notifClear:
            DispatchQueue.main.async {
                NotificationManager.shared.handleRemoteClearAll()
            }
        case SyncType.notifAck:
            if let hash = env.hash {
                handleAck(hash: hash)
            }
        case SyncType.notifConfig:
            appLog("Ignored remote notification config", level: .warning)
        case SyncType.hello, SyncType.welcome:
            // Late handshake frames on an established session — refresh peer metadata
            if let name = env.name, let p = env.port {
                recordPeer(peerId: env.peerId, name: name, host: host, port: UInt16(p))
            }
        default:
            break
        }
    }

    private func replyAck(to peerId: String, hash: String?) {
        guard let hash, !hash.isEmpty else { return }
        let env = SyncEnvelope.make(type: SyncType.ack, peerId: self.peerId, hash: hash)
        guard let data = encodeFrame(env), let fd = sessions[peerId]?.fd else { return }
        if !writeAll(fd, data) {
            appLog("ack send failed to \(peerId.prefix(8))", level: .warning)
        }
    }

    private func closeSession(peerId: String, scheduleReconnect: Bool, keepaliveDriven: Bool = false) {
        guard let session = sessions.removeValue(forKey: peerId) else { return }
        session.readSource?.cancel()
        Darwin.close(session.fd)
        // Drop the in-flight marks for this peer: the session is gone, so ACKs
        // for anything sent on it will never return. Clearing allows a reconnect
        // to legitimately redeliver still-pending items.
        inFlightHashes.removeValue(forKey: peerId)
        appLog("Session closed with \(peerId.prefix(8))")
        guard scheduleReconnect else { return }
        // Keepalive-driven close (pong timeout / EOF / frame corruption): only the
        // client role redials, so the two sides don't both reconnect each other.
        // Data-driven close (deliver write fail) bypasses this — both roles may
        // reconnect, throttled by scheduleReconnect's debounce.
        if keepaliveDriven && !session.isClient { return }
        self.scheduleReconnect(peerId: peerId)
    }

    private func scheduleReconnect(peerId: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        if pendingReconnects[peerId] != nil { return }
        // Debounce: don't fire another reconnect attempt within the min interval.
        // This caps data-driven reconnects (deliver write failures) so they can't
        // pile on top of the client's keepalive reconnect.
        let now = Date()
        if let last = lastReconnectAttempt[peerId], now.timeIntervalSince(last) < Self.minReconnectInterval {
            return
        }
        lastReconnectAttempt[peerId] = now
        let delay = reconnectBackoffs[peerId] ?? 1
        reconnectBackoffs[peerId] = min(delay * 2, Self.maxReconnectBackoff)
        appLog("Reconnect scheduled for \(peerId.prefix(8)) in \(Int(delay))s (next backoff \(Int(min(delay * 2, Self.maxReconnectBackoff)))s)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconnects.removeValue(forKey: peerId)
            guard self.sessions[peerId] == nil else { return }
            if let peer = self.peerSnapshot(peerId) {
                self.dial(host: peer.host, port: peer.port, reason: "reconnect")
            } else {
                self.scheduleDiscovery(immediate: false)
            }
        }
        pendingReconnects[peerId] = work
        syncQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Listener (POSIX IPv4)

    private func startListening() {
        stopListening()
        let port = syncPort
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            appLog("Failed to create listen socket", level: .error)
            return
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 32) == 0 else {
            appLog("Failed to bind/listen on \(port): \(errno)", level: .error)
            Darwin.close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: syncQueue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.listenFD >= 0 {
                Darwin.close(self.listenFD)
                self.listenFD = -1
            }
        }
        listenSource = source
        source.resume()
        appLog("Listening on 0.0.0.0:\(port)")
    }

    private func stopListening() {
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    private func acceptClient() {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenFD, $0, &len)
            }
        }
        guard clientFD >= 0 else { return }
        var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostBuf)
        appLog("Inbound connection from \(host)")

        // Handshake on background then adopt
        scanQueue.async { [weak self] in
            guard let self else { Darwin.close(clientFD); return }
            self.performHandshake(fd: clientFD, host: host, port: self.syncPort, inbound: true) { hf in
                appLog("Inbound handshake failed from \(host): \(hf.label)", level: .warning)
            }
        }
    }

    // MARK: - Keepalive / path

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            self?.sendPings()
        }
        pingTimer = timer
        timer.resume()
    }

    private func sendPings() {
        let env = SyncEnvelope.make(type: SyncType.ping, peerId: peerId)
        guard let data = encodeFrame(env) else { return }
        let staleCutoff = Date().addingTimeInterval(-Self.pingInterval * 3)
        for (id, session) in sessions {
            if session.lastPong < staleCutoff {
                closeSession(peerId: id, scheduleReconnect: true, keepaliveDriven: true)
                continue
            }
            if !writeAll(session.fd, data) {
                appLog("ping send failed to \(id.prefix(8))", level: .warning)
            }
        }
    }

    private func startPathMonitoring() {
        stopPathMonitoring()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let prev = self.lastPathStatus
            self.lastPathStatus = path.status
            if path.status == .satisfied && prev != .satisfied {
                appLog("Network path restored; rediscovering")
                self.scheduleDiscovery(immediate: true)
            }
        }
        monitor.start(queue: syncQueue)
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Codec / crypto

    private func encodeFrame(_ env: SyncEnvelope) -> Data? {
        guard let json = try? JSONEncoder().encode(env) else { return nil }
        var length = UInt32(json.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(json)
        return out
    }

    private func decodeEnvelope(_ data: Data) -> SyncEnvelope? {
        try? JSONDecoder().decode(SyncEnvelope.self, from: data)
    }

    private func encrypt(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            let iv = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: encryptionKey, nonce: iv)
            var combined = Data(iv)
            combined.append(sealed.ciphertext)
            combined.append(sealed.tag)
            return combined.base64EncodedString()
        } catch {
            return nil
        }
    }

    private func decrypt(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count > 28 else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: data.prefix(12))
            let tag = data.suffix(16)
            let ciphertext = data.dropFirst(12).dropLast(16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(box, using: encryptionKey)
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - POSIX helpers

    /// Classified TCP connect failure for diagnostics. Most silent scan failures
    /// (VPN route hijack, firewall, port closed) collapse into `.timeout` — that
    /// bucket dominating the scan summary is the VPN/route-hijack tell-tale.
    private enum ConnectFailure {
        case timeout, refused, unreachable, other

        fileprivate init(errno err: Int32) {
            switch err {
            case ECONNREFUSED: self = .refused
            case EHOSTUNREACH, ENETUNREACH: self = .unreachable
            default: self = .other
            }
        }
        fileprivate init(soError err: Int32) {
            switch err {
            case ECONNREFUSED: self = .refused
            case EHOSTUNREACH, ENETUNREACH: self = .unreachable
            default: self = .other
            }
        }

        fileprivate var label: String {
            switch self {
            case .timeout: return "timeout"
            case .refused: return "refused"
            case .unreachable: return "unreachable"
            case .other: return "other"
            }
        }
    }

    /// Classified handshake failure for diagnostics.
    private enum HandshakeFailure {
        case writeFail, readTimeout, versionMismatch, selfHandshake, badType

        fileprivate var label: String {
            switch self {
            case .writeFail: return "writeFail"
            case .readTimeout: return "readTimeout"
            case .versionMismatch: return "versionMismatch"
            case .selfHandshake: return "selfHandshake"
            case .badType: return "badType"
            }
        }
    }

    /// Thread-safe aggregator for one /24 scan sweep. scanQueue is concurrent with
    /// up to `scanConcurrency` workers, so counters are guarded by an NSLock.
    private final class ScanStats {
        private let lock = NSLock()
        private var attempted = 0
        private var connectOk = 0
        private var connectFail: [ConnectFailure: Int] = [:]
        private var handshakeFail: [HandshakeFailure: Int] = [:]

        func recordAttempt() { lock.lock(); defer { lock.unlock() }; attempted += 1 }
        func recordConnectOk() { lock.lock(); defer { lock.unlock() }; connectOk += 1 }
        func recordConnectFailure(_ f: ConnectFailure) {
            lock.lock(); defer { lock.unlock() }
            connectFail[f, default: 0] += 1
        }
        func recordHandshakeFailure(_ f: HandshakeFailure) {
            lock.lock(); defer { lock.unlock() }
            handshakeFail[f, default: 0] += 1
        }

        func summary() -> String {
            lock.lock(); defer { lock.unlock() }
            let hsFailTotal = handshakeFail.values.reduce(0, +)
            let hsOk = max(connectOk - hsFailTotal, 0)
            let cfParts = connectFail.sorted { $0.key.label < $1.key.label }.map { "\($0.key.label)=\($0.value)" }
            let hfParts = handshakeFail.sorted { $0.key.label < $1.key.label }.map { "\($0.key.label)=\($0.value)" }
            let cfStr = cfParts.isEmpty ? "" : cfParts.joined(separator: ",")
            let hfStr = hfParts.isEmpty ? "" : hfParts.joined(separator: ",")
            return "attempted=\(attempted) connect_ok=\(connectOk) handshake_ok=\(hsOk) | connect_fail{\(cfStr)} handshake_fail{\(hfStr)}"
        }
    }

    private func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) -> Int32? {
        var failure: ConnectFailure? = nil
        return tcpConnectDiag(host: host, port: port, timeout: timeout, failure: &failure)
    }

    /// Same behavior as `tcpConnect`, but reports *why* it failed via `failure`.
    /// Original callers ignore the out-param and behavior is unchanged.
    private func tcpConnectDiag(host: String, port: UInt16, timeout: TimeInterval, failure: inout ConnectFailure?) -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { failure = .other; return nil }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            failure = .other
            Darwin.close(fd)
            return nil
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            setTCPNoDelay(fd)
            return fd
        }
        if errno != EINPROGRESS {
            failure = ConnectFailure(errno: errno)
            Darwin.close(fd)
            return nil
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(timeout * 1000)
        let pr = poll(&pfd, 1, ms)
        guard pr > 0 else {
            failure = .timeout
            Darwin.close(fd)
            return nil
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else {
            failure = ConnectFailure(soError: soError)
            Darwin.close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTCPNoDelay(fd)
        setKeepalive(fd)
        return fd
    }

    private func setTCPNoDelay(_ fd: Int32) {
        var v: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &v, socklen_t(MemoryLayout.size(ofValue: v)))
    }

    private func setKeepalive(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            let total = raw.count
            while sent < total {
                let n = Darwin.send(fd, base + sent, total - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func readOneFrame(fd: Int32, timeout: TimeInterval) -> Data? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.count >= 4 {
                let length: Int = buffer.withUnsafeBytes { raw in
                    Int(UInt32(bigEndian: raw.load(as: UInt32.self)))
                }
                if length <= 0 || length > Self.maxFrameLength { return nil }
                if buffer.count >= 4 + length {
                    return buffer.subdata(in: 4..<(4 + length))
                }
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remain = deadline.timeIntervalSinceNow
            guard remain > 0 else { return nil }
            let pr = poll(&pfd, 1, Int32(remain * 1000))
            guard pr > 0 else { return nil }
            var tmp = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: tmp.prefix(n))
        }
        return nil
    }

    // MARK: - Endpoint cache

    private struct CachedEndpoint: Codable {
        let peerId: String
        let name: String
        let host: String
        let port: UInt16
        let ts: TimeInterval
    }

    private func persistEndpoint(peerId: String, name: String, host: String, port: UInt16) {
        var entries = loadEndpointCacheEntries()
        entries.removeAll { $0.peerId == peerId }
        entries.append(CachedEndpoint(
            peerId: peerId, name: name, host: host, port: port,
            ts: Date().timeIntervalSince1970
        ))
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.endpointCacheKey)
        }
    }

    private func loadEndpointCacheEntries() -> [CachedEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: Self.endpointCacheKey),
              let decoded = try? JSONDecoder().decode([CachedEndpoint].self, from: data) else {
            return []
        }
        let cutoff = Date().timeIntervalSince1970 - Self.endpointCacheTTL
        return decoded.filter { $0.ts >= cutoff }
    }

    private func loadEndpointCache() {
        for entry in loadEndpointCacheEntries() where entry.peerId != peerId {
            recordPeer(peerId: entry.peerId, name: entry.name, host: entry.host, port: entry.port)
            dial(host: entry.host, port: entry.port, reason: "cache")
        }
    }

    // MARK: - LAN helpers

    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var addr = p.pointee.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(
                &addr, socklen_t(addr.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard ok == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, isLanIPv4(a: parts[0], b: parts[1]) else { continue }
            result.append(ip)
        }
        return Array(Set(result)).sorted()
    }

    /// One-line diagnostic of every up, non-loopback IPv4 interface and whether it
    /// is treated as a LAN scan subnet. A VPN `utun` carrying `10.8.0.x` shows up
    /// as `[LAN]` here because `isLanIPv4(10, *) == true` — that is the tell-tale
    /// sign of VPN route hijack starving the real Wi-Fi subnet of scan packets.
    static func diagnoseInterfaces() -> String {
        var parts: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return "Discovery local interfaces: <getifaddrs failed>"
        }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let nameC = p.pointee.ifa_name
            let ifName = nameC.map { String(cString: $0) } ?? "?"
            var addr = p.pointee.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(&addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            let isLan = octets.count == 4 && isLanIPv4(a: octets[0], b: octets[1])
            parts.append("\(ifName)=\(ip)[\(isLan ? "LAN" : "ignored")]")
        }
        if parts.isEmpty { return "Discovery local interfaces: <none>" }
        return "Discovery local interfaces: " + parts.joined(separator: ", ")
    }

    static func isLanIPv4(a: Int, b: Int) -> Bool {
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        return false
    }
}

extension Notification.Name {
    static let syncAvailableDevicesDidChange = Notification.Name("SyncAvailableDevicesDidChange")
}
