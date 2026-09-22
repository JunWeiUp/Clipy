import AppKit
import Combine

@MainActor
final class SmartSwitchViewModel: ObservableObject {
    @Published var query = "" {
        didSet { if oldValue != query { invalidate(); clearResults() } }
    }
    @Published private(set) var candidates: [SmartSwitchTarget] = []
    @Published var selectedID: UUID?
    @Published private(set) var output: String?
    @Published private(set) var selectedAction: SmartSwitchAction = .automatic
    @Published private(set) var availableActions = SmartSwitchAction.allCases
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var inputSourceWarning: String?
    @Published var focusGeneration = 0

    var onWillActivate: (() -> Void)?
    var onSuccess: (() -> Void)?
    var onActivationFailed: (() -> Void)?
    var onPaste: ((String) -> Void)?
    private let store: SmartSwitchStore
    private let resolverFactory: (SmartSwitchConfiguration) throws -> SmartSwitchResolving
    private let launcher: SmartSwitchLaunching
    private let executor: SmartSwitchActionExecuting
    private var generation = 0
    private var task: Task<Void, Never>?
    private var configObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?

    init(store: SmartSwitchStore, launcher: SmartSwitchLaunching, executor: SmartSwitchActionExecuting? = nil,
         resolverFactory: @escaping (SmartSwitchConfiguration) throws -> SmartSwitchResolving) {
        self.store = store
        self.launcher = launcher
        self.executor = executor ?? SmartSwitchActionExecutor()
        self.resolverFactory = resolverFactory
        availableActions = store.configuration.availableActions
        configObserver = store.$configuration.dropFirst().sink { [weak self] config in
            guard let self else { return }
            self.invalidate()
            self.clearResults()
            self.availableActions = config.availableActions
            if !self.availableActions.contains(self.selectedAction) { self.selectedAction = .automatic }
        }
        languageObserver = NotificationCenter.default.publisher(for: .appLanguageDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }
    }

    convenience init() {
        self.init(store: .shared, launcher: SmartSwitchApplicationLauncher()) {
            SmartSwitchAPIService(configuration: $0, apiKey: try SmartSwitchCredentialStore.load())
        }
    }

    var canSubmit: Bool {
        !isBusy && (!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAction.acceptsEmptyInput)
    }
    var pasteText: String { output ?? query }

    func present() {
        invalidate()
        query = ""
        clearResults()
        selectedAction = .automatic
        availableActions = store.configuration.availableActions
        inputSourceWarning = nil
        focusGeneration += 1
    }

    func close() {
        invalidate()
        focusGeneration += 1
        query = ""
        clearResults()
        inputSourceWarning = nil
    }

    func voiceRoutingInterrupted() {
        if message == nil { message = L10n.t(.smartVoiceInterrupted) }
    }

    private func clearResults() {
        candidates = []
        output = nil
        message = nil
    }

    private func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
        isBusy = false
        selectedID = nil
    }

    func selectAction(_ action: SmartSwitchAction, execute: Bool = false) {
        guard availableActions.contains(action) else { return }
        invalidate()
        clearResults()
        selectedAction = action
        if !execute { focusGeneration += 1 }
        if execute { submit() }
    }

    func cycleAction(_ delta: Int) {
        selectAction(SmartSwitchWheelSelection.next(selectedAction, in: availableActions, delta: delta))
    }

    func submit() {
        guard !isBusy else { return }
        if !candidates.isEmpty, let id = selectedID { choose(id); return }
        invalidate()
        clearResults()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 8000, !text.isEmpty || selectedAction.acceptsEmptyInput else {
            message = L10n.t(.smartSwitchInputError); return
        }
        let config = store.configuration
        let action = selectedAction
        let ticket = generation
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let intent: SmartSwitchIntent
                if action == .automatic || action == .openApplication {
                    // App launch is the first branch and does not read API credentials.
                    if let direct = SmartSwitchDirectIntent.resolve(text, targets: config.targets),
                       config.availableActions.contains(direct.action) {
                        intent = direct
                    } else {
                        let resolver = try self.resolverFactory(config)
                        if action == .automatic { intent = try await resolver.resolveIntent(text: text, configuration: config) }
                        else {
                            switch try await resolver.resolve(text: text, targets: config.targets) {
                            case .matched(let id): intent = SmartSwitchIntent(action: .openApplication, appIDs: [id])
                            case .ambiguous(let ids): intent = SmartSwitchIntent(action: .openApplication, appIDs: ids)
                            case .noMatch: intent = SmartSwitchIntent(action: .automatic)
                            }
                        }
                    }
                } else {
                    intent = SmartSwitchIntent(action: action, text: self.query, language: config.translationLanguage)
                }
                guard self.isCurrent(ticket) else { return }
                try await self.execute(intent, config: config, ticket: ticket)
            } catch { self.report(error, ticket: ticket) }
        }
    }

    private func execute(_ intent: SmartSwitchIntent, config: SmartSwitchConfiguration, ticket: Int) async throws {
        guard isCurrent(ticket) else { return }
        guard config.availableActions.contains(intent.action) else { throw SmartSwitchError.invalidResponse }
        switch intent.action {
        case .automatic:
            isBusy = false
            message = L10n.t(.smartSwitchNoMatch)
        case .openApplication:
            let targets = intent.appIDs.compactMap { id in config.targets.first { $0.id == id && $0.isEnabled } }
            guard targets.count == intent.appIDs.count else { throw SmartSwitchError.invalidResponse }
            if targets.count == 1 { try await activate(targets[0].id, ticket: ticket) }
            else {
                isBusy = false
                candidates = targets
                selectedID = targets.first?.id
                message = targets.isEmpty ? L10n.t(.smartSwitchNoMatch) : L10n.t(.smartSwitchAmbiguous)
            }
        case .translate:
            guard !intent.text.isEmpty else { throw SmartSwitchError.invalidInput }
            let result = try await resolverFactory(config).rewrite(text: intent.text, action: intent.action,
                language: intent.language.isEmpty ? config.translationLanguage : intent.language)
            guard isCurrent(ticket) else { return }
            output = result
            isBusy = false
            message = SmartActionL10n.t("结果已就绪。Esc 粘贴结果回原应用。", "Result ready. Esc pastes it back into the original app.")
        default:
            try await performExternal(intent, config: config, ticket: ticket)
        }
    }

    private func performExternal(_ intent: SmartSwitchIntent, config: SmartSwitchConfiguration, ticket: Int) async throws {
        do {
            try await executor.perform(intent, configuration: config, canContinue: { [weak self] in
                self?.isCurrent(ticket) == true
            }, willActivate: { [weak self] in self?.onWillActivate?() })
        } catch {
            if isCurrent(ticket) { onActivationFailed?() }
            throw error
        }
        guard isCurrent(ticket) else { return }
        isBusy = false
        onSuccess?()
    }

    func choose(_ id: UUID) {
        guard !isBusy, candidates.contains(where: { $0.id == id }) else { return }
        invalidate()
        isBusy = true
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.activate(id, ticket: ticket) }
            catch { self.report(error, ticket: ticket) }
        }
    }

    func useOutputAsInput() {
        guard let output else { return }
        query = output
        focusGeneration += 1
    }

    func pasteBack() { guard !pasteText.isEmpty else { return }; onPaste?(pasteText) }

    private func isCurrent(_ ticket: Int) -> Bool { generation == ticket && !Task.isCancelled }

    private func report(_ error: Error, ticket: Int) {
        guard isCurrent(ticket) else { return }
        isBusy = false
        message = SmartSwitchError.message(for: error)
    }

    private func activate(_ id: UUID, ticket: Int) async throws {
        guard let target = store.configuration.targets.first(where: { $0.id == id && $0.isEnabled }) else { throw SmartSwitchError.invalidResponse }
        let activate = try await launcher.prepare(target)
        guard isCurrent(ticket), store.configuration.targets.contains(where: { $0 == target && $0.isEnabled }) else { return }
        onWillActivate?()
        guard activate() else { onActivationFailed?(); throw SmartSwitchError.activationFailed }
        isBusy = false
        onSuccess?()
    }

    func moveSelection(_ delta: Int) {
        if !candidates.isEmpty {
            let index = candidates.firstIndex(where: { $0.id == selectedID }) ?? 0
            selectedID = candidates[(index + delta + candidates.count) % candidates.count].id
        }
    }
}
