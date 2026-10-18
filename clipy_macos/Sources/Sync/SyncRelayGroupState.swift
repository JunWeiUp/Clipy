import Foundation

/// Transport enrollment and signed member management are separate capabilities.
/// A missing management anchor must never erase an existing transport identity.
enum SyncRelayGroupState: Equatable {
    case unconfigured, legacy, managed
    static func classify(_ config: [String:Any]) -> Self {
        guard config["app"] as? String == "clipy",
              let group = config["group"] as? String, !group.isEmpty,
              let device = config["device"] as? String, !device.isEmpty,
              let token = config["token"] as? String, token.count >= 32,
              let secret = config["secret_key"] as? String, secret.count == 64 else { return .unconfigured }
        return config["group_entry"] is [String:Any] ? .managed : .legacy
    }
}
