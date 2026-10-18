import Foundation
import CryptoKit

public struct PreparedRelayFile: Sendable {
    private let record: RelayEvent
    public var descriptor: [String: Any] { record.object }
    public let ciphertext: URL
    public init(descriptor: [String: Any], ciphertext: URL) throws { record = try RelayEvent(descriptor); self.ciphertext = ciphertext }
}

public enum RelayFileCrypto {
    public static func prepare(identity: RelayIdentity, to: String, source: URL, ciphertext: URL, metadata: [String: Any]) throws -> PreparedRelayFile {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), enc = try SecretStream()
        guard !FileManager.default.fileExists(atPath: ciphertext.path), FileManager.default.createFile(atPath: ciphertext.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RelayError.invalid("staging file") }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: ciphertext)
        defer { try? input.close(); try? output.close() }
        var sequence: UInt64 = 0, size = 0, hash = SHA256()
        while true {
            let plain = try input.read(upToCount: 65519) ?? Data()
            let cipher = try enc.push(plain, aad: identity.aad(from: identity.device, to: to, kind: "file", id: id, sequence: sequence), final: plain.isEmpty)
            var length = UInt32(cipher.count).bigEndian, record = Data(); withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }; record.append(cipher)
            try output.write(contentsOf: record); hash.update(data: record); size += record.count; sequence += 1
            if plain.isEmpty { break }
        }
        try output.synchronize()
        var privateDescriptor = enc.descriptor; privateDescriptor["metadata"] = metadata
        let descriptor: [String: Any] = ["id": id, "to": to, "size": size, "sha256": Data(hash.finalize()).relayHex, "metadata": try identity.seal(to: to, kind: "file", id: id, value: privateDescriptor)]
        return try PreparedRelayFile(descriptor: descriptor, ciphertext: ciphertext)
    }
    public static func decrypt(identity: RelayIdentity, from: String, descriptor: [String: Any], ciphertext: URL, destination: URL) throws -> [String: Any] {
        guard let id = descriptor["id"] as? String, let body = descriptor["metadata"] as? String, let expected = descriptor["sha256"] as? String, !FileManager.default.fileExists(atPath: destination.path) else { throw RelayError.invalid("file descriptor or destination") }
        let wrapped = try identity.open(from: from, kind: "file", id: id, body: body), stream = try SecretStream(descriptor: identity.open(from: from, kind: "file", id: id, body: body))
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RelayError.invalid("temporary file") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: ciphertext), output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(), sequence: UInt64 = 0
        while let prefix = try input.read(upToCount: 4), !prefix.isEmpty {
            guard prefix.count == 4 else { throw RelayError.invalid("truncated record") }
            let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
            guard (17...65536).contains(size), let cipher = try input.read(upToCount: size), cipher.count == size else { throw RelayError.invalid("record size") }
            hash.update(data: prefix); hash.update(data: cipher)
            let plain = try stream.pull(cipher, aad: identity.aad(from: from, to: identity.device, kind: "file", id: id, sequence: sequence))
            try output.write(contentsOf: plain); sequence += 1
        }
        guard stream.finished, Data(hash.finalize()).relayHex == expected else { throw RelayError.invalid("incomplete or corrupt file") }
        try output.synchronize(); try output.close()
        try FileManager.default.linkItem(at: temporary, to: destination)
        return wrapped["metadata"] as? [String: Any] ?? [:]
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor RelayFiles {
    private let base: URL, token: String
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    public init(base: URL, token: String, allowLocalTest: Bool = false) throws {
        guard base.scheme == "https" || (allowLocalTest && base.scheme == "http" && base.host == "127.0.0.1") else { throw RelayError.invalid("HTTPS required") }
        self.base = base; self.token = token
    }
    private func request(_ method: String, path: String = "", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: path.isEmpty ? base : base.appendingPathComponent(path)); request.httpMethod = method; request.timeoutInterval = 60; request.httpBody = body; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RelayError.invalid("response") }; return (data, response.statusCode)
    }
    public func upload(_ file: PreparedRelayFile) async throws -> RelayEvent {
        guard let id = file.descriptor["id"] as? String else { throw RelayError.invalid("id") }
        var (data, code) = try await request("POST", body: json(file.descriptor))
        if code == 409 { (data, code) = try await request("GET", path: id) }
        guard code == 200 || code == 201 else { throw RelayError.invalid("file admission \(code)") }
        let existing = try dictionary(data)
        for field in ["id", "to", "size", "sha256", "metadata"] { guard let a = existing[field], let b = file.descriptor[field], try json([a]) == json([b]) else { throw RelayError.invalid("upload conflict") } }
        var offset = (existing["offset"] as? NSNumber)?.uint64Value ?? 0
        let input = try FileHandle(forReadingFrom: file.ciphertext); defer { try? input.close() }; try input.seek(toOffset: offset)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            let (response, status) = try await request("PUT", path: id + "/data", body: chunk, headers: ["Upload-Offset": String(offset)])
            guard status == 200, let next = try dictionary(response)["offset"] as? NSNumber else { throw RelayError.invalid("upload failed \(status)") }; offset = next.uint64Value
        }
        let (response, status) = try await request("POST", path: id + "/commit"); guard status == 200 else { throw RelayError.invalid("commit failed") }; return try RelayEvent(dictionary(response))
    }
    public func inbox() async throws -> [RelayEvent] { let (data, code) = try await request("GET"); guard code == 200, let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw RelayError.invalid("file inbox") }; return try files.map(RelayEvent.init) }
    public func download(id: String, ciphertext: URL) async throws {
        // Range-bounded requests keep memory independent of total file size.
        let (raw, code) = try await request("GET", path: id); guard code == 200, let size = try dictionary(raw)["size"] as? NSNumber else { throw RelayError.invalid("file metadata") }
        if !FileManager.default.fileExists(atPath: ciphertext.path) { FileManager.default.createFile(atPath: ciphertext.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: ciphertext); defer { try? output.close() }; var offset = try output.seekToEnd()
        while offset < size.uint64Value {
            let end = min(size.uint64Value - 1, offset + (1 << 20) - 1)
            let (chunk, status) = try await request("GET", path: id + "/data", headers: ["Range": "bytes=\(offset)-\(end)"])
            guard status == 206, chunk.count == Int(end - offset + 1) else { throw RelayError.invalid("range download") }; try output.write(contentsOf: chunk); offset += UInt64(chunk.count)
        }
        try output.synchronize()
    }
    public func acknowledge(id: String) async throws { let (_, code) = try await request("DELETE", path: id); guard code == 204 else { throw RelayError.invalid("file acknowledgement") } }
    public func close() { session.invalidateAndCancel() }
}
