import Foundation

// Strict signed-payload scan shared byte for byte with the relay and other
// SDKs. JSON parsers disagree on duplicate keys, key case, unknown fields,
// null, number forms and lone surrogates; a signed group record must have
// exactly one reading everywhere (protocol/README.md, "严格载荷").
enum StrictPayload {
    typealias Schema = [String: (kind: Character, required: Bool)]
    static let member: Schema = ["device": ("s", true), "name": ("s", true), "public_key": ("s", true), "signing_key": ("s", true), "manager": ("b", true)]
    static let state: Schema = ["closed": ("b", false), "name": ("s", false), "version": ("i", true), "app": ("s", true), "group": ("s", true), "revision": ("i", true), "previous": ("s", true), "members": ("M", true), "invitation": ("s", true), "request_hash": ("s", true)]
    static let request: Schema = ["version": ("i", true), "app": ("s", true), "group": ("s", true), "invitation": ("s", true), "member": ("m", true), "token_hash": ("s", true)]
    static let grant: Schema = ["version": ("i", true), "purpose": ("s", true), "mode": ("s", true), "app": ("s", true), "group": ("s", true), "invitation": ("s", true), "expires": ("i", true), "secret_hash": ("s", true), "delegate_key": ("s", true), "anchor_revision": ("i", true), "anchor_hash": ("s", true)]
    static let schemas = [state, request, grant]

    static func check(_ raw: Data, _ schema: Schema) -> Bool {
        guard String(data: raw, encoding: .utf8) != nil else { return false }
        var p = Scanner(b: [UInt8](raw))
        return p.object(schema) && p.ws() == p.b.count
    }

    struct Scanner {
        let b: [UInt8]
        var i = 0
        @discardableResult mutating func ws() -> Int {
            while i < b.count, [0x20, 0x09, 0x0a, 0x0d].contains(b[i]) { i += 1 }
            return i
        }
        mutating func eat(_ c: UInt8) -> Bool {
            ws()
            if i < b.count, b[i] == c { i += 1; return true }
            return false
        }
        // Keys are compared as raw bytes, so an escaped key never matches the schema.
        mutating func object(_ schema: Schema) -> Bool {
            guard eat(0x7b) else { return false }
            var seen = Set<String>()
            if !eat(0x7d) {
                while true {
                    let start = ws()
                    guard string(), let k = String(bytes: b[(start + 1)..<(i - 1)], encoding: .utf8), let f = schema[k], !seen.contains(k), eat(0x3a), value(f.kind) else { return false }
                    seen.insert(k)
                    if eat(0x7d) { break }
                    guard eat(0x2c) else { return false }
                }
            }
            return schema.allSatisfy { !$0.value.required || seen.contains($0.key) }
        }
        mutating func value(_ kind: Character) -> Bool {
            ws()
            switch kind {
            case "s": return string()
            case "b": return word("true") || word("false")
            case "i": return integer()
            case "m": return object(StrictPayload.member)
            default: break
            }
            guard eat(0x5b) else { return false }
            if eat(0x5d) { return true }
            while true {
                guard object(StrictPayload.member) else { return false }
                if eat(0x5d) { return true }
                guard eat(0x2c) else { return false }
            }
        }
        mutating func word(_ w: String) -> Bool {
            let w = Array(w.utf8)
            guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { return false }
            i += w.count
            return true
        }
        // Only 0 or [1-9][0-9]* up to 2^53-1; a fraction or exponent fails at the caller.
        mutating func integer() -> Bool {
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            let digits = b[start..<i]
            guard let first = digits.first, digits.count == 1 || first != 0x30, let n = UInt64(String(decoding: digits, as: UTF8.self)) else { return false }
            return n <= 9_007_199_254_740_991
        }
        mutating func string() -> Bool {
            guard i < b.count, b[i] == 0x22 else { return false }
            i += 1
            while i < b.count {
                let c = b[i]
                if c == 0x22 { i += 1; return true }
                if c < 0x20 { return false }
                if c == 0x5c {
                    i += 1
                    guard i < b.count else { return false }
                    if b[i] == 0x75 {
                        guard i + 4 < b.count else { return false }
                        let h = b[(i + 1)...(i + 4)]
                        guard h.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }), let n = UInt32(String(decoding: h, as: UTF8.self), radix: 16), n < 0xd800 || n > 0xdfff else { return false }
                        i += 4
                    } else if !Array("\"\\/bfnrt".utf8).contains(b[i]) {
                        return false
                    }
                }
                i += 1
            }
            return false
        }
    }
}
