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
    private let port: UInt16, addresses: [String], onPeers: ([Peer]) -> Void
    private static let journal: Result<RelayJournal, Error> = Result {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try RelayJournal(directory: support.appendingPathComponent("ClipyClone/common-relay-journal", isDirectory: true))
    }
    var onPeerAvailable: (() -> Void)?
    private var refreshGeneration: Int?
    private var refreshRequestID: UUID?
    private var client: CommonRelay.RelayClient?
    private var runTask: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var generation = 0, backoff: Double = 1
    private var refreshingMembership = false
    private var membershipChecked = false
    private var stopped = false
    private var metadata: [String: Peer] = [:]
    private var bridges: [String: RelayByteBridge] = [:]
    private var pending: [String: RelayEvent] = [:]
    private var callbacks: [String: (Int32) -> Void] = [:]
    private var opening = Set<String>()
    static func validURL(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path == "/relay/v1/ws"
    }
    init(url: URL, token: String, id: String, name: String, port: UInt16, addresses: [String], onPeers: @escaping ([Peer]) -> Void) {
        self.url = url; self.token = token; self.id = id; self.name = name; self.port = port; self.addresses = addresses; self.onPeers = onPeers
    }
    func start() { queue.async { self.connect() } }
    func refreshPeers() {
        queue.async {
            guard !self.stopped else { return }
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
                    let value = try await SyncRelayGroups.refreshedConfiguration(raw,url:endpoint)
                    self?.queue.async { guard let self else { return };self.refreshingMembership = false;self.membershipChecked = true;self.token = value;self.connect() }
                } catch { self?.queue.async { guard let self else { return };self.refreshingMembership = false;self.lost(self.generation) } }
            }
            return
        }
        guard !stopped, let access = Access.parse(token), let identity = try? access.identity() else { return }
        generation += 1; let current = generation
        let journal: RelayJournal
        do { journal = try Self.journal.get() }
        catch { lost(current); return }
        let connection = CommonRelay.RelayClient(identity: identity, journal: journal); client = connection
        runTask = Task { [weak self] in
            do {
                guard let self else { return }
                let events = try await connection.connect(url: self.url, token: access.token)
                self.queue.async {
                    guard current == self.generation, !self.stopped else { return }
                    self.backoff = 1; self.refresh(connection, current)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 30, repeating: 30)
                    timer.setEventHandler { [weak self] in self?.refresh(connection, current) }; self.timer = timer; timer.resume()
                }
                for try await event in events { self.queue.async { guard current == self.generation, !self.stopped else { return }; self.handle(event, connection, current) } }
            } catch { self?.queue.async { self?.lost(current) } }
        }
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
        queue.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, self.refreshRequestID == requestID, self.refreshGeneration == current, self.generation == current, !self.stopped else { return }
            self.refreshGeneration = nil; self.lost(current)
        }
        Task { [weak self] in
            let peers = try? await connection.peers()
            guard let self else { return }
            self.queue.async { if self.refreshRequestID == requestID { self.refreshGeneration = nil; self.refreshRequestID = nil } }
            guard let peers else { return }
            self.queue.async { guard current == self.generation, !self.stopped else { return }; for peer in peers { self.announce(peer.device, connection, current) }; self.onPeers(Array(self.metadata.values)) }
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
            if let object = try? JSONSerialization.jsonObject(with:Data(token.utf8)) as? [String:Any], let entry = object["group_entry"] as? [String:Any], let state = try? RelayGroups.unpack(entry), (event["revision"] as? Int ?? 0) > (state["revision"] as? Int ?? 0) { membershipChecked = false;lost(current) };return
        }
        if type == "peer.up", let own = event["identity"] as? [String: Any], let peer = own["device"] as? String { onPeerAvailable?();announce(peer, connection, current) }
        if type == "peer.down", let own = event["identity"] as? [String: Any], let peer = own["device"] as? String { metadata.removeValue(forKey: peer); bridges.removeValue(forKey: peer)?.close(); callbacks.removeValue(forKey: peer); pending.removeValue(forKey: peer); opening.remove(peer) }
        if type == "message", event["offline"] as? Bool != true, let peer = event["from"] as? String, let data = event["data"] as? Data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "clipy.presence",
            let name = object["name"] as? String, let addresses = object["addresses"] as? [String], addresses.count <= 8,
            let port = object["port"] as? Int, (1...65535).contains(port), metadata.count < 7 || metadata[peer] != nil {
            guard let lanID = Self.lanPeerID(relayID: peer, presence: object), lanID != id else { return }
            let first = metadata[peer] == nil; metadata[peer] = Peer(id: lanID, name: String(name.prefix(100)), addresses: addresses, port: UInt16(port))
            if first { announce(peer, connection, current) }; onPeers(Array(metadata.values))
        }
        if type == "stream.open", let peer = event["from"] as? String {
            guard let lanID = metadata[peer]?.id ?? Self.lanPeerID(relayID: peer, presence: [:]), lanID < id, bridges[peer] == nil, pending[peer] == nil else { Task { try? await connection.rejectStream(event) }; return }
            pending[peer] = event
            if metadata[peer] == nil { metadata[peer] = Peer(id: lanID, name: peer, addresses: [], port: 5566) }
            onPeers(Array(metadata.values)); begin(peer)
        }
    }
    func open(peer: String, onReady: @escaping (Int32) -> Void) {
        queue.async {
            guard let relayID = self.metadata.first(where: { $0.value.id == peer })?.key,
                  !self.stopped, self.bridges[relayID] == nil else { return }
            self.callbacks[relayID] = onReady; self.begin(relayID)
        }
    }
    private func begin(_ peer: String) {
        guard let connection = client, callbacks[peer] != nil, bridges[peer] == nil, !opening.contains(peer), !stopped else { return }
        let incoming = pending[peer]
        guard id < (metadata[peer]?.id ?? peer) || incoming != nil else { return }
        pending.removeValue(forKey: peer); opening.insert(peer); let current = generation
        Task { [weak self] in
            do {
                let stream: RelayStream
                if let incoming { stream = try await connection.acceptStream(incoming) } else { stream = try await connection.openStream(to: peer) }
                guard let self else { await stream.close(); return }
                self.queue.async {
                    self.opening.remove(peer)
                    guard !self.stopped, current == self.generation, let callback = self.callbacks.removeValue(forKey: peer) else { Task { await stream.close() }; return }
                    let bridge = RelayByteBridge(stream: stream, queue: self.queue, onReady: callback); self.bridges[peer] = bridge
                    bridge.onClose = { [weak self, weak bridge] in guard self?.bridges[peer] === bridge else { return }; self?.bridges.removeValue(forKey: peer) }
                    bridge.start()
                }
            } catch { self?.queue.async { self?.opening.remove(peer) } }
        }
    }
    private func lost(_ current: Int) {
        membershipChecked = false
        guard current == generation, !stopped else { return }; generation += 1
        timer?.cancel(); timer = nil; metadata.removeAll(); pending.removeAll(); callbacks.removeAll(); opening.removeAll()
        for bridge in Array(bridges.values) { bridge.close() }; bridges.removeAll()
        if let connection = client { Task { await connection.close() } }; client = nil
        let work = DispatchWorkItem { [weak self] in self?.connect() }; retry = work; queue.asyncAfter(deadline: .now() + backoff, execute: work); backoff = min(backoff * 2, 30)
    }
    func stop() { queue.async { self.stopped = true; self.generation += 1; self.retry?.cancel(); self.timer?.cancel(); self.runTask?.cancel(); if let client = self.client { Task { await client.close() } }; self.client = nil; for bridge in Array(self.bridges.values) { bridge.close() }; self.bridges.removeAll(); self.callbacks.removeAll(); self.pending.removeAll() } }
}

private final class RelayByteBridge: @unchecked Sendable {
    let stream: RelayStream, queue: DispatchQueue, onReady: (Int32) -> Void
    var onClose: (() -> Void)?
    var fd: Int32 = -1
    var source: DispatchSourceRead?
    var writer: SyncSocketWriter?
    var suspended = false, closed = false
    private var sentRecords = 0, receivedRecords = 0
    private let trace = ProcessInfo.processInfo.environment["CLIPY_RELAY_TRACE"] == "1"
    init(stream: RelayStream, queue: DispatchQueue, onReady: @escaping (Int32) -> Void) { self.stream = stream; self.queue = queue; self.onReady = onReady }
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
        Task { [weak self] in guard let self else { return }; do { try await self.stream.send(data); self.queue.async { guard !self.closed else { return }; self.suspended = false; self.source?.resume() } } catch { self.queue.async { self.close() } } }
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
