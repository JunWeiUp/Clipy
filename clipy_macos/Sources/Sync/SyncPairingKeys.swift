import Foundation
import CryptoKit
import Security

enum SyncPairingKeys {
    private static let lock = NSLock()
    private static var cached: SymmetricKey?
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.clipy.private-sync-group", kSecAttrAccount as String: "default"] }
    static func load() throws -> SymmetricKey {
        #if CLIPY_CORE_TESTS
        if let cached { return cached }; let testKey = SymmetricKey(size: .bits256); cached = testKey; return testKey
        #else
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { let key = SymmetricKey(data: data); cached = key; return key }
        // Do not fall back to any built-in or shared key when Keychain is unavailable.
        let generated = SymmetricKey(size: .bits256)
        if status == errSecItemNotFound { let data = generated.withUnsafeBytes { Data($0) }; var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { cached = generated }
        }
        guard let cached else { throw NSError(domain: "SyncPairing", code: Int(status)) }; return cached
        #endif
    }
    static func replace(hex: String) throws {
        guard hex.count == 64 else { throw NSError(domain: "SyncPairing", code: 1) }
        var bytes = Data(); var index = hex.startIndex
        while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); guard let b = UInt8(hex[index..<next], radix: 16) else { throw NSError(domain: "SyncPairing", code: 2) }; bytes.append(b); index = next }
        lock.lock(); defer { lock.unlock() }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound { var add = query; add[kSecValueData as String] = bytes; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; status = SecItemAdd(add as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: "SyncPairing", code: Int(status)) }; cached = SymmetricKey(data: bytes)
    }
}
