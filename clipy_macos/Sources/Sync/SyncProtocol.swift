import Foundation
import Network

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
struct SyncEnvelope: Codable {
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

enum SyncType {
    static let hello = "hello"
    static let welcome = "welcome"
    static let history = "history"
    /// Device-list one-shot text send; no mutual authorization required.
    static let historyDirect = "history.direct"
    static let historyFetch = "history.fetch"
    static let notifPost = "notif.post"
    static let notifDismiss = "notif.dismiss"
    static let notifClear = "notif.clear"
    static let notifAck = "notif.ack"
    static let notifConfig = "notif.config"
    static let ping = "ping"
    static let pong = "pong"
    static let ack = "ack"
}

enum SyncCodec {
    static func encodeFrame(_ env: SyncEnvelope, maxFrameLength: Int) -> Data? {
        guard let json = try? JSONEncoder().encode(env) else { return nil }
        guard json.count <= maxFrameLength else {
            appLog(
                "Refusing to send \(env.type): frame is \(json.count / 1024)KB, limit is \(maxFrameLength / 1024)KB",
                level: .warning
            )
            return nil
        }
        var length = UInt32(json.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(json)
        return out
    }

    static func decodeEnvelope(_ data: Data) -> SyncEnvelope? {
        try? JSONDecoder().decode(SyncEnvelope.self, from: data)
    }
}
