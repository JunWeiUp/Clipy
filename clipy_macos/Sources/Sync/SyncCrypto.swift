import Foundation
import CryptoKit

extension SyncManager {
    /// Transport key: the pairing secret stretched with HKDF. `nil` while the
    /// device is unpaired — there is deliberately no shipped fallback key, so
    /// an unpaired device cannot encrypt, decrypt or complete a handshake.
    var encryptionKey: SymmetricKey? {
        let secret = PreferencesManager.shared.syncPairingSecret
        guard !secret.isEmpty else { return nil }
        keyLock.lock()
        defer { keyLock.unlock() }
        if cachedKeySecret == secret, let cachedKey { return cachedKey }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Self.keyDerivationSalt,
            info: Self.keyDerivationInfo,
            outputByteCount: 32
        )
        cachedKeySecret = secret
        cachedKey = key
        return key
    }

    var isPaired: Bool { !PreferencesManager.shared.syncPairingSecret.isEmpty }

    /// Handshake proof carried in hello/welcome `payload`: the sender's peerId
    /// sealed with the pairing key. A peer holding a different secret cannot
    /// open it, so a mismatch fails the handshake instead of every later frame
    /// silently failing to decrypt.
    func pairingProof() -> String? {
        encrypt(Self.pairingProofPrefix + peerId)
    }

    /// `nil` proof = pre-proof build that already shares our secret (it still
    /// cannot decrypt anything if it doesn't), accepted for compatibility.
    func verifyPairingProof(_ proof: String?, peerId remotePeerId: String) -> Bool {
        guard let proof else { return true }
        return decrypt(proof) == Self.pairingProofPrefix + remotePeerId
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
            guard let key = encryptionKey else { return nil }
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
            guard let key = encryptionKey else { return nil }
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
            guard let key = encryptionKey else { return nil }
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
            guard let key = encryptionKey else { return nil }
            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }
}
