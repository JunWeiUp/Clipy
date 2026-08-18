import Foundation
import CryptoKit

extension SyncManager {
    /// Transport key. A user-configured pairing secret is stretched with HKDF;
    /// with no secret set we keep the legacy SHA256(shipped secret) so devices
    /// that have not been re-paired keep syncing.
    var encryptionKey: SymmetricKey {
        let secret = PreferencesManager.shared.syncPairingSecret
        keyLock.lock()
        defer { keyLock.unlock() }
        if cachedKeySecret == secret, let cachedKey { return cachedKey }
        let key: SymmetricKey
        if secret.isEmpty {
            key = SymmetricKey(data: SHA256.hash(data: Data(Self.legacySharedSecret.utf8)))
        } else {
            key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                salt: Self.keyDerivationSalt,
                info: Self.keyDerivationInfo,
                outputByteCount: 32
            )
        }
        cachedKeySecret = secret
        cachedKey = key
        return key
    }

    /// Drops the derived-key cache so a secret change takes effect immediately.
    func invalidateKeyCache() {
        keyLock.lock()
        cachedKeySecret = nil
        cachedKey = nil
        keyLock.unlock()
    }

    func encodeFrame(_ env: SyncEnvelope) -> Data? {
        SyncCodec.encodeFrame(env, maxFrameLength: Self.maxFrameLength)
    }

    func decodeEnvelope(_ data: Data) -> SyncEnvelope? {
        SyncCodec.decodeEnvelope(data)
    }

    func encrypt(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            let iv = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: encryptionKey, nonce: iv)
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
            let plain = try AES.GCM.open(box, using: encryptionKey)
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Binary variant of `encrypt(_:)` for file chunks. Wire form is the same
    /// `base64(nonce12 ‖ ciphertext ‖ tag)` so it interops with the Dart side.
    func encryptBytes(_ data: Data) -> String? {
        do {
            let iv = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: encryptionKey, nonce: iv)
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
            return try AES.GCM.open(box, using: encryptionKey)
        } catch {
            return nil
        }
    }
}
