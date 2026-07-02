import Foundation

enum CollectorCategory: String, CaseIterable, Codable {
    case notification
    case sms
    case call
    case callLog = "call_log"
    case clipboard
    case location
    case system

    var displayNameKey: L10nKey {
        switch self {
        case .notification: return .collectorCategoryNotification
        case .sms: return .collectorCategorySms
        case .call: return .collectorCategoryCall
        case .callLog: return .collectorCategoryCallLog
        case .clipboard: return .collectorCategoryClipboard
        case .location: return .collectorCategoryLocation
        case .system: return .collectorCategorySystem
        }
    }
}

struct CollectorEvent: Codable, Identifiable {
    let id: String
    let category: String
    let timestamp: TimeInterval
    let deviceId: String
    let payload: [String: String]

    var collectorCategory: CollectorCategory? {
        CollectorCategory(rawValue: category)
    }

    init(id: String, category: String, timestamp: TimeInterval, deviceId: String, payload: [String: String]) {
        self.id = id
        self.category = category
        self.timestamp = timestamp
        self.deviceId = deviceId
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        if let stringPayload = try? container.decode([String: String].self, forKey: .payload) {
            payload = stringPayload
        } else if let dynamicPayload = try? container.decode([String: CollectorPayloadValue].self, forKey: .payload) {
            payload = dynamicPayload.mapValues { $0.stringValue }
        } else {
            payload = [:]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, timestamp, deviceId, payload
    }
}

private enum CollectorPayloadValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}

extension Notification.Name {
    static let deviceCollectorEventsDidChange = Notification.Name("deviceCollectorEventsDidChange")
}
