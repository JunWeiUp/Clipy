import Foundation
import CryptoKit

// Minimal standalone stubs so SyncProtocol.swift can be tested without the full app target.
enum AppLogLevel { case debug, info, warning, error }
func appLog(_ message: String, level: AppLogLevel = .info) {}
enum AppLanguage { case zh, en }
final class PreferencesManager {
    static let shared = PreferencesManager()
    var appLanguage: AppLanguage = .en
}

private struct ProtocolV3Fixtures: Decodable {
    struct TextVector: Decodable {
        let plaintext: String
        let sealedBase64: String
    }
    struct BinaryVector: Decodable {
        let rawHex: String
        let sealedBase64: String
    }
    let version: Int
    let maxFrameLength: Int
    let defaultKeySeed: String
    let expectedKeySha256Hex: String
    let textCryptoVector: TextVector
    let binaryCryptoVector: BinaryVector
    let invalidCiphertexts: [String]
    let requiredSyncTypes: [String]
    let envelopes: [SyncEnvelope]
    let unknownFieldEnvelopeJson: String
    let legacyV2EnvelopeJson: String
}

private func assertCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("ProtocolV3ContractRegression FAILED: \(message)\n", stderr)
        exit(1)
    }
}

private func decryptWithKey(_ base64: String, key: SymmetricKey) -> Data? {
    guard let data = Data(base64Encoded: base64), data.count > 28 else { return nil }
    do {
        let nonce = try AES.GCM.Nonce(data: data.prefix(12))
        let tag = data.suffix(16)
        let ciphertext = data.dropFirst(12).dropLast(16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    } catch {
        return nil
    }
}

@main
struct ProtocolV3ContractMain {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: protocol-v3-contract-tests <path-to-fixtures.json>\n", stderr)
            exit(2)
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtures = try JSONDecoder().decode(ProtocolV3Fixtures.self, from: fixtureData)

        // 1. Version & SyncType parity
        assertCheck(SyncEnvelope.version == fixtures.version, "SyncEnvelope.version mismatch")
        let actualTypes: Set<String> = [
            SyncType.hello,
            SyncType.welcome,
            SyncType.history,
            SyncType.historyDirect,
            SyncType.historyFetch,
            SyncType.notifPost,
            SyncType.notifDismiss,
            SyncType.notifClear,
            SyncType.notifAck,
            SyncType.notifConfig,
            SyncType.ping,
            SyncType.pong,
            SyncType.ack,
            SyncType.fileMeta,
            SyncType.fileChunk,
            SyncType.fileAck
        ]
        for required in fixtures.requiredSyncTypes {
            assertCheck(actualTypes.contains(required), "Missing SyncType \(required)")
        }

        // 2. Key derivation & AES-GCM vectors
        let keyData = Data(SHA256.hash(data: Data(fixtures.defaultKeySeed.utf8)))
        let keyHex = keyData.map { String(format: "%02x", $0) }.joined()
        assertCheck(keyHex == fixtures.expectedKeySha256Hex, "Key SHA-256 mismatch")
        let key = SymmetricKey(data: keyData)

        let plainTextData = decryptWithKey(fixtures.textCryptoVector.sealedBase64, key: key)
        assertCheck(
            plainTextData.flatMap { String(data: $0, encoding: .utf8) } == fixtures.textCryptoVector.plaintext,
            "Text AES-GCM vector decryption failed"
        )

        let plainBinData = decryptWithKey(fixtures.binaryCryptoVector.sealedBase64, key: key)
        let plainBinHex = plainBinData?.map { String(format: "%02x", $0) }.joined()
        assertCheck(plainBinHex == fixtures.binaryCryptoVector.rawHex, "Binary AES-GCM vector decryption failed")

        for bad in fixtures.invalidCiphertexts {
            assertCheck(decryptWithKey(bad, key: key) == nil, "Invalid ciphertext unexpectedly decrypted")
        }

        // 3. Length-prefixed framing, unknown fields, v2 rejection, size cap
        for env in fixtures.envelopes {
            guard let frame = SyncCodec.encodeFrame(env, maxFrameLength: fixtures.maxFrameLength) else {
                assertCheck(false, "Failed to encode envelope \(env.msgId)")
                return
            }
            assertCheck(frame.count > 4, "Encoded frame too short")
            let declaredLen = frame.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let body = Data(frame.dropFirst(4))
            assertCheck(Int(declaredLen) == body.count, "Length prefix mismatch")
            guard let decoded = SyncCodec.decodeEnvelope(body) else {
                assertCheck(false, "Failed to decode envelope \(env.msgId)")
                return
            }
            assertCheck(decoded.v == env.v && decoded.type == env.type && decoded.msgId == env.msgId, "Decoded core fields mismatch")
            assertCheck(decoded.peerId == env.peerId && decoded.name == env.name && decoded.port == env.port, "Decoded peer fields mismatch")
            assertCheck(decoded.hash == env.hash && decoded.payload == env.payload && decoded.sessionPolicy == env.sessionPolicy, "Decoded payload/policy mismatch")
        }

        let unknownDecoded = SyncCodec.decodeEnvelope(Data(fixtures.unknownFieldEnvelopeJson.utf8))
        assertCheck(unknownDecoded != nil && unknownDecoded?.v == 3 && unknownDecoded?.type == SyncType.welcome, "Unknown field envelope failed to decode")

        let v2Decoded = SyncCodec.decodeEnvelope(Data(fixtures.legacyV2EnvelopeJson.utf8))
        assertCheck(v2Decoded != nil && v2Decoded?.v != SyncEnvelope.version, "Legacy v2 envelope version check failed")

        let oversized = SyncEnvelope.make(
            type: SyncType.history,
            peerId: "peer-oversized",
            payload: String(repeating: "x", count: fixtures.maxFrameLength + 1)
        )
        assertCheck(SyncCodec.encodeFrame(oversized, maxFrameLength: fixtures.maxFrameLength) == nil, "Oversized frame was not rejected")

        print("Protocol v3 contract regressions passed (Swift <-> shared fixtures).")
    }
}
