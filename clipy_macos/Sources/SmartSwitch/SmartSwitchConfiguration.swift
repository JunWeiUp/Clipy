import AppKit
import Combine
import Security

struct SmartSwitchTarget: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleIdentifier: String
    var applicationPath: String
    var name: String
    var aliases: String = ""
    var intentDescription: String = ""
    var isEnabled = true

    static func application(at url: URL) throws -> SmartSwitchTarget {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
              bundle.executableURL != nil else { throw SmartSwitchError.invalidApplication }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return SmartSwitchTarget(bundleIdentifier: identifier, applicationPath: url.path, name: name)
    }
}

struct SmartSwitchConfiguration: Codable {
    var baseURL = ""
    var model = ""
    var targets: [SmartSwitchTarget] = []
    var shortcutEnabled = true
    var shortcut: ShortcutCombo? = ShortcutCombo(
        keyCode: 0, modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue)
    var actionOrder = SmartSwitchAction.allCases
    var searchEngine: SmartSwitchSearchEngine = .google
    var translationLanguage = "English"

    var orderedActions: [SmartSwitchAction] {
        var seen = Set<SmartSwitchAction>()
        return (actionOrder + SmartSwitchAction.allCases).filter { seen.insert($0).inserted }
    }
    var availableActions: [SmartSwitchAction] { orderedActions }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case baseURL, model, targets, shortcutEnabled, shortcut, actionOrder, searchEngine, translationLanguage
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        targets = try values.decodeIfPresent([SmartSwitchTarget].self, forKey: .targets) ?? []
        shortcutEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? true
        // The old encoder omitted a cleared optional shortcut. Missing must stay
        // nil when migrating, rather than silently restoring the default hotkey.
        shortcut = try values.decodeIfPresent(ShortcutCombo.self, forKey: .shortcut)
        actionOrder = try values.decodeIfPresent([String].self, forKey: .actionOrder)?.compactMap(SmartSwitchAction.migrated) ?? SmartSwitchAction.allCases
        searchEngine = try values.decodeIfPresent(String.self, forKey: .searchEngine).flatMap(SmartSwitchSearchEngine.init(rawValue:)) ?? .google
        translationLanguage = try values.decodeIfPresent(String.self, forKey: .translationLanguage) ?? "English"
    }
}

final class SmartSwitchStore: ObservableObject {
    static let shared = SmartSwitchStore()
    private let defaults: UserDefaults
    private static let key = "smartSwitchConfiguration.v1"
    private static let voiceKey = "smartSwitchVoiceRouting.v1"
    @Published var voiceConfiguration: SmartSwitchVoiceConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(voiceConfiguration) {
                defaults.set(data, forKey: Self.voiceKey)
            }
        }
    }
    @Published var configuration: SmartSwitchConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voiceConfiguration = defaults.data(forKey: Self.voiceKey)
            .flatMap { try? JSONDecoder().decode(SmartSwitchVoiceConfiguration.self, from: $0) }
            ?? SmartSwitchVoiceConfiguration()
        configuration = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SmartSwitchConfiguration.self, from: $0) }
            ?? SmartSwitchConfiguration()
    }
}

enum SmartSwitchError: Error, Equatable, LocalizedError {
    case configuration, noTargets, invalidInput, invalidResponse, invalidApplication
    case applicationMissing, activationFailed, keychain(Int32), http(Int)

    var errorDescription: String? {
        switch self {
        case .configuration: return L10n.t(.smartSwitchConfigurationError)
        case .noTargets: return L10n.t(.smartSwitchNoTargets)
        case .invalidInput: return L10n.t(.smartSwitchInputError)
        case .invalidResponse: return L10n.t(.smartSwitchResponseError)
        case .invalidApplication: return L10n.t(.smartSwitchInvalidApplication)
        case .applicationMissing: return L10n.t(.smartSwitchApplicationMissing)
        case .activationFailed: return L10n.t(.smartSwitchActivationFailed)
        case .keychain(let status): return L10n.format(.smartSwitchKeychainError, status)
        case .http(401), .http(403): return L10n.t(.smartSwitchAuthenticationError)
        case .http(let status): return L10n.format(.smartSwitchHTTPError, status)
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? SmartSwitchActionError { return error.localizedDescription }
        if let error = error as? SmartSwitchError { return error.localizedDescription }
        if (error as? URLError)?.code == .timedOut { return L10n.t(.smartSwitchTimeout) }
        // Do not surface response bodies or URL errors containing credentials.
        return L10n.t(.smartSwitchNetworkError)
    }
}

enum SmartSwitchCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.yourdomain.ClipyClone.smart-switch-api",
         kSecAttrAccount as String: "default"]
    }

    static func load() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw SmartSwitchError.keychain(status)
        }
        return key
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SmartSwitchError.keychain(status)
            }
            return
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SmartSwitchError.keychain(status) }
    }
}
