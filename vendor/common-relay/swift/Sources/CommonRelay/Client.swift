import Foundation

/// Owns a single connection. Applications explicitly reconnect; this object never replays operations.
public actor RelayClient {
    public let identity: RelayIdentity
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<RelayEvent, Error>] = [:]
    private var requestTokens: [String: UUID] = [:]
    private var streams: [String: RelayStream] = [:]
    private var eventContinuation: AsyncThrowingStream<RelayEvent, Error>.Continuation?
    private let journal: RelayJournal?
    private var cleaner: Task<Void, Never>?
    private var scope: String { [identity.app, identity.group, identity.device].joined(separator: "/") }
    public init(identity: RelayIdentity, journal: RelayJournal? = nil) { self.identity = identity; self.journal = journal }
    public func cleanup() throws { try journal?.cleanup() }
    public func connect(url: URL, token: String, allowLocalTest: Bool = false) async throws -> AsyncThrowingStream<RelayEvent, Error> {
        guard socket == nil, url.scheme == "wss" || (allowLocalTest && url.scheme == "ws" && url.host == "127.0.0.1") else { throw RelayError.invalid("WSS required") }
        var request = URLRequest(url: url); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("common-relay.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let session = URLSession(configuration: .ephemeral); self.session = session
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 270336; self.socket = socket; socket.resume()
        do {
            let welcome = try await socket.receive(); guard case .string(let text) = welcome else { throw RelayError.invalid("welcome") }
            let object = try dictionary(Data(text.utf8))
            guard object["version"] as? Int == 1, let own = object["identity"] as? [String: Any], own["app"] as? String == identity.app, own["group"] as? String == identity.group, own["device"] as? String == identity.device, own["public_key"] as? String == identity.publicKey.relayHex else { throw RelayError.invalid("identity mismatch") }
            let events = AsyncThrowingStream<RelayEvent, Error>(bufferingPolicy: .bufferingOldest(64)) { eventContinuation = $0 }
            reader = Task { [weak self] in
                do { while !Task.isCancelled { let message = try await socket.receive(); try await self?.dispatch(message) } }
                catch { await self?.close(error: error) }
            }
            if journal != nil {
                cleaner = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 3_600_000_000_000); try await self?.cleanup() }
                        catch is CancellationError { return }
                        catch { await self?.close(error: error); return }
                    }
                }
            }
            return events
        } catch { await close(error: error); throw error }
    }
    func send(_ event: [String: Any]) async throws { guard let socket else { throw RelayError.closed }; let data = try json(event); guard data.count <= 270336, let text = String(data: data, encoding: .utf8) else { throw RelayError.invalid("frame size") }; try await socket.send(.string(text)) }
    func binary(_ data: Data) async throws { guard let socket else { throw RelayError.closed }; try await socket.send(.data(data)) }
    public func request(_ original: [String: Any]) async throws -> RelayEvent {
        var event = original; let id = event["id"] as? String ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); event["id"] = id
        guard pending[id] == nil else { throw RelayError.invalid("duplicate request") }
        let token = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation; requestTokens[id] = token
                Task { do { try await self.send(event) } catch { self.failRequest(id, error: error, token: token) } }
                Task { try? await Task.sleep(nanoseconds: 45_000_000_000); self.failRequest(id, error: RelayError.invalid("request timeout"), token: token) }
            }
        }, onCancel: { Task { await self.failRequest(id, error: CancellationError(), token: token) } })
    }
    private func failRequest(_ id: String, error: Error, token: UUID? = nil) {
        if let token, requestTokens[id] != token { return }
        requestTokens.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    /// Returns after the socket write, not server/device/business acknowledgment. Never persists or replays.
    public func sendOnline(to: String, data: Data) async throws {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body = try identity.seal(to: to, kind: "message", id: id, value: ["data": data.base64EncodedString()])
        try await send(["type": "message", "id": id, "to": to, "body": body, "offline": false])
    }
    public func message(to: String, data: Data, offline: Bool = false, id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) async throws -> RelayEvent {
        var body: String, expires: Int64 = 0
        if offline {
            guard let journal else { throw RelayError.invalid("persistent state required") }
            let prepared = try journal.prepare(scope: scope, id: id, to: to, data: data) { expiry in
                try identity.seal(to: to, kind: "message", id: id, value: ["data": data.base64EncodedString(), "expires": expiry])
            }
            guard let saved = prepared.0 else { return try RelayEvent(["type": "received", "id": id]) }
            body = saved; expires = prepared.1
        } else { body = try identity.seal(to: to, kind: "message", id: id, value: ["data": data.base64EncodedString()]) }
        let result = try await request(["type": "message", "id": id, "to": to, "body": body, "offline": offline, "expires": expires])
        if offline, result["type"] as? String == "received" { try journal?.complete(scope: scope, id: id) }
        return result
    }
    /// Call after the business transaction commits. Storage failure prevents ACK.
    public func acknowledge(id: String, from: String, offline: Bool = false) async throws {
        if offline && journal == nil { throw RelayError.invalid("persistent state required for acknowledgment") }
        try journal?.acknowledge(scope: scope, sender: from, id: id)
        _ = try await request(["type": "ack", "id": id, "from": from])
    }
    public func peers() async throws -> [RelayDevice] { let result = try await request(["type": "peers"]); return (result["devices"] as? [[String: Any]] ?? []).compactMap(RelayDevice.init) }
    public func openStream(to: String) async throws -> RelayStream {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let enc = try SecretStream(); let stream = RelayStream(client: self, peer: to, id: id, identity: identity, encryptor: enc); streams[id] = stream
        do {
            let response = try await request(["type": "stream.open", "id": id, "to": to, "body": identity.seal(to: to, kind: "stream.open", id: id, value: enc.descriptor)])
            guard let body = response["body"] as? String else { throw RelayError.invalid("stream response") }
            try await stream.setDecryptor(identity.open(from: to, kind: "stream.accept", id: id, body: body)); return stream
        } catch { await stream.close(); throw error }
    }
    public func acceptStream(_ event: RelayEvent) async throws -> RelayStream {
        guard let id = event["id"] as? String, let from = event["from"] as? String, let body = event["body"] as? String else { throw RelayError.invalid("stream request") }
        let enc = try SecretStream(); let stream = RelayStream(client: self, peer: from, id: id, identity: identity, encryptor: enc)
        try await stream.setDecryptor(identity.open(from: from, kind: "stream.open", id: id, body: body)); streams[id] = stream
        do { _ = try await request(["type": "stream.accept", "id": id, "body": identity.seal(to: from, kind: "stream.accept", id: id, value: enc.descriptor)]); return stream }
        catch { await stream.close(); throw error }
    }
    public func rejectStream(_ event: RelayEvent) async throws {
        guard let id = event["id"] as? String else { throw RelayError.invalid("stream id") }
        try await send(["type": "stream.close", "id": id])
    }
    func removeStream(_ id: String) async { streams.removeValue(forKey: id); try? await send(["type": "stream.close", "id": id]) }
    private func dispatch(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .data(let data):
            guard data.count >= 26, data.count <= 65561, data.first == 1 else { throw RelayError.invalid("binary frame") }
            let id = data.subdata(in: 1..<17).relayHex; let sequence = data[17..<25].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            try await streams[id]?.enqueue(sequence: sequence, data: data.subdata(in: 25..<data.count))
        case .string(let text):
            var e = try dictionary(Data(text.utf8)); let id = e["id"] as? String ?? ""; let type = e["type"] as? String ?? ""
            if type == "stream.credit" { guard let n = e["sequence"] as? UInt64 else { throw RelayError.invalid("credit") }; try await streams[id]?.credit(n); return }
            if type == "stream.close" { await streams.removeValue(forKey: id)?.abort(); failRequest(id, error: RelayError.closed); return }
            if type != "message", type != "stream.open", let continuation = pending.removeValue(forKey: id) { requestTokens.removeValue(forKey: id); if type == "error" { continuation.resume(throwing: RelayError.invalid(e["code"] as? String ?? "error")) } else { continuation.resume(returning: try RelayEvent(e)) }; return }
            if type == "message" {
                if e["offline"] as? Bool == true && journal == nil { throw RelayError.invalid("persistent state required for offline reception") }
                guard let from = e["from"] as? String, let body = e["body"] as? String else { throw RelayError.invalid("message") }; let plain = try identity.open(from: from, kind: "message", id: id, body: body)
                let expired = (plain["expires"] as? NSNumber).map { $0.doubleValue <= Date().timeIntervalSince1970 } ?? false
                let duplicate = try journal?.contains(scope: scope, sender: from, id: id) ?? false
                if expired || duplicate { if e["offline"] as? Bool == true { try await send(["type": "ack", "id": id, "from": from]) }; return }
                guard let encoded = plain["data"] as? String, let data = Data(base64Encoded: encoded) else { throw RelayError.invalid("payload") }; e["data"] = data }
            if ["message", "stream.open", "peer.up", "peer.down"].contains(type) { if case .dropped = eventContinuation?.yield(try RelayEvent(e)) { throw RelayError.backpressure } }
        @unknown default: throw RelayError.invalid("message type")
        }
    }
    public func close(error: Error = RelayError.closed) async {
        cleaner?.cancel(); cleaner = nil
        reader?.cancel(); reader = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; session?.invalidateAndCancel(); session = nil
        let requests = pending; pending.removeAll(); requestTokens.removeAll(); for continuation in requests.values { continuation.resume(throwing: error) }
        let old = streams; streams.removeAll(); for stream in old.values { await stream.abort() }
        eventContinuation?.finish(throwing: error); eventContinuation = nil
    }
}

public actor RelayStream {
    public let peer: String, id: String
    private let client: RelayClient, identity: RelayIdentity, encryptor: SecretStream
    private var decryptor: SecretStream?
    private var tx: UInt64 = 0, rx: UInt64 = 0, acknowledged: UInt64 = 0
    private var queue: [(UInt64, Data)] = []
    private var receiver: CheckedContinuation<(UInt64, Data), Error>?
    private var creditWaiter: CheckedContinuation<Void, Error>?
    private var closed = false, sending = false
    init(client: RelayClient, peer: String, id: String, identity: RelayIdentity, encryptor: SecretStream) { self.client = client; self.peer = peer; self.id = id; self.identity = identity; self.encryptor = encryptor }
    func setDecryptor(_ descriptor: [String: Any]) throws { decryptor = try SecretStream(descriptor: descriptor) }
    public var receivedFinal: Bool { decryptor?.finished ?? false }
    public func send(_ data: Data, final: Bool = false) async throws {
        guard !closed, !sending else { throw RelayError.invalid("concurrent send or closed stream") }; sending = true; defer { sending = false }
        for offset in stride(from: 0, to: max(1, data.count), by: 65519) {
            if tx - acknowledged >= 8 { try await withCheckedThrowingContinuation { creditWaiter = $0 }; }
            guard !closed else { throw RelayError.closed }
            let part = data.subdata(in: offset..<min(data.count, offset + 65519)); let aad = try identity.aad(from: identity.device, to: peer, id: id, sequence: tx)
            let cipher = try encryptor.push(part, aad: aad, final: final && offset + 65519 >= data.count)
            var frame = Data([1]); frame.append(try Data(relayHex: id)); var n = tx.bigEndian; withUnsafeBytes(of: &n) { frame.append(contentsOf: $0) }; frame.append(cipher); tx += 1
            try await client.binary(frame)
        }
    }
    public func receive() async throws -> Data {
        guard !closed, receiver == nil else { throw RelayError.invalid("concurrent receive or closed stream") }
        let item: (UInt64, Data)
        if queue.isEmpty { item = try await withCheckedThrowingContinuation { receiver = $0 } } else { item = queue.removeFirst() }
        guard item.0 == rx, let decryptor else { throw RelayError.invalid("stream sequence") }
        let plain = try decryptor.pull(item.1, aad: identity.aad(from: peer, to: identity.device, id: id, sequence: rx)); rx += 1
        try await client.send(["type": "stream.credit", "id": id, "sequence": rx]); return plain
    }
    func enqueue(sequence: UInt64, data: Data) throws { guard !closed else { return }; if let waiter = receiver { receiver = nil; waiter.resume(returning: (sequence, data)) } else { guard queue.count < 16 else { throw RelayError.backpressure }; queue.append((sequence, data)) } }
    func credit(_ sequence: UInt64) throws { guard sequence >= acknowledged, sequence <= tx else { throw RelayError.invalid("credit") }; acknowledged = sequence; if tx - acknowledged < 8 { creditWaiter?.resume(); creditWaiter = nil } }
    func abort() { closed = true; queue.removeAll(); receiver?.resume(throwing: RelayError.closed); receiver = nil; creditWaiter?.resume(throwing: RelayError.closed); creditWaiter = nil }
    public func close() async { abort(); await client.removeStream(id) }
}
