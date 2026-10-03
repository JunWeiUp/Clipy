import Foundation
import CryptoKit

extension SyncManager {
    /// Shared default transport key; old pairing preferences are ignored.
    /// This encrypts LAN payloads but does not authenticate a device.
    var encryptionKey: SymmetricKey { Self.defaultEncryptionKey }

    func encodeFrame(_ env: SyncEnvelope) -> Data? {
        SyncCodec.encodeFrame(env, maxFrameLength: Self.maxFrameLength)
    }

    func decodeEnvelope(_ data: Data) -> SyncEnvelope? {
        SyncCodec.decodeEnvelope(data)
    }

    func encrypt(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            let key = encryptionKey
            let iv = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: key, nonce: iv)
            var combined = Data(iv)
            combined.append(sealed.ciphertext)
            combined.append(sealed.tag)
            return combined.base64EncodedString()
        } catch {
            return nil
        }
    }

    func decrypt(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count > 28 else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: data.prefix(12))
            let tag = data.suffix(16)
            let ciphertext = data.dropFirst(12).dropLast(16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let key = encryptionKey
            let plain = try AES.GCM.open(box, using: key)
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Binary variant of `encrypt(_:)` for file chunks. Wire form is the same
    /// `base64(nonce12 ‖ ciphertext ‖ tag)` so it interops with the Dart side.
    func encryptBytes(_ data: Data) -> String? {
        do {
            let key = encryptionKey
            let iv = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: key, nonce: iv)
            var combined = Data(iv)
            combined.append(sealed.ciphertext)
            combined.append(sealed.tag)
            return combined.base64EncodedString()
        } catch {
            return nil
        }
    }

    func decryptToBytes(_ base64: String) -> Data? {
        guard let data = Data(base64Encoded: base64), data.count > 28 else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: data.prefix(12))
            let tag = data.suffix(16)
            let ciphertext = data.dropFirst(12).dropLast(16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let key = encryptionKey
            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }
}
