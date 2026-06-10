import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @State private var selectedLanguage: AppLanguage
    @State private var launchAtLogin: Bool
    @State private var deviceName: String
    @State private var historyLimit: Int
    @State private var historyLimitText: String
    @FocusState private var historyLimitFocused: Bool
    @State private var excludedApps: String
    @State private var syncEnabled: Bool
    @State private var syncPort: String
    @State private var authorizedDevices: String
    @State private var notificationSyncEnabled: Bool
    @State private var notificationSound: Bool
    @State private var accessibilityGranted: Bool

    init() {
        let prefs = PreferencesManager.shared
        _selectedLanguage = State(initialValue: prefs.appLanguage)
        _launchAtLogin = State(initialValue: LaunchAtLoginManager.isEnabled)
        _deviceName = State(initialValue: prefs.deviceName)
        let limit = prefs.historyLimit
        _historyLimit = State(initialValue: limit)
        _historyLimitText = State(initialValue: "\(limit)")
        _excludedApps = State(initialValue: prefs.excludedApps.joined(separator: ", "))
        _syncEnabled = State(initialValue: prefs.isSyncEnabled)
        _syncPort = State(initialValue: "\(prefs.syncPort)")
        _authorizedDevices = State(initialValue: prefs.authorizedDevices.joined(separator: ", "))
        _notificationSyncEnabled = State(initialValue: NotificationManager.shared.notificationSyncEnabled)
        _notificationSound = State(initialValue: NotificationManager.shared.notificationSound)
        _accessibilityGranted = State(initialValue: AccessibilityManager.isTrusted)
    }

    var body: some View {
        let _ = languageObserver.revision

        AppFormWindowLayout {
            Form {
            Section {
                Picker(L10n.t(.language), selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .onChange(of: selectedLanguage) { newValue in
                    PreferencesManager.shared.appLanguage = newValue
                }

                Toggle(L10n.t(.launchAtLogin), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            try LaunchAtLoginManager.setEnabled(newValue)
                        } catch {
                            launchAtLogin = !newValue
                            AlertPresenter.showWarning(
                                title: L10n.t(.launchAtLoginFailed),
                                message: error.localizedDescription
                            )
                        }
                    }
            }

            Section {
                HStack {
                    TextField(L10n.t(.enterDeviceName), text: $deviceName)
                    Button(L10n.t(.save)) {
                        saveDeviceName()
                    }
                    .buttonStyle(.bordered)
                }
                Text(L10n.t(.deviceNameForSync))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(L10n.t(.historyLimit))
                    TextField("", text: $historyLimitText)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .focused($historyLimitFocused)
                        .onSubmit {
                            commitHistoryLimitText()
                        }
                    Stepper("", value: $historyLimit, in: 1...1000)
                        .labelsHidden()
                }
                .onChange(of: historyLimit) { newValue in
                    let text = "\(newValue)"
                    if historyLimitText != text {
                        historyLimitText = text
                    }
                    saveHistoryLimit(newValue)
                }
                .onChange(of: historyLimitFocused) { focused in
                    if !focused {
                        commitHistoryLimitText()
                    }
                }
                Text(L10n.t(.changesNextCopy))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                TextField(L10n.t(.excludedBundleIds), text: $excludedApps)
                    .onChange(of: excludedApps) { newValue in
                        let apps = newValue
                            .components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        PreferencesManager.shared.excludedApps = apps
                    }
            }

            Section {
                Toggle(L10n.t(.enableLanSync), isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { newValue in
                        PreferencesManager.shared.isSyncEnabled = newValue
                        if newValue {
                            SyncManager.shared.start()
                        } else {
                            SyncManager.shared.stop()
                        }
                    }

                TextField(L10n.t(.syncPort), text: $syncPort)
                    .onChange(of: syncPort) { newValue in
                        if let port = Int(newValue) {
                            PreferencesManager.shared.syncPort = port
                        }
                    }

                TextField(L10n.t(.authorizedDevicesComma), text: $authorizedDevices)
                    .onChange(of: authorizedDevices) { newValue in
                        let devices = newValue
                            .components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        PreferencesManager.shared.authorizedDevices = devices
                    }
            }

            Section {
                Toggle(L10n.t(.enableNotificationSync), isOn: $notificationSyncEnabled)
                    .onChange(of: notificationSyncEnabled) { newValue in
                        NotificationManager.shared.notificationSyncEnabled = newValue
                        NotificationManager.shared.savePreferences()
                    }

                Toggle(L10n.t(.notificationSound), isOn: $notificationSound)
                    .onChange(of: notificationSound) { newValue in
                        NotificationManager.shared.notificationSound = newValue
                        NotificationManager.shared.savePreferences()
                    }
            }

            Section {
                Text(L10n.t(.accessibilityPermission))
                    .font(AppFont.caption)

                Text(accessibilityGranted ? L10n.t(.accessibilityGranted) : L10n.t(.accessibilityNotGranted))
                    .font(AppFont.caption)
                    .foregroundStyle(accessibilityGranted ? .green : .orange)

                Button(L10n.t(.openSystemSettings)) {
                    AccessibilityManager.requestSystemPrompt()
                    AccessibilityManager.openSettings()
                }
                .buttonStyle(.bordered)
            }
            }
        }
        .frame(width: AppWindowSize.settings.width, height: AppWindowSize.settings.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityManager.isTrusted
            launchAtLogin = LaunchAtLoginManager.isEnabled
        }
    }

    private static let historyLimitRange = 1...1000

    private func commitHistoryLimitText() {
        let trimmed = historyLimitText.trimmingCharacters(in: .whitespaces)
        guard let limit = Int(trimmed), Self.historyLimitRange.contains(limit) else {
            historyLimitText = "\(historyLimit)"
            return
        }
        if historyLimit != limit {
            historyLimit = limit
        } else {
            historyLimitText = "\(limit)"
            saveHistoryLimit(limit)
        }
    }

    private func saveHistoryLimit(_ limit: Int) {
        PreferencesManager.shared.historyLimit = limit
        ClipboardManager.shared.applyHistoryLimit()
    }

    private func saveDeviceName() {
        let newName = deviceName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            deviceName = PreferencesManager.shared.deviceName
            return
        }
        PreferencesManager.shared.deviceName = newName
        SyncManager.shared.restartService()
        AlertPresenter.showInfo(
            title: L10n.t(.success),
            message: L10n.format(.deviceNameUpdated, newName)
        )
    }
}

enum AlertPresenter {
    static func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t(.ok))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    static func showWarning(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t(.ok))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    static func confirm(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L10n.t(.cancel))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    onConfirm()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }
}
