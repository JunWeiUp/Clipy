import Foundation

/// 随机密码生成选项
struct PasswordOptions: Equatable {
    var length: Int = 20
    var useLowercase = true
    var useUppercase = true
    var useDigits = true
    var useSymbols = true
    /// 排除肉眼易混淆的字符（Il1|O0o）
    var excludeAmbiguous = false

    static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digits = Array("0123456789")
    static let symbols = Array("!@#$%^&*()-_=+[]{}<>?/~")
    /// 各字符集并集中视觉易混淆的字符，excludeAmbiguous 时统一剔除
    static let ambiguous: Set<Character> = Set("Il1|O0o")

    var selectedSets: [[Character]] {
        var sets: [[Character]] = []
        if useLowercase { sets.append(Self.lowercase) }
        if useUppercase { sets.append(Self.uppercase) }
        if useDigits { sets.append(Self.digits) }
        if useSymbols { sets.append(Self.symbols) }
        return sets
    }

    /// 去重后的有效字母表（可能为空：所有集合都被关闭或被排除清空）
    func effectiveAlphabet() -> [Character] {
        var seen = Set<Character>()
        var alphabet: [Character] = []
        for set in selectedSets {
            for ch in set where !excludeAmbiguous || !Self.ambiguous.contains(ch) {
                if seen.insert(ch).inserted { alphabet.append(ch) }
            }
        }
        return alphabet
    }

    /// 信息熵估算：length × log2(字符集大小)
    func entropyBits() -> Double {
        let count = effectiveAlphabet().count
        guard count > 1, length > 0 else { return 0 }
        return Double(length) * log2(Double(count))
    }

    static let strengthThresholds = (weak: Double(40), fair: Double(60), strong: Double(80))

    var strength: PasswordStrength {
        switch entropyBits() {
        case ..<Self.strengthThresholds.weak: return .weak
        case ..<Self.strengthThresholds.fair: return .fair
        case ..<Self.strengthThresholds.strong: return .strong
        default: return .veryStrong
        }
    }
}

enum PasswordStrength {
    case weak, fair, strong, veryStrong
}

/// 基于 SecRandomCopyBytes 的加密安全随机密码生成器
enum PasswordGenerator {
    static func generate(options: PasswordOptions) -> String? {
        guard options.length > 0 else { return nil }
        let alphabet = options.effectiveAlphabet()
        guard !alphabet.isEmpty else { return nil }

        // 每个选中的字符集至少保证出现一个字符（同样剔除易混淆字符）
        var chars: [Character] = []
        for set in options.selectedSets where chars.count < options.length {
            if let ch = set.filter({ !options.excludeAmbiguous || !PasswordOptions.ambiguous.contains($0) })
                .secureRandomElement() {
                chars.append(ch)
            }
        }
        while chars.count < options.length {
            let index = alphabet.secureRandomIndex(upperBound: alphabet.count) ?? Int.random(in: alphabet.indices)
            chars.append(alphabet[index])
        }
        chars.shuffleSecure()
        return String(chars)
    }
}

private extension Array {
    /// 用 SecRandomCopyBytes 取 [0, upperBound) 随机下标；拒绝采样消除取模偏差。
    /// 返回 nil 表示系统熵源不可用（调用方用 Int.random 兜底）。
    func secureRandomIndex(upperBound: Int) -> Int? {
        guard upperBound > 0, upperBound <= Int(UInt32.max) else { return nil }
        let bound = UInt32(upperBound)
        let limit = UInt32.max - (UInt32.max % bound)
        while true {
            var value: UInt32 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &value)
            guard status == errSecSuccess else { return nil }
            if value < limit { return Int(value % bound) }
        }
    }

    func secureRandomElement() -> Element? {
        guard let index = secureRandomIndex(upperBound: count) else { return nil }
        return self[index]
    }

    mutating func shuffleSecure() {
        guard count > 1 else { return }
        for i in stride(from: count - 1, through: 1, by: -1) {
            guard let j = secureRandomIndex(upperBound: i + 1) else { break }
            swapAt(i, j)
        }
    }
}
