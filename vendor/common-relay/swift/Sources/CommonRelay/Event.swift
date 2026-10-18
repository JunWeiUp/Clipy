import Foundation

/// Immutable serialized wire value. Decoding produces a fresh, thread-local object graph.
public struct RelayEvent: Sendable {
    private let wire: Data
    private let payload: Data?
    init(_ object: [String: Any]) throws {
        var metadata = object
        payload = metadata.removeValue(forKey: "data") as? Data
        wire = try json(metadata)
    }
    public var object: [String: Any] {
        var result = (try? dictionary(wire)) ?? [:]
        if let payload { result["data"] = payload }
        return result
    }
    public subscript(_ key: String) -> Any? { key == "data" ? payload : object[key] }
}

public struct RelayDevice: Sendable {
    public let app: String, group: String, device: String, publicKey: String
    init?(_ object: [String: Any]) {
        guard let app = object["app"] as? String, let group = object["group"] as? String,
            let device = object["device"] as? String, let key = object["public_key"] as? String else { return nil }
        self.app = app; self.group = group; self.device = device; publicKey = key
    }
}
