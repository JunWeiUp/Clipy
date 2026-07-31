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
    }
    private var sessions: [String: Session] = [:]
    private var reconnectBackoffs: [String: TimeInterval] = [:]
    private var pendingReconnects: [String: DispatchWorkItem] = [:]

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
        if let session = sessions[peerId], writeAll(session.fd, data) {
            return true
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
        let cutoff = Date().addingTimeInterval(-Self.pendingQueueTTL)
        let due = pendingQueue.filter { $0.peerId == peerId && $0.enqueueAt >= cutoff }
        guard !due.isEmpty, let session = sessions[peerId] else { return }
        appLog("Flushing \(due.count) pending frame(s) to \(peerId)")
        for frame in due {
            if writeAll(session.fd, frame.data) {
                // Keep history/notif.post until ack; drop fire-and-forget types
                if frame.type != SyncType.history && frame.type != SyncType.notifPost {
                    pendingQueue.removeAll { $0.peerId == peerId && $0.data == frame.data }
                }
            }
        }
    }

    private func handleAck(hash: String) {
        guard !hash.isEmpty else { return }
        let before = pendingQueue.count
        pendingQueue.removeAll { $0.hash == hash }
        if pendingQueue.count != before {
            appLog("ACK cleared pending for hash \(hash.prefix(8))")
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
        for ip in myIPs {
            let parts = ip.split(separator: ".").map(String.init)
            guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { continue }
            guard Self.isLanIPv4(a: a, b: b) else { continue }
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
        appLog("Subnet scan: \(toScan.count) hosts on :\(port)")

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
                self.dialOnScanQueue(host: host, port: port, reason: "scan", timeout: Self.scanConnectTimeout)
            }
        }
        _ = group.wait(timeout: .now() + 20)
        appLog("Subnet scan finished")
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
            self?.dialOnScanQueue(host: host, port: port, reason: reason, timeout: timeout)
        }
    }

    private func dialOnScanQueue(host: String, port: UInt16, reason: String, timeout: TimeInterval) {
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

        guard let fd = tcpConnect(host: host, port: port, timeout: timeout) else { return }
        performHandshake(fd: fd, host: host, port: port, inbound: false)
    }

    private func performHandshake(fd: Int32, host: String, port: UInt16, inbound: Bool) {
        let hello = SyncEnvelope.make(
            type: SyncType.hello,
            peerId: peerId,
            name: displayName,
            port: Int(syncPort)
        )
        guard let helloData = encodeFrame(hello), writeAll(fd, helloData) else {
            Darwin.close(fd)
            return
        }

        // Wait for welcome (or hello if they dialed us — we reply welcome below for inbound)
        guard let frame = readOneFrame(fd: fd, timeout: Self.handshakeTimeout),
              let env = decodeEnvelope(frame) else {
            Darwin.close(fd)
            return
        }

        if env.v != SyncEnvelope.version {
            Darwin.close(fd)
            return
        }

        if inbound {
            // Peer sent hello; we already sent hello — expect their hello, reply welcome
            if env.type == SyncType.hello {
                guard env.peerId != peerId, !env.peerId.isEmpty else {
                    Darwin.close(fd)
                    return
                }
                let welcome = SyncEnvelope.make(
                    type: SyncType.welcome,
                    peerId: peerId,
                    name: displayName,
                    port: Int(syncPort)
                )
                if let data = encodeFrame(welcome) { _ = writeAll(fd, data) }
                adoptSession(peerId: env.peerId, name: env.name ?? env.peerId, host: host, port: UInt16(env.port ?? Int(port)), fd: fd)
                return
            }
        }

        // Outbound path: we sent hello, expect welcome (or hello from simultaneous dial)
        if env.type == SyncType.welcome || env.type == SyncType.hello {
            guard env.peerId != peerId, !env.peerId.isEmpty else {
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
                if let data = encodeFrame(welcome) { _ = writeAll(fd, data) }
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

        Darwin.close(fd)
    }

    private func adoptSession(peerId: String, name: String, host: String, port: UInt16, fd: Int32) {
        syncQueue.async { [weak self] in
            guard let self else { Darwin.close(fd); return }

            if let existing = self.sessions[peerId] {
                // Keep existing; drop duplicate
                Darwin.close(fd)
                self.recordPeer(peerId: peerId, name: name, host: existing.host, port: existing.port)
                return
            }

            // Close any accepting-client bookkeeping for this fd
            if let client = self.acceptingClients.removeValue(forKey: fd) {
                client.source.cancel()
            }

            var session = Session(peerId: peerId, host: host, port: port, fd: fd)
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
            closeSession(peerId: peerId, scheduleReconnect: true)
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
                Int(UInt32(bigEndian: raw.load(as: UInt32.self)))
            }
            guard length > 0, length <= Self.maxFrameLength else {
                closeSession(peerId: peerId, scheduleReconnect: true)
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
                _ = writeAll(fd, d)
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
        _ = writeAll(fd, data)
    }

    private func closeSession(peerId: String, scheduleReconnect: Bool) {
        guard let session = sessions.removeValue(forKey: peerId) else { return }
        session.readSource?.cancel()
        Darwin.close(session.fd)
        appLog("Session closed with \(peerId.prefix(8))")
        if scheduleReconnect {
            self.scheduleReconnect(peerId: peerId)
        }
    }

    private func scheduleReconnect(peerId: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        if pendingReconnects[peerId] != nil { return }
        let delay = reconnectBackoffs[peerId] ?? 1
        reconnectBackoffs[peerId] = min(delay * 2, Self.maxReconnectBackoff)
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
            self?.performHandshake(fd: clientFD, host: host, port: self?.syncPort ?? 5566, inbound: true)
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
                closeSession(peerId: id, scheduleReconnect: true)
                continue
            }
            _ = writeAll(session.fd, data)
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

    private func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
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
            Darwin.close(fd)
            return nil
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(timeout * 1000)
        let pr = poll(&pfd, 1, ms)
        guard pr > 0 else {
            Darwin.close(fd)
            return nil
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else {
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
