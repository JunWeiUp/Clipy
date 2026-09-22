import AppKit

@MainActor
protocol SmartSwitchActionExecuting {
    func perform(_ intent: SmartSwitchIntent, configuration: SmartSwitchConfiguration,
                 canContinue: @escaping () -> Bool, willActivate: @escaping () -> Void) async throws
}

@MainActor
struct SmartSwitchActionExecutor: SmartSwitchActionExecuting {
    static let codexBundleIdentifier = "com.openai.codex"
    private let zcode: SmartSwitchZCodeOpening
    private let applicationLauncher: SmartSwitchLaunching
    private let codexURL: () -> URL?

    init(zcode: SmartSwitchZCodeOpening? = nil, applicationLauncher: SmartSwitchLaunching? = nil,
         codexURL: @escaping () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") }) {
        self.zcode = zcode ?? SmartSwitchZCodeLauncher()
        self.applicationLauncher = applicationLauncher ?? SmartSwitchApplicationLauncher()
        self.codexURL = codexURL
    }

    func perform(_ intent: SmartSwitchIntent, configuration: SmartSwitchConfiguration,
                 canContinue: @escaping () -> Bool, willActivate: @escaping () -> Void) async throws {
        try Task.checkCancellation()
        guard canContinue() else { throw CancellationError() }
        switch intent.action {
        case .zcodeNewChat:
            // New Chat carries the full draft, or opens an empty chat if blank.
            try await zcode.openNewChat(text: intent.text, canContinue: canContinue, willActivate: willActivate)
        case .webSearch:
            guard !intent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SmartSwitchError.invalidInput }
            willActivate()
            guard NSWorkspace.shared.open(configuration.searchEngine.url(query: intent.text)) else { throw SmartSwitchError.activationFailed }
        case .openCodex:
            guard let url = codexURL() else {
                throw SmartSwitchActionError.message(SmartActionL10n.t("未找到 Codex，请先安装并打开一次。", "Codex was not found. Install and open it first."))
            }
            let target = try SmartSwitchTarget.application(at: url)
            guard target.bundleIdentifier == Self.codexBundleIdentifier else { throw SmartSwitchError.invalidApplication }
            let activate = try await applicationLauncher.prepare(target)
            try Task.checkCancellation()
            guard canContinue() else { throw CancellationError() }
            willActivate()
            guard activate() else { throw SmartSwitchError.activationFailed }
        default: throw SmartSwitchError.invalidInput
        }
    }

}

enum SmartSwitchActionError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}
