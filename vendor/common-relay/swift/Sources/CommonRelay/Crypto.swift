import Foundation
import Clibsodium

public enum RelayError: Error { case invalid(String), closed, backpressure }
public extension Data {
    init(relayHex: String) throws {
        guard relayHex.count % 2 == 0 else { throw RelayError.invalid("hex") }
        var result = Data(); var index = relayHex.startIndex
        while index < relayHex.endIndex { let end = relayHex.index(index, offsetBy: 2); guard let b = UInt8(relayHex[index..<end], radix: 16) else { throw RelayError.invalid("hex") }; result.append(b); index = end }
        self = result
    }
    var relayHex: String { map { String(format: "%02x", $0) }.joined() }
}
func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
func dictionary(_ data: Data) throws -> [String: Any] { guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RelayError.invalid("object") }; return value }
func checked(_ code: Int32) throws { guard code == 0 else { throw RelayError.invalid("cryptographic verification") } }

public struct RelayIdentity: Sendable {
    public let app: String, group: String, device: String
    private let secret: [UInt8], trusted: [String: Data]
    public init(app: String, group: String, device: String, secretKey: Data, trustedPeers: [String: Data]) throws {
        guard secretKey.count == 32, trustedPeers.values.allSatisfy({ $0.count == 32 }), sodium_init() >= 0 else { throw RelayError.invalid("key") }
        self.app = app; self.group = group; self.device = device; secret = Array(secretKey); trusted = trustedPeers
    }
    public static func generateSecretKey() -> Data { var data = [UInt8](repeating: 0, count: 32); randombytes_buf(&data, 32); return Data(data) }
    public var publicKey: Data { var out = [UInt8](repeating: 0, count: 32); crypto_scalarmult_base(&out, secret); return Data(out) }
    func context(from: String, to: String, kind: String, id: String) -> [Any] { [1, app, group, from, to, kind, id] }
    func aad(from: String, to: String, kind: String = "stream", id: String, sequence: UInt64) throws -> Data { try json(context(from: from, to: to, kind: kind, id: id) + [sequence]) }
    public func seal(to: String, kind: String, id: String, value: [String: Any]) throws -> String {
        guard let peer = trusted[to] else { throw RelayError.invalid("untrusted peer") }
        let plain = try json(["context": context(from: device, to: to, kind: kind, id: id), "value": value])
        var nonce = [UInt8](repeating: 0, count: 24); randombytes_buf(&nonce, 24)
        var cipher = [UInt8](repeating: 0, count: plain.count + 16)
        try checked(crypto_box_easy(&cipher, Array(plain), UInt64(plain.count), nonce, Array(peer), secret))
        return Data(nonce + cipher).base64EncodedString()
    }
    public func open(from: String, kind: String, id: String, body: String) throws -> [String: Any] {
        guard let peer = trusted[from], let raw = Data(base64Encoded: body), raw.count >= 40 else { throw RelayError.invalid("envelope") }
        let cipher = Array(raw.dropFirst(24)); var plain = [UInt8](repeating: 0, count: cipher.count - 16)
        try checked(crypto_box_open_easy(&plain, cipher, UInt64(cipher.count), Array(raw.prefix(24)), Array(peer), secret))
        let value = try dictionary(Data(plain))
        guard let bound = value["context"], try json(bound) == json(context(from: from, to: device, kind: kind, id: id)), let result = value["value"] as? [String: Any] else { throw RelayError.invalid("context mismatch") }
        return result
    }
}

final class SecretStream {
    private var state = crypto_secretstream_xchacha20poly1305_state()
    private var key: [UInt8], header: [UInt8]
    private let writer: Bool
    private(set) var finished = false
    init() throws {
        writer = true; key = Array(RelayIdentity.generateSecretKey()); header = [UInt8](repeating: 0, count: 24)
        try checked(crypto_secretstream_xchacha20poly1305_init_push(&state, &header, key))
    }
    init(descriptor: [String: Any]) throws {
        guard let k = descriptor["key"] as? String, let h = descriptor["header"] as? String else { throw RelayError.invalid("stream descriptor") }
        key = Array(try Data(relayHex: k)); header = Array(try Data(relayHex: h)); writer = false
        guard key.count == 32, header.count == 24 else { throw RelayError.invalid("stream key") }
        try checked(crypto_secretstream_xchacha20poly1305_init_pull(&state, header, key))
    }
    var descriptor: [String: Any] { ["key": Data(key).relayHex, "header": Data(header).relayHex] }
    func push(_ plain: Data, aad: Data, final: Bool) throws -> Data {
        guard writer, !finished, plain.count <= 65519 else { throw RelayError.invalid("stream state") }
        var out = [UInt8](repeating: 0, count: plain.count + 17)
        try checked(crypto_secretstream_xchacha20poly1305_push(&state, &out, nil, Array(plain), UInt64(plain.count), Array(aad), UInt64(aad.count), final ? 3 : 0)); finished = final
        return Data(out)
    }
    func pull(_ cipher: Data, aad: Data) throws -> Data {
        guard !writer, !finished, (17...65536).contains(cipher.count) else { throw RelayError.invalid("stream state") }
        var out = [UInt8](repeating: 0, count: cipher.count - 17); var tag: UInt8 = 0
        try checked(crypto_secretstream_xchacha20poly1305_pull(&state, &out, nil, &tag, Array(cipher), UInt64(cipher.count), Array(aad), UInt64(aad.count)))
        guard tag == 0 || tag == 3 else { throw RelayError.invalid("stream tag") }; finished = tag == 3; return Data(out)
    }
    deinit { sodium_memzero(&state, MemoryLayout.size(ofValue: state)); key.withUnsafeMutableBytes { sodium_memzero($0.baseAddress, $0.count) } }
}
