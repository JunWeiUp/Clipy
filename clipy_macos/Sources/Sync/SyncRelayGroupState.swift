import Foundation

/// Transport enrollment and signed member management are separate capabilities.
/// A missing management anchor must never erase an existing transport identity.
enum SyncRelayAccessPolicy {
    enum Failure: Error { case missingPassword, invalidPassword }
    static func validPassword(_ value: String) -> Bool {
        let bytes = value.utf8
        return (8...128).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
    /// Never trim credentials: whitespace is invalid, not an alternate password.
    static func validate(_ value: String) throws {
        guard !value.isEmpty else { throw Failure.missingPassword }
        guard validPassword(value) else { throw Failure.invalidPassword }
    }
    static func applying(_ password: String?, to config: [String:Any]) -> [String:Any] {
        var result = removingPasswords(config) as! [String:Any]
        if let password { result["password"] = password }
        return result
    }
    private static func removingPasswords(_ value: Any) -> Any {
        if let object = value as? [String:Any] {
            return object.filter { $0.key != "password" }.mapValues(removingPasswords)
        }
        if let values = value as? [Any] { return values.map(removingPasswords) }
        return value
    }
    static func sameRequestConfiguration(_ before: [String:Any], _ after: [String:Any]) -> Bool {
        ["url", "device", "group", "token", "secret_key", "password"].allSatisfy {
            before[$0] as? String == after[$0] as? String
        }
    }
    static func invitationPassword(url: String, configuredURL: String, supplied: String?, saved: String?) throws -> String {
        guard url == configuredURL else { throw InvitationFailure.differentRelay }
        let value = supplied ?? saved ?? ""
        guard !value.isEmpty else { throw InvitationFailure.missingPassword }
        try validate(value)
        return value
    }
    enum InvitationFailure: Error { case differentRelay, missingPassword }
    /// The SDK reports group HTTP status as a fixed message, not a typed status.
    /// Match exactly; an unrelated error containing the digits 401 is not auth.
    static func isAuthenticationMessage(_ message: String) -> Bool { message == "group HTTP 401" }
    static func invitationForExport(_ invitation: [String:Any]) -> [String:Any] {
        var result = invitation
        result.removeValue(forKey: "password")
        // The compact link intentionally carries credentials in its fragment.
        // Keep it only in secure invitation storage, never ordinary configuration.
        return result
    }
}

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
