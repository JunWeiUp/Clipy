import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SmartSwitchSettingsView: View {
    @ObservedObject private var store = SmartSwitchStore.shared
    @ObservedObject private var voiceRouter = SmartSwitchVoiceRouter.shared
    @State private var baseURL = SmartSwitchStore.shared.configuration.baseURL
    @State private var model = SmartSwitchStore.shared.configuration.model
    @State private var apiKey = ""
    @State private var credentialLoaded = false
    @State private var status: String?
    @State private var shortcutFailed = SmartSwitchGlobalHotKeyManager.registrationFailed
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = 0

    var body: some View {
        Group {
            Section {
                Text(L10n.t(.smartSwitchSetupHint)).foregroundStyle(.secondary)
                Toggle(L10n.t(.smartSwitchShortcut), isOn: $store.configuration.shortcutEnabled)
                    .onChange(of: store.configuration.shortcutEnabled) { _ in registerShortcut() }
                ShortcutRecorderRepresentable(combo: $store.configuration.shortcut) { _ in registerShortcut() }
                    .frame(height: 30)
                if shortcutFailed { Text(L10n.t(.smartSwitchShortcutConflict)).foregroundStyle(.orange) }
            }
            Section(L10n.t(.smartVoiceTitle)) {
                Toggle(L10n.t(.smartVoiceEnabled), isOn: $store.voiceConfiguration.enabled)
                Picker(L10n.t(.smartVoiceTrigger), selection: $store.voiceConfiguration.trigger) {
                    ForEach(SmartSwitchVoiceKey.allCases) { key in Text(key.title).tag(key) }
                }
                Text(L10n.t(.smartVoiceHint)).font(AppFont.caption).foregroundStyle(.secondary)
                Text(voiceStatus).font(AppFont.caption).foregroundStyle(.secondary)
                if store.voiceConfiguration.enabled {
                    HStack {
                        if voiceRouter.status == .needsPermission {
                            Button(L10n.t(.accessibilityPermission)) { AccessibilityManager.openSettings() }
                            Button(L10n.t(.smartVoiceInputMonitoring)) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Button(L10n.t(.smartVoiceRecheck)) { voiceRouter.configure() }
                    }
                }
            }
            Section(L10n.t(.smartSwitchAPI)) {
                TextField("Base URL", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                TextField(L10n.t(.smartSwitchModel), text: $model)
                SecureField("API Key", text: $apiKey)
                Text(L10n.t(.smartSwitchAPIHint)).font(AppFont.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.t(.smartSwitchSaveAPI), action: saveAPI)
                        .disabled(!credentialLoaded)
                    Button(L10n.t(.smartSwitchTest), action: testConnection)
                        .disabled(isTesting || !credentialLoaded)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                if let status { Text(status).font(AppFont.caption).textSelection(.enabled) }
                Text(L10n.t(.smartSwitchPrivacy)).font(AppFont.caption).foregroundStyle(.secondary)
            }
            SmartSwitchActionSettings(store: store)
            Section(L10n.t(.smartSwitchApplications)) {
                if store.configuration.targets.isEmpty {
                    Text(L10n.t(.smartSwitchNoTargets)).foregroundStyle(.secondary)
                }
                ForEach($store.configuration.targets) { $target in
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: target.applicationPath))
                                .resizable().frame(width: 24, height: 24)
                            Toggle(target.name, isOn: $target.isEnabled)
                            Spacer()
                            Button(L10n.t(.smartSwitchLocate)) { chooseApplications(replacing: target.id) }
                            Button(L10n.t(.delete)) {
                                store.configuration.targets.removeAll { $0.id == target.id }
                            }
                        }
                        TextField(L10n.t(.smartSwitchAppName), text: $target.name)
                        TextField(L10n.t(.smartSwitchAliases), text: $target.aliases)
                        TextField(L10n.t(.smartSwitchDescription), text: $target.intentDescription, axis: .vertical)
                            .lineLimit(1...3)
                        Text(target.applicationPath).font(AppFont.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(target.applicationPath)
                    }
                    .padding(.vertical, AppSpacing.xs)
                }
                Button(L10n.t(.smartSwitchAddApplication)) { chooseApplications(replacing: nil) }
            }
        }
        .onAppear {
            guard !credentialLoaded else { return }
            do { apiKey = try SmartSwitchCredentialStore.load(); credentialLoaded = true }
            catch { status = SmartSwitchError.message(for: error) }
        }
        .onChange(of: baseURL) { _ in cancelTest() }
        .onChange(of: model) { _ in cancelTest() }
        .onChange(of: apiKey) { _ in cancelTest() }
        .onReceive(NotificationCenter.default.publisher(for: .smartSwitchShortcutChanged)) { _ in
            shortcutFailed = SmartSwitchGlobalHotKeyManager.registrationFailed
        }
        .onDisappear { cancelTest() }
    }

    private func registerShortcut() { shortcutFailed = !SmartSwitchGlobalHotKeyManager.register() }

    private var voiceStatus: String {
        switch voiceRouter.status {
        case .disabled: return L10n.t(.smartVoiceDisabled)
        case .needsSetup: return L10n.t(.smartVoiceNeedsSetup)
        case .needsPermission: return L10n.t(.smartVoiceNeedsPermission)
        case .active: return L10n.t(.smartVoiceActive)
        case .unavailable: return L10n.t(.smartVoiceUnavailable)
        }
    }

    private func draftConfiguration() throws -> SmartSwitchConfiguration {
        var config = store.configuration
        config.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try SmartSwitchAPIService.endpoint(config.baseURL)
        guard !config.model.isEmpty, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SmartSwitchError.configuration
        }
        return config
    }

    private func saveAPI() {
        cancelTest()
        do {
            // Empty all three fields to remove the saved service and credential.
            var config = store.configuration
            if baseURL.isEmpty && model.isEmpty && apiKey.isEmpty {
                config.baseURL = ""
                config.model = ""
            } else { config = try draftConfiguration() }
            try SmartSwitchCredentialStore.save(apiKey)
            store.configuration = config
            status = L10n.t(.smartSwitchSaved)
        } catch { status = SmartSwitchError.message(for: error) }
    }

    private func cancelTest() {
        testGeneration += 1
        testTask?.cancel()
        testTask = nil
        isTesting = false
        status = nil
    }

    private func testConnection() {
        cancelTest()
        do {
            let service = SmartSwitchAPIService(configuration: try draftConfiguration(), apiKey: apiKey)
            let target = SmartSwitchTarget(bundleIdentifier: "test", applicationPath: "", name: "Connection Test")
            let ticket = testGeneration
            isTesting = true
            testTask = Task { @MainActor in
                do {
                    let result = try await service.resolve(text: "Open Connection Test", targets: [target])
                    guard ticket == testGeneration, !Task.isCancelled else { return }
                    guard result == .matched(target.id) else { throw SmartSwitchError.invalidResponse }
                    status = L10n.t(.smartSwitchTestSuccess)
                } catch {
                    guard ticket == testGeneration, !Task.isCancelled else { return }
                    status = SmartSwitchError.message(for: error)
                }
                isTesting = false
            }
        } catch { status = SmartSwitchError.message(for: error) }
    }

    private func chooseApplications(replacing id: UUID?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = id == nil
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.begin { response in
            guard response == .OK else { return }
            do {
                let chosen = try panel.urls.map(SmartSwitchTarget.application)
                if let id, let replacement = chosen.first,
                   let index = store.configuration.targets.firstIndex(where: { $0.id == id }) {
                    // Preserve aliases, intent and stable ID when locating a moved/replaced app.
                    store.configuration.targets[index].bundleIdentifier = replacement.bundleIdentifier
                    store.configuration.targets[index].applicationPath = replacement.applicationPath
                } else {
                    for target in chosen where !store.configuration.targets.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) {
                        store.configuration.targets.append(target)
                    }
                }
            } catch { status = SmartSwitchError.message(for: error) }
        }
    }
}
