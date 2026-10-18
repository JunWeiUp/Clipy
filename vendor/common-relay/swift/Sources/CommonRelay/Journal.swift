import Foundation
import CryptoKit

/// One owner per directory. Store under the application's private data directory.
// All state access is serialized by lock; the injected clock must also be Sendable.
public final class RelayJournal: @unchecked Sendable {
    private let directory: URL
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let retention: Int64 = 7 * 86400
    public init(directory: URL, clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        self.directory = directory; self.clock = clock
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try cleanup()
    }
    private func path(_ scope: String, _ kind: String, _ sender: String, _ id: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: [scope, kind, sender, id])
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    private func read(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw RelayError.invalid("journal record") }
        return result
    }
    private func write(_ value: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func prepare(scope: String, id: String, to: String, data: Data, ttl: Int64 = 86400, seal: (Int64) throws -> String) throws -> (String?, Int64) {
        lock.lock(); defer { lock.unlock() }
        guard ttl > 0 && ttl <= 86400 else { throw RelayError.invalid("TTL") }
        let url = try path(scope, "out", "", id), now = Int64(clock())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let record = try read(url) {
            guard record["recipient"] as? String == to, record["digest"] as? String == digest else { throw RelayError.invalid("message ID content conflict") }
            let expires = (record["expires"] as? NSNumber)?.int64Value ?? 0
            if record["status"] as? String == "received" { return (nil, expires) }
            guard record["status"] as? String == "pending", expires > now, let body = record["body"] as? String else { throw RelayError.invalid("message expired") }
            return (body, expires)
        }
        let expires = now + ttl, body = try seal(expires)
        try write(["recipient": to, "digest": digest, "body": body, "expires": expires, "purge": expires + retention, "status": "pending"], url)
        return (body, expires)
    }
    func complete(scope: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let url = try path(scope, "out", "", id)
        if var record = try read(url) { record.removeValue(forKey: "body"); record["status"] = "received"; record["purge"] = Int64(clock()) + retention; try write(record, url) }
    }
    func contains(scope: String, sender: String, id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ((try read(path(scope, "in", sender, id)))?["purge"] as? NSNumber)?.int64Value ?? 0 > Int64(clock())
    }
    func acknowledge(scope: String, sender: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let url = try path(scope, "in", sender, id)
        if let record = try read(url), let purge = record["purge"] as? NSNumber, purge.int64Value > Int64(clock()) { return }
        try write(["purge": Int64(clock()) + retention], url)
    }
    public func cleanup(batch: Int = 256) throws {
        lock.lock(); defer { lock.unlock() }
        let now = Int64(clock()); var changed = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" && url.deletingPathExtension().lastPathComponent.count == 64 {
            if changed >= batch { break }
            guard var record = try read(url), let purge = record["purge"] as? NSNumber else { throw RelayError.invalid("journal record") }
            if purge.int64Value <= now { try FileManager.default.removeItem(at: url); changed += 1 }
            else if record["status"] as? String == "pending", let expiry = record["expires"] as? NSNumber, expiry.int64Value <= now {
                record.removeValue(forKey: "body"); record["status"] = "expired"; try write(record, url); changed += 1
            }
        }
    }
}
