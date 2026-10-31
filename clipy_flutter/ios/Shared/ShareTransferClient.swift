import Foundation
import Network
import CryptoKit

enum ShareTransferLimits {
  static let fileBytes: Int64 = 1024 * 1024 * 1024
  static let stagingBytes: Int64 = 4 * fileBytes
  static let diskReserve: Int64 = 64 * 1024 * 1024
  static let chunkBytes = 1024 * 1024
}

struct SharePeer: Codable, Equatable {
  let peerId: String
  let name: String
  let host: String
  let port: UInt16
}

enum ShareTransferError: Error, Equatable {
  case cancelled, timeout, connection, invalidFrame, wrongDevice, tooLarge
  case rejected(String), sourceChanged
}

/// Owns only connections in one visible share/refresh operation. Closing the
/// extension cancels pending connects, reads and writes without waiting on UI.
final class ShareCancellation {
  private let lock = NSLock()
  private var cancelled = false
  private var connections: [UUID: NWConnection] = [:]
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func check() throws { if isCancelled { throw ShareTransferError.cancelled } }
  func register(_ connection: NWConnection) throws -> UUID {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { throw ShareTransferError.cancelled }
    let id = UUID(); connections[id] = connection; return id
  }
  func remove(_ id: UUID) { lock.lock(); connections.removeValue(forKey: id); lock.unlock() }
  func cancel() {
    lock.lock(); cancelled = true; let active = Array(connections.values); connections.removeAll(); lock.unlock()
    active.forEach { $0.cancel() }
  }
}

private final class ShareResult<Value> {
  private let condition = NSCondition()
  private var result: Result<Value, Error>?
  func finish(_ value: Result<Value, Error>) {
    condition.lock(); defer { condition.unlock() }
    guard result == nil else { return }
    result = value; condition.broadcast()
  }
  func peek() throws -> Value? {
    condition.lock(); defer { condition.unlock() }
    return try result?.get()
  }
  func wait(seconds: TimeInterval, cancellation: ShareCancellation) throws -> Value {
    condition.lock(); defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(seconds)
    while result == nil {
      try cancellation.check()
      guard Date() < deadline else { throw ShareTransferError.timeout }
      _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
    }
    try cancellation.check()
    return try result!.get()
  }
}

private final class ShareSocket {
  let cancellation: ShareCancellation
  private let connection: NWConnection
  private let id: UUID
  private let writes = NSLock()
  init(host: String, port: UInt16, cancellation: ShareCancellation, timeout: TimeInterval) throws {
    self.cancellation = cancellation
    connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    id = try cancellation.register(connection)
    let ready = ShareResult<Bool>()
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: ready.finish(.success(true))
      case .failed: ready.finish(.failure(ShareTransferError.connection))
      case .cancelled: ready.finish(.failure(ShareTransferError.cancelled))
      default: break
      }
    }
    connection.start(queue: .global(qos: .userInitiated))
    do { _ = try ready.wait(seconds: timeout, cancellation: cancellation) }
    catch { connection.cancel(); cancellation.remove(id); throw error }
  }
  deinit { close() }
  func close() { connection.cancel(); cancellation.remove(id) }
  func send(_ frame: [String: Any]) throws {
    let body = try JSONSerialization.data(withJSONObject: frame)
    guard !body.isEmpty, body.count <= 2 * 1024 * 1024 else { throw ShareTransferError.invalidFrame }
    var size = UInt32(body.count).bigEndian
    var data = Data(bytes: &size, count: 4); data.append(body)
    writes.lock(); defer { writes.unlock() }
    try cancellation.check()
    let result = ShareResult<Bool>()
    connection.send(content: data, completion: .contentProcessed { error in
      result.finish(error == nil ? .success(true) : .failure(ShareTransferError.connection))
    })
    _ = try result.wait(seconds: 120, cancellation: cancellation)
  }
  private func read(_ count: Int, timeout: TimeInterval) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    var bytes = Data()
    while bytes.count < count {
      try cancellation.check()
      let result = ShareResult<Data>()
      connection.receive(minimumIncompleteLength: 1, maximumLength: count - bytes.count) { data, _, complete, error in
        if let data, !data.isEmpty { result.finish(.success(data)) }
        else if complete || error != nil { result.finish(.failure(ShareTransferError.connection)) }
        else { result.finish(.failure(ShareTransferError.invalidFrame)) }
      }
      bytes.append(try result.wait(seconds: max(0, deadline.timeIntervalSinceNow), cancellation: cancellation))
    }
    return bytes
  }
  func receive(timeout: TimeInterval = 120) throws -> [String: Any] {
    let header = try read(4, timeout: timeout)
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= 2 * 1024 * 1024 else { throw ShareTransferError.invalidFrame }
    guard let frame = try JSONSerialization.jsonObject(with: read(length, timeout: timeout)) as? [String: Any],
          frame["v"] as? Int == 3 else { throw ShareTransferError.invalidFrame }
    return frame
  }
}

/// A one-shot v3 client, not another sync service. Independent peer identity
/// prevents an extension connection from replacing the main app's live session.
final class ShareTransferClient {
  private static let key = SymmetricKey(data: SHA256.hash(data: Data("ClipySyncSecret2026".utf8)))
  let identity: String
  let name: String
  init(identity: String = UUID().uuidString, name: String) { self.identity = identity; self.name = name }

  private func envelope(_ type: String, msgId: String = UUID().uuidString, payload: String? = nil) -> [String: Any] {
    var frame: [String: Any] = ["v": 3, "type": type, "peerId": identity, "name": name,
      "port": 0, "msgId": msgId, "ts": Date().timeIntervalSince1970]
    if let payload { frame["payload"] = payload }
    return frame
  }
  private func handshake(_ socket: ShareSocket, host: String, port: UInt16, timeout: TimeInterval) throws -> SharePeer {
    try socket.send(envelope("hello"))
    let reply = try socket.receive(timeout: timeout)
    guard let type = reply["type"] as? String, ["hello", "welcome"].contains(type),
          let peerId = reply["peerId"] as? String, !peerId.isEmpty, peerId != identity else { throw ShareTransferError.invalidFrame }
    if type == "hello" { try socket.send(envelope("welcome")) }
    let advertised = reply["port"] as? Int ?? Int(port)
    guard (1...65535).contains(advertised) else { throw ShareTransferError.invalidFrame }
    return SharePeer(peerId: peerId, name: String((reply["name"] as? String ?? host).prefix(100)), host: host, port: UInt16(advertised))
  }
  func probe(host: String, port: UInt16, cancellation: ShareCancellation) throws -> SharePeer {
    guard port > 0 else { throw ShareTransferError.connection }
    let socket = try ShareSocket(host: host, port: port, cancellation: cancellation, timeout: 1.5)
    defer { socket.close() }
    return try handshake(socket, host: host, port: port, timeout: 2)
  }
  private func seal(_ data: Data) throws -> String {
    guard let combined = try AES.GCM.seal(data, using: Self.key).combined else { throw ShareTransferError.invalidFrame }
    return combined.base64EncodedString()
  }
  private func open(_ frame: [String: Any]) throws -> [String: Any] {
    guard let payload = frame["payload"] as? String, let combined = Data(base64Encoded: payload),
          let value = try JSONSerialization.jsonObject(with: AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: Self.key)) as? [String: Any]
    else { throw ShareTransferError.invalidFrame }
    return value
  }

  func send(file: URL, to peer: SharePeer, cancellation: ShareCancellation,
            progress: @escaping (Double) -> Void) throws {
    guard peer.port > 0 else { throw ShareTransferError.connection }
    let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    guard size <= ShareTransferLimits.fileBytes else { throw ShareTransferError.tooLarge }
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var digest = SHA256()
    var hashed: Int64 = 0
    while true {
      try cancellation.check()
      let count: Int = try autoreleasepool {
        guard let data = try input.read(upToCount: ShareTransferLimits.chunkBytes), !data.isEmpty else { return 0 }
        digest.update(data: data); return data.count
      }
      if count == 0 { break }
      hashed += Int64(count)
      guard hashed <= size else { throw ShareTransferError.sourceChanged }
    }
    guard hashed == size else { throw ShareTransferError.sourceChanged }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    try input.seek(toOffset: 0)
    let socket = try ShareSocket(host: peer.host, port: peer.port, cancellation: cancellation, timeout: 8)
    defer { socket.close() }
    let remote = try handshake(socket, host: peer.host, port: peer.port, timeout: 8)
    guard remote.peerId == peer.peerId else { throw ShareTransferError.wrongDevice }
    let fileId = UUID().uuidString
    let acknowledgement = ShareResult<Bool>()
    // One reader handles keepalive and early rejection while the bounded writer streams.
    let readerDone = DispatchGroup()
    readerDone.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { readerDone.leave() }
      do {
        while true {
          let frame = try socket.receive()
          if frame["type"] as? String == "ping" { try socket.send(self.envelope("pong")) }
          if frame["type"] as? String == "file.ack" {
            let ack = try self.open(frame)
            guard ack["fileId"] as? String == fileId else { continue }
            if ack["ok"] as? Bool == true { acknowledgement.finish(.success(true)) }
            else { acknowledgement.finish(.failure(ShareTransferError.rejected(ack["error"] as? String ?? "unknown"))) }
            return
          }
        }
      } catch { acknowledgement.finish(.failure(error)) }
    }
    defer { socket.close(); _ = readerDone.wait(timeout: .now() + 1) }
    let chunks = size == 0 ? 0 : (size + Int64(ShareTransferLimits.chunkBytes) - 1) / Int64(ShareTransferLimits.chunkBytes)
    let meta: [String: Any] = ["fileId": fileId, "name": file.lastPathComponent, "size": size,
      "chunkSize": ShareTransferLimits.chunkBytes, "chunks": chunks, "sha256": hash]
    var metadata = envelope("file.meta", payload: try seal(JSONSerialization.data(withJSONObject: meta)))
    metadata["hash"] = hash
    try socket.send(metadata)
    var sent: Int64 = 0
    var lastProgress = Date.distantPast
    for index in 0..<chunks {
      try cancellation.check()
      if try acknowledgement.peek() != nil { throw ShareTransferError.invalidFrame }
      try autoreleasepool {
        guard let bytes = try input.read(upToCount: ShareTransferLimits.chunkBytes), !bytes.isEmpty else { throw ShareTransferError.sourceChanged }
        var number = UInt32(index).bigEndian
        var plain = Data(bytes: &number, count: 4); plain.append(bytes)
        try socket.send(envelope("file.chunk", msgId: fileId, payload: seal(plain)))
        sent += Int64(bytes.count)
      }
      if Date().timeIntervalSince(lastProgress) >= 0.1 { progress(Double(sent) / Double(max(size, 1))); lastProgress = Date() }
    }
    guard sent == size else { throw ShareTransferError.sourceChanged }
    _ = try acknowledgement.wait(seconds: 120, cancellation: cancellation)
    progress(1)
  }
}
