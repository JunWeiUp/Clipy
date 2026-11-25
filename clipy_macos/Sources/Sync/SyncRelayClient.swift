import Foundation
import Darwin
import CommonRelay

final class SyncRelayClient: @unchecked Sendable {
    struct Peer: Decodable { let id: String; let name: String; let addresses: [String]; let port: UInt16 }
    struct Access: Decodable {
        let app: String, group: String, device: String, token: String, secret_key: String
        let sync_key: String?
        let trusted_peers: [String: String]
        func identity() throws -> RelayIdentity { try RelayIdentity(app: app, group: group, device: device, secretKey: Data(relayHex: secret_key), trustedPeers: trusted_peers.mapValues { try Data(relayHex: $0) }) }
        static func parse(_ raw: String) -> Access? {
            guard raw.utf8.count <= 65536, let value = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)), value.app == "clipy", value.token.count >= 32,
                SyncRelaySettings.validDeviceID(value.device), value.token.count <= 4096, (try? value.identity()) != nil else { return nil }; return value
        }
    }
    let queue = DispatchQueue(label: "com.clipy.relay")
    private let url: URL, id: String, name: String
    private var token: String
    private let accessPassword: String?
    private let statusOwner = UUID()
    private let port: UInt16, addresses: [String], onPeers: ([Peer]) -> Void
    private static let journal: Result<RelayJournal, Error> = Result {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try RelayJournal(directory: support.appendingPathComponent("ClipyClone/common-relay-journal", isDirectory: true))
    }
    var onPeerAvailable: (() -> Void)?
    var onSocket: ((Peer, Int32) -> Void)?
    private var refreshGeneration: Int?
    private var refreshRequestID: UUID?
    private var client: CommonRelay.RelayClient?
    private var v2Pipe: CommonRelay.RelayV2Pipe?
    private var runTask: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var generation = 0, backoff: Double = 1
    private var refreshingMembership = false
    private var membershipChecked = false
    private var stopped = false
    /// Liveness: a peers query must answer within `firstProbeTimeout`; one slow answer gets a
    /// second, longer window before the session is declared lost. A single hiccup (relay
    /// under load, proxy, Wi-Fi wake) no longer tears down and rebuilds the whole WebSocket.
    static let firstProbeTimeout: TimeInterval = 3, retryProbeTimeout: TimeInterval = 8
    private var connectedAt: Date?
    private var reconnects = 0
    private var metadata: [String: Peer] = [:]
    private var bridges: [String: RelayByteBridge] = [:]
    private var pending: [String: RelayEvent] = [:]
    private var pendingV2: [String: RelayV2PipeEvent] = [:]
    private var callbacks: [String: (Int32) -> Void] = [:]
    private var opening = Set<String>()
    private var liveOnlinePeers = Set<String>()
    private func publishLivePresence() {
        var online = liveOnlinePeers
        if let own = Access.parse(token)?.device { online.insert(own) }
        var names: [String: String] = [:]
        for (relayID, peer) in metadata { names[relayID] = peer.name }
        SyncRelayConnectionState.shared.updatePresence(online: online, names: names, owner: statusOwner)
    }
    private var isV2: Bool { url.path == "/v2/ws" }
    private var v2BaseURL: String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = (url.scheme == "ws") ? "http" : "https"
        comps?.path = ""
        return comps?.string ?? ""
    }
    static func validURL(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path == "/relay/v1/ws" || url.path == "/v2/ws"
    }
    init(url: URL, token: String, id: String, name: String, port: UInt16, addresses: [String], accessPassword: String? = nil, onPeers: @escaping ([Peer]) -> Void) {
        self.accessPassword = accessPassword
        self.url = url; self.token = token; self.id = id; self.name = name; self.port = port; self.addresses = addresses; self.onPeers = onPeers
    }
    func start() { SyncRelayConnectionState.shared.begin(statusOwner); queue.async { self.connect() } }
    func refreshPeers() {
        queue.async {
            guard !self.stopped else { return }
            if self.isV2 {
                guard let pipe = self.v2Pipe else {
                    self.retry?.cancel(); self.retry = nil
                    self.connect(); return
                }
                self.refreshV2(pipe, self.generation)
                return
            }
            guard let client = self.client else {
                self.retry?.cancel(); self.retry = nil
                self.connect(); return
            }
            self.refresh(client, self.generation)
        }
    }
    private func connect() {
        guard !stopped else { return }
        if !membershipChecked {
            guard !refreshingMembership else { return };refreshingMembership = true
            let raw = token, endpoint = url.absoluteString
            Task { @MainActor [weak self] in
                do {
                    let value = try await SyncRelayGroups.refreshedConfiguration(raw,url:endpoint,accessPassword:self?.accessPassword)
                    self?.queue.async { guard let self, !self.stopped else { return };self.refreshingMembership = false;self.membershipChecked = true;self.token = value;self.connect() }
                } catch { self?.queue.async { guard let self, !self.stopped else { return };self.refreshingMembership = false;self.report(error);self.lost(self.generation, reason: "membership refresh failed: \(error)") } }
            }
            return
        }
        if isV2 {
            connectV2()
            return
        }
        guard !stopped, let access = Access.parse(token), let identity = try? access.identity() else { return }
        generation += 1; let current = generation
        let journal: RelayJournal
        do { journal = try Self.journal.get() }
        catch { lost(current, reason: "journal unavailable"); return }
        let connection = CommonRelay.RelayClient(identity: identity, journal: journal); client = connection
        runTask = Task { [weak self] in
            do {
                guard let self else { return }
                let events = try await connection.connect(url: self.url, token: access.token, password: self.accessPassword)
                self.queue.async {
                    guard current == self.generation, !self.stopped else { return }
                    SyncRelayConnectionState.shared.update(.connected, owner: self.statusOwner)
                    appLog("Relay: connected (reconnects=\(self.reconnects), backoff was \(Int(self.backoff))s)")
                    self.connectedAt = Date(); self.backoff = 1; self.refresh(connection, current)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 30, repeating: 30)
                    timer.setEventHandler { [weak self] in self?.refresh(connection, current) }; self.timer = timer; timer.resume()
                }
                for try await event in events { self.queue.async { guard current == self.generation, !self.stopped else { return }; self.handle(event, connection, current) } }
            } catch { self?.queue.async { guard let self, !self.stopped, current == self.generation else { return }; self.report(error); self.lost(current, reason: "connection: \(error)") } }
        }
    }
    private func connectV2() {
        guard !stopped, let access = Access.parse(token), let identity = try? access.identity() else { return }
        generation += 1; let current = generation
        let v2Client: RelayV2Client
        do {
            v2Client = try RelayV2Client(baseURL: v2BaseURL, accessPassword: accessPassword ?? "", token: access.token)
        } catch {
            lost(current, reason: "invalid v2 url: \(error)")
            return
        }
        let pipe = RelayV2Pipe(client: v2Client, space: access.group, identity: identity)
        v2Pipe = pipe
        runTask = Task { [weak self] in
            do {
                guard let self else { return }
                let events = try await pipe.connect()
                self.queue.async {
                    guard current == self.generation, !self.stopped else { return }
                    SyncRelayConnectionState.shared.update(.connected, owner: self.statusOwner)
                    appLog("Relay v2: connected (reconnects=\(self.reconnects), backoff was \(Int(self.backoff))s)")
                    self.connectedAt = Date(); self.backoff = 1; self.refreshV2(pipe, current)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 30, repeating: 30)
                    timer.setEventHandler { [weak self] in self?.refreshV2(pipe, current) }; self.timer = timer; timer.resume()
                }
                for try await event in events {
                    self.queue.async {
                        guard current == self.generation, !self.stopped else { return }
                        self.handleV2(event, pipe, current)
                    }
                }
            } catch {
                self?.queue.async {
                    guard let self, !self.stopped, current == self.generation else { return }
                    self.report(error)
                    self.lost(current, reason: "v2 connection: \(error)")
                }
            }
        }
    }
    private func announceV2(_ peer: String, _ pipe: RelayV2Pipe, _ current: Int) {
        guard let access = Access.parse(token), peer != access.device, access.trusted_peers[peer] != nil else { return }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "clipy.presence", "peerId": id, "name": name, "port": Int(port), "addresses": Array(addresses.prefix(8))])
        Task { try? await pipe.sendMessage(to: peer, topic: "clipy.presence", plaintext: data) }
    }
    private func refreshV2(_ pipe: RelayV2Pipe, _ current: Int) {
        onPeers(Array(metadata.values))
        guard refreshGeneration != current else { return }; refreshGeneration = current
        let requestID = UUID(); refreshRequestID = requestID
        queryV2(pipe, current, requestID)
        armProbeDeadlineV2(pipe, current, requestID, retry: false)
    }
    private func armProbeDeadlineV2(_ pipe: RelayV2Pipe, _ current: Int, _ requestID: UUID, retry: Bool) {
        queue.asyncAfter(deadline: .now() + (retry ? Self.retryProbeTimeout : Self.firstProbeTimeout)) { [weak self] in
            guard let self, self.refreshRequestID == requestID, self.refreshGeneration == current, self.generation == current, !self.stopped else { return }
            if !retry { self.queryV2(pipe, current, requestID); self.armProbeDeadlineV2(pipe, current, requestID, retry: true); return }
            self.refreshGeneration = nil; self.refreshRequestID = nil
            self.lost(current, reason: "v2 presence query unanswered for \(Int(Self.firstProbeTimeout + Self.retryProbeTimeout))s")
        }
    }
    private func queryV2(_ pipe: RelayV2Pipe, _ current: Int, _ requestID: UUID) {
        Task { [weak self] in
            let peers = try? await pipe.peers(timeoutSeconds: Self.retryProbeTimeout)
            guard let self else { return }
            self.queue.async { if self.refreshRequestID == requestID, peers != nil { self.refreshGeneration = nil; self.refreshRequestID = nil } }
            guard let peers else { return }
            self.queue.async {
                guard current == self.generation, !self.stopped else { return }
                self.reconcilePresenceV2(peers, pipe: pipe, current: current)
            }
        }
    }
    private func reconcilePresenceV2(_ peers: [String], pipe: RelayV2Pipe, current: Int) {
        let online = Set(peers)
        let access = Access.parse(token)
        let ownDevice = access?.device
        let trusted = access?.trusted_peers
        liveOnlinePeers = online
        for existing in Array(metadata.keys) where !online.contains(existing) {
            metadata.removeValue(forKey: existing)
            bridges.removeValue(forKey: existing)?.close()
            callbacks.removeValue(forKey: existing)
            pendingV2.removeValue(forKey: existing)
            opening.remove(existing)
        }
        for peer in peers {
            guard peer != ownDevice, trusted?[peer] != nil else { continue }
            if metadata[peer] == nil { onPeerAvailable?() }
            announceV2(peer, pipe, current)
        }
        publishLivePresence()
        onPeers(Array(metadata.values))
    }
    private func handleV2(_ event: RelayV2PipeEvent, _ pipe: RelayV2Pipe, _ current: Int) {
        switch event.type {
        case "group.changed":
            if let object = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any],
               let entry = object["group_entry"] as? [String: Any],
               let state = try? RelayGroups.unpack(entry),
               Int(event.seq ?? 0) > (state["revision"] as? Int ?? 0) {
                membershipChecked = false
                lost(current, reason: "v2 group changed")
            }
        case "presence":
            reconcilePresenceV2(event.peers ?? [], pipe: pipe, current: current)
        case "msg":
            guard event.topic == "clipy.presence", let peer = event.from,
                  let data = try? pipe.openMessage(event),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "clipy.presence",
                  let name = object["name"] as? String,
                  let addresses = object["addresses"] as? [String], addresses.count <= 8,
                  let port = object["port"] as? Int, (1...65535).contains(port),
                  metadata.count < 7 || metadata[peer] != nil else { return }
            guard let lanID = Self.lanPeerID(relayID: peer, presence: object), lanID != id else { return }
            let first = metadata[peer] == nil
            metadata[peer] = Peer(id: lanID, name: String(name.prefix(100)), addresses: addresses, port: UInt16(port))
            liveOnlinePeers.insert(peer)
            publishLivePresence()
            if first { announceV2(peer, pipe, current) }
            onPeers(Array(metadata.values))
        case "stream.open":
            guard let peer = event.from else { return }
            let peerLanID = metadata[peer]?.id ?? Self.lanPeerID(relayID: peer, presence: [:]) ?? peer
            if bridges[peer] != nil || (opening.contains(peer) && id < peerLanID) {
                Task { await pipe.rejectStream(event) }
                return
            }
            if let old = pendingV2.removeValue(forKey: peer) {
                Task { await pipe.rejectStream(old) }
            }
            pendingV2[peer] = event
            if metadata[peer] == nil {
                metadata[peer] = Peer(
                    id: peerLanID,
                    name: peer,
                    addresses: [],
                    port: 5566
                )
            }
            onPeers(Array(metadata.values))
            begin(peer)
        default:
            break
        }
    }
    private func report(_ error: Error) {
        guard !stopped else { return }
        SyncRelayConnectionState.shared.update(SyncRelayGroups.isAuthenticationFailure(error) ? .authenticationRequired : .unavailable, owner: statusOwner)
    }
    private func announce(_ peer: String, _ connection: CommonRelay.RelayClient, _ current: Int) {
        guard Access.parse(token)?.trusted_peers[peer] != nil else { return }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "clipy.presence", "peerId": id, "name": name, "port": Int(port), "addresses": Array(addresses.prefix(8))])
        Task { _ = try? await connection.sendOnline(to: peer, data: data) }
    }
    private func refresh(_ connection: CommonRelay.RelayClient, _ current: Int) {
        onPeers(Array(metadata.values))
        guard refreshGeneration != current else { return }; refreshGeneration = current
        let requestID = UUID(); refreshRequestID = requestID
        query(connection, current, requestID)
        armProbeDeadline(connection, current, requestID, retry: false)
    }
    private func armProbeDeadline(_ connection: CommonRelay.RelayClient, _ current: Int, _ requestID: UUID, retry: Bool) {
        queue.asyncAfter(deadline: .now() + (retry ? Self.retryProbeTimeout : Self.firstProbeTimeout)) { [weak self] in
            guard let self, self.refreshRequestID == requestID, self.refreshGeneration == current, self.generation == current, !self.stopped else { return }
            if !retry { self.query(connection, current, requestID); self.armProbeDeadline(connection, current, requestID, retry: true); return }
            self.refreshGeneration = nil; self.refreshRequestID = nil
            self.lost(current, reason: "peers query unanswered for \(Int(Self.firstProbeTimeout + Self.retryProbeTimeout))s")
        }
    }
    /// Any answer for `requestID` (first or retried query) proves the session alive.
    private func query(_ connection: CommonRelay.RelayClient, _ current: Int, _ requestID: UUID) {
        Task { [weak self] in
            let peers = try? await connection.peers()
            guard let self else { return }
            self.queue.async { if self.refreshRequestID == requestID, peers != nil { self.refreshGeneration = nil; self.refreshRequestID = nil } }
            guard let peers else { return }
            self.queue.async { guard current == self.generation, !self.stopped else { return }; self.liveOnlinePeers = Set(peers.map(\.device)); for peer in peers { self.announce(peer.device, connection, current) }; self.publishLivePresence(); self.onPeers(Array(self.metadata.values)) }
        }
    }
    static func lanPeerID(relayID: String, presence: [String: Any]) -> String? {
        let raw = presence["peerId"] ?? relayID
        guard let value = raw as? String, UUID(uuidString: value) != nil else { return nil }
        return value
    }
    private func handle(_ event: RelayEvent, _ connection: CommonRelay.RelayClient, _ current: Int) {
        let type = event["type"] as? String
        if type == "group.changed" {
            if let object = try? JSONSerialization.jsonObject(with:Data(token.utf8)) as? [String:Any], let entry = object["group_entry"] as? [String:Any], let state = try? RelayGroups.unpack(entry), (event["revision"] as? Int ?? 0) > (state["revision"] as? Int ?? 0) { membershipChecked = false;lost(current, reason: "group changed") };return
        }
        if type == "peer.up", let own = event["identity"] as? [String: Any], let peer = own["device"] as? String { liveOnlinePeers.insert(peer); publishLivePresence(); onPeerAvailable?();announce(peer, connection, current) }
        if type == "peer.down", let own = event["identity"] as? [String: Any], let peer = own["device"] as? String { liveOnlinePeers.remove(peer); metadata.removeValue(forKey: peer); bridges.removeValue(forKey: peer)?.close(); callbacks.removeValue(forKey: peer); pending.removeValue(forKey: peer); opening.remove(peer); publishLivePresence() }
        if type == "message", event["offline"] as? Bool != true, let peer = event["from"] as? String, let data = event["data"] as? Data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "clipy.presence",
            let name = object["name"] as? String, let addresses = object["addresses"] as? [String], addresses.count <= 8,
            let port = object["port"] as? Int, (1...65535).contains(port), metadata.count < 7 || metadata[peer] != nil {
            guard let lanID = Self.lanPeerID(relayID: peer, presence: object), lanID != id else { return }
            let first = metadata[peer] == nil; metadata[peer] = Peer(id: lanID, name: String(name.prefix(100)), addresses: addresses, port: UInt16(port)); liveOnlinePeers.insert(peer); publishLivePresence()
            if first { announce(peer, connection, current) }; onPeers(Array(metadata.values))
        }
        if type == "stream.open", let peer = event["from"] as? String {
            let peerLanID = metadata[peer]?.id ?? Self.lanPeerID(relayID: peer, presence: [:]) ?? peer
            if bridges[peer] != nil || (opening.contains(peer) && id < peerLanID) {
                Task { try? await connection.rejectStream(event) }
                return
            }
            if let old = pending.removeValue(forKey: peer) {
                Task { try? await connection.rejectStream(old) }
            }
            pending[peer] = event
            if metadata[peer] == nil { metadata[peer] = Peer(id: peerLanID, name: peer, addresses: [], port: 5566) }
            onPeers(Array(metadata.values)); begin(peer)
        }
    }
    func open(peer: String, force: Bool = false, onReady: @escaping (Int32) -> Void) {
        queue.async {
            guard let relayID = self.metadata.first(where: { $0.value.id == peer })?.key,
                  !self.stopped, self.bridges[relayID] == nil else { return }
            self.callbacks[relayID] = onReady; self.begin(relayID, force: force)
        }
    }
    private func resolveReadyCallback(for peer: String, hasIncoming: Bool) -> ((Int32) -> Void)? {
        if let callback = callbacks.removeValue(forKey: peer) { return callback }
        guard hasIncoming, let handler = onSocket, let peerMeta = metadata[peer] else { return nil }
        return { fd in handler(peerMeta, fd) }
    }
    private func hasReadyCallback(for peer: String, hasIncoming: Bool) -> Bool {
        callbacks[peer] != nil || (hasIncoming && onSocket != nil && metadata[peer] != nil)
    }
    private func begin(_ peer: String, force: Bool = false) {
        if isV2 {
            let incoming = pendingV2[peer]
            guard let pipe = v2Pipe, hasReadyCallback(for: peer, hasIncoming: incoming != nil), bridges[peer] == nil, !opening.contains(peer), !stopped else { return }
            guard force || id < (metadata[peer]?.id ?? peer) || incoming != nil else { return }
            pendingV2.removeValue(forKey: peer); opening.insert(peer); let current = generation
            Task { [weak self] in
                do {
                    let stream: RelayV2Stream
                    if let incoming { stream = try await pipe.acceptStream(incoming) } else { stream = try await pipe.openStream(to: peer, topic: "clipy.sync") }
                    guard let self else { await stream.close(); return }
                    self.queue.async {
                        self.opening.remove(peer)
                        guard !self.stopped, current == self.generation, let callback = self.resolveReadyCallback(for: peer, hasIncoming: incoming != nil) else { Task { await stream.close() }; return }
                        let bridge = RelayByteBridge(stream: stream, queue: self.queue, onReady: callback); self.bridges[peer] = bridge
                        bridge.onClose = { [weak self, weak bridge] in guard self?.bridges[peer] === bridge else { return }; self?.bridges.removeValue(forKey: peer) }
                        bridge.start()
                    }
                } catch {
                    appLog("Relay v2 stream \(incoming != nil ? "accept" : "open") failed peer=\(peer.prefix(8)): \(error)", level: .warning)
                    self?.queue.async {
                        guard let self else { return }
                        self.opening.remove(peer)
                        if self.pendingV2[peer] != nil { self.begin(peer) }
                    }
                }
            }
            return
        }
        let incoming = pending[peer]
        guard let connection = client, hasReadyCallback(for: peer, hasIncoming: incoming != nil), bridges[peer] == nil, !opening.contains(peer), !stopped else { return }
        guard force || id < (metadata[peer]?.id ?? peer) || incoming != nil else { return }
        pending.removeValue(forKey: peer); opening.insert(peer); let current = generation
        Task { [weak self] in
            do {
                let stream: RelayStream
                if let incoming { stream = try await connection.acceptStream(incoming) } else { stream = try await connection.openStream(to: peer) }
                guard let self else { await stream.close(); return }
                self.queue.async {
                    self.opening.remove(peer)
                    guard !self.stopped, current == self.generation, let callback = self.resolveReadyCallback(for: peer, hasIncoming: incoming != nil) else { Task { await stream.close() }; return }
                    let bridge = RelayByteBridge(stream: stream, queue: self.queue, onReady: callback); self.bridges[peer] = bridge
                    bridge.onClose = { [weak self, weak bridge] in guard self?.bridges[peer] === bridge else { return }; self?.bridges.removeValue(forKey: peer) }
                    bridge.start()
                }
            } catch {
                appLog("Relay v1 stream \(incoming != nil ? "accept" : "open") failed peer=\(peer.prefix(8)): \(error)", level: .warning)
                self?.queue.async {
                    guard let self else { return }
                    self.opening.remove(peer)
                    if self.pending[peer] != nil { self.begin(peer) }
                }
            }
        }
    }
    private func lost(_ current: Int, reason: String) {
        membershipChecked = false
        guard current == generation, !stopped else { return }; generation += 1
        reconnects += 1
        let uptime = connectedAt.map { " after \(Int(Date().timeIntervalSince($0)))s" } ?? " (not connected)"
        appLog("Relay: lost\(uptime), reason=\(reason); retry in \(Int(backoff))s (reconnects=\(reconnects))", level: .warning)
        connectedAt = nil
        SyncRelayConnectionState.shared.disconnected(statusOwner)
        timer?.cancel(); timer = nil; metadata.removeAll(); liveOnlinePeers.removeAll(); pending.removeAll(); pendingV2.removeAll(); callbacks.removeAll(); opening.removeAll()
        for bridge in Array(bridges.values) { bridge.close() }; bridges.removeAll()
        if let connection = client { Task { await connection.close() } }; client = nil
        if let pipe = v2Pipe { Task { await pipe.close() } }; v2Pipe = nil
        let work = DispatchWorkItem { [weak self] in self?.connect() }; retry = work; queue.asyncAfter(deadline: .now() + backoff, execute: work); backoff = min(backoff * 2, 30)
    }
    func stop() { queue.async { self.stopped = true; SyncRelayConnectionState.shared.end(self.statusOwner); self.generation += 1; self.retry?.cancel(); self.timer?.cancel(); self.runTask?.cancel(); if let client = self.client { Task { await client.close() } }; self.client = nil; if let pipe = self.v2Pipe { Task { await pipe.close() } }; self.v2Pipe = nil; for bridge in Array(self.bridges.values) { bridge.close() }; self.bridges.removeAll(); self.liveOnlinePeers.removeAll(); self.callbacks.removeAll(); self.pending.removeAll(); self.pendingV2.removeAll() } }
}

private protocol RelayStreamAdapter: Sendable {
    func sendChunk(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}
extension CommonRelay.RelayStream: RelayStreamAdapter {
    func sendChunk(_ data: Data) async throws { try await send(data) }
}
extension CommonRelay.RelayV2Stream: RelayStreamAdapter {
    func sendChunk(_ data: Data) async throws { try await send(data) }
}

private final class RelayByteBridge: @unchecked Sendable {
    let stream: any RelayStreamAdapter, queue: DispatchQueue, onReady: (Int32) -> Void
    var onClose: (() -> Void)?
    var fd: Int32 = -1
    var source: DispatchSourceRead?
    var writer: SyncSocketWriter?
    var suspended = false, closed = false
    private var sentRecords = 0, receivedRecords = 0
    private let trace = ProcessInfo.processInfo.environment["CLIPY_RELAY_TRACE"] == "1"
    init(stream: any RelayStreamAdapter, queue: DispatchQueue, onReady: @escaping (Int32) -> Void) { self.stream = stream; self.queue = queue; self.onReady = onReady }
    func start() {
        var fds: [Int32] = [-1, -1]; guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { close(); return }; fd = fds[0]
        var one: Int32 = 1; for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        writer = SyncSocketWriter(fd: fd, queue: queue, byteLimit: 65536, timeout: 30, onFailure: { [weak self] in self?.close() })
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue); source.setEventHandler { [weak self] in self?.read() }; self.source = source; source.resume(); onReady(fds[1]); receive()
    }
    func read() {
        guard !closed else { return }; var bytes = [UInt8](repeating: 0, count: 65519); let count = Darwin.recv(fd, &bytes, bytes.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }; guard count > 0 else { close(); return }
        suspended = true; source?.suspend(); let data = Data(bytes.prefix(count))
        sentRecords += 1; if trace && sentRecords <= 12 { appLog("Relay bridge outgoing record \(sentRecords) bytes=\(count)") }
        Task { [weak self] in guard let self else { return }; do { try await self.stream.sendChunk(data); self.queue.async { guard !self.closed else { return }; self.suspended = false; self.source?.resume() } } catch { self.queue.async { self.close() } } }
    }
    func receive() {
        Task { [weak self] in guard let self else { return }; do { let data = try await self.stream.receive(); self.queue.async { guard !self.closed else { return }; guard !data.isEmpty else { self.close(); return }; self.receivedRecords += 1; if self.trace && self.receivedRecords <= 12 { appLog("Relay bridge incoming record \(self.receivedRecords) bytes=\(data.count)") }; self.writer?.enqueue(data) { [weak self] ok in guard let self, !self.closed else { return }; if ok { self.receive() } else { self.close() } } } } catch { self.queue.async { self.close() } } }
    }
    func close() {
        guard !closed else { return }; closed = true; Task { await stream.close() }
        let fd = self.fd
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); let group = DispatchGroup()
            if let source { group.enter(); source.setCancelHandler { group.leave() }; source.cancel(); if suspended { suspended = false; source.resume() }; self.source = nil }
            if let writer { group.enter(); writer.cancel { group.leave() }; self.writer = nil }; group.notify(queue: queue) { Darwin.close(fd) }; self.fd = -1
        }; onClose?()
    }
}
