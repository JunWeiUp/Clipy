import CryptoKit
import Foundation
import Security

enum HistoryKeychain {
    private static let service = "com.yourdomain.ClipyClone.history-key"
    private static let account = "default"
    private static let keyFileName = ".history-encryption-key"

    private static var keyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        return appSupport.appendingPathComponent(keyFileName)
    }

    static func loadOrCreateKey() -> SymmetricKey? {
        if let key = loadKey() {
            return key
        }

        var keyData = Data(count: 32)
        let status = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess, saveKeyData(keyData) else {
            return nil
        }
        return SymmetricKey(data: keyData)
    }

    static func loadKey() -> SymmetricKey? {
        if let data = loadKeyDataFromFile() {
            return SymmetricKey(data: data)
        }
        if let data = loadKeyDataFromKeychain() {
            if saveKeyData(data) {
                deleteKeyFromKeychain()
            }
            return SymmetricKey(data: data)
        }
        return nil
    }

    private static func loadKeyDataFromFile() -> Data? {
        let url = keyFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              data.count == 32 else {
            return nil
        }
        return data
    }

    private static func saveKeyData(_ data: Data) -> Bool {
        let url = keyFileURL
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func loadKeyDataFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    private static func deleteKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
