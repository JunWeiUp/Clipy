import CryptoKit
import Foundation

enum SecureStorageCrypto {
    enum CryptoError: Error {
        case invalidPayload
    }

    static func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        return Data(nonce) + sealedBox.ciphertext + sealedBox.tag
    }

    static func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        guard data.count > 28 else {
            if let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) {
                return opened
            }
            throw CryptoError.invalidPayload
        }

        let nonce = try AES.GCM.Nonce(data: data.prefix(12))
        let tag = data.suffix(16)
        let ciphertext = data[12..<(data.count - 16)]
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }
}
