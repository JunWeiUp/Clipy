import Foundation
import Security
import LocalAuthentication

/// Mac-local credential storage; no phone control secret is required.
enum ScreenControlSecurity {
    static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }
    static func save(_ data: Data?, account: String) throws {
        let query = baseQuery(account)
        var status: OSStatus
        if let data {
            let attributes: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
        } else {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.clipyclone.screen-control.v1", kSecAttrAccount as String: account]
    }
}

/// Per-session duplicate suppression, not authentication. Connected peers may control.
struct ScreenControlChallenge {
    let token: String
    let issued: Date
    private(set) var consumed = false
    init(token: String = UUID().uuidString, issued: Date = Date()) {
        self.token = token; self.issued = issued
    }
    mutating func consume(token: String, action: String, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(issued)
        guard !consumed, age >= 0, age < 120, token == self.token,
              ["lock", "unlock"].contains(action) else { return false }
        consumed = true
        return true
    }
}

/// Rate-limit credential submissions only. Locking must never delay unlocking.
struct ScreenControlAttemptGate {
    private var lastUnlock = Date.distantPast
    mutating func admit(action: String, configured: Bool, busy: Bool, locked: Bool?, helper: Bool, now: Date = Date()) -> String? {
        guard ["lock", "unlock"].contains(action) else { return "invalidAction" }
        guard !busy else { return "busy" }
        guard configured else { return "notConfigured" }
        guard let locked else { return "sessionUnavailable" }
        if (action == "lock" && locked) || (action == "unlock" && !locked) { return "ok" }
        if action == "unlock" {
            guard helper else { return "accessibilityRequired" }
            guard now.timeIntervalSince(lastUnlock) >= 5 else { return "cooldown" }
            lastUnlock = now
        }
        return nil
    }
}

struct ScreenControlUnlockError: Error {
    let stage: String
    var status: Int32? = nil
    var result: String {
        switch stage {
        case "accessibility": return "accessibilityRequired"
        case "credential": return "credentialInvalid"
        case "write-secure-field": return "secureFieldWriteFailed"
        case "confirm-secure-field": return "secureConfirmFailed"
        default: return "secureFieldUnavailable"
        }
    }
}
