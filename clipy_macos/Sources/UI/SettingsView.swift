import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @State private var selectedLanguage: AppLanguage
    @State private var launchAtLogin: Bool
    @State private var deviceName: String
    @State private var historyLimit: Int
    @State private var historyLimitText: String
    @FocusState private var historyLimitFocused: Bool
    @State private var currentHistoryCount: Int
    @State private var excludedApps: String
    @State private var historyEncryptionEnabled: Bool
    @State private var historyImageOCRIndexing: Bool
    @State private var searchGlobalShortcutEnabled: Bool
    @State private var searchHistoryShortcut: ShortcutCombo?
    @State private var syncEnabled: Bool
    @State private var syncPort: String
    @State private var availablePeers: [DiscoveredPeer] = []
    @State private var clipboardSyncTargets: Set<String> = Set(PreferencesManager.shared.clipboardSyncPeerIds)
    @State private var notificationSyncTargets: Set<String> = Set(PreferencesManager.shared.notificationSyncPeerIds)
    @State private var isRefreshingDevices = false
    // Manual peers (host:port) for cross-band / cross-subnet discovery.
    @State private var manualPeers: [String] = PreferencesManager.shared.manualSyncPeers
    @State private var showAddManualPeer = false
    @State private var manualPeerHost = ""
    @State private var manualPeerPort = "5566"
    @State private var accessibilityGranted: Bool
    @State private var isReencryptingHistory = false
    @State private var syncPairingSecret: String = PreferencesManager.shared.syncPairingSecret

    init() {
        let prefs = PreferencesManager.shared
        _selectedLanguage = State(initialValue: prefs.appLanguage)
        _launchAtLogin = State(initialValue: LaunchAtLoginManager.isEnabled)
        _deviceName = State(initialValue: prefs.deviceName)
        let limit = prefs.historyLimit
        _historyLimit = State(initialValue: limit)
        _historyLimitText = State(initialValue: "\(limit)")
        _currentHistoryCount = State(initialValue: ClipboardManager.shared.totalHistoryCount)
        _excludedApps = State(initialValue: prefs.excludedApps.joined(separator: ", "))
        _historyEncryptionEnabled = State(initialValue: prefs.isHistoryEncryptionEnabled)
        _historyImageOCRIndexing = State(initialValue: prefs.isHistoryImageOCRIndexingEnabled)
        _searchGlobalShortcutEnabled = State(initialValue: prefs.isSearchGlobalShortcutEnabled)
        _searchHistoryShortcut = State(initialValue: prefs.searchHistoryShortcut)
        _syncEnabled = State(initialValue: prefs.isSyncEnabled)
        _syncPort = State(initialValue: "\(prefs.syncPort)")
        _accessibilityGranted = State(initialValue: AccessibilityManager.isTrusted)
    }

    var body: some View {
        let _ = languageObserver.revision

        AppFormWindowLayout {
            ScrollView {
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
                Text(L10n.format(.historyCurrentCount, currentHistoryCount))
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

                Toggle(L10n.t(.encryptHistoryAtRest), isOn: $historyEncryptionEnabled)
                    .disabled(isReencryptingHistory)
                    .onChange(of: historyEncryptionEnabled) { newValue in
                        isReencryptingHistory = true
                        let started = ClipboardManager.shared.setHistoryEncryptionEnabled(newValue) { _ in
                            isReencryptingHistory = false
                        }
                        if !started {
                            isReencryptingHistory = false
                            historyEncryptionEnabled = !newValue
                            AlertPresenter.showWarning(
                                title: L10n.t(.error),
                                message: L10n.t(.historyEncryptionFailed)
                            )
                        }
                    }
                if isReencryptingHistory {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t(.historyEncryptionInProgress))
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.t(.encryptHistoryAtRestDescription))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.t(.historyImageOCRIndexing), isOn: $historyImageOCRIndexing)
                    .onChange(of: historyImageOCRIndexing) { newValue in
                        PreferencesManager.shared.isHistoryImageOCRIndexingEnabled = newValue
                    }
                Text(L10n.t(.historyImageOCRIndexingDescription))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.t(.searchGlobalShortcut), isOn: $searchGlobalShortcutEnabled)
                    .onChange(of: searchGlobalShortcutEnabled) { newValue in
                        PreferencesManager.shared.isSearchGlobalShortcutEnabled = newValue
                        SearchGlobalHotKeyManager.register()
                    }
                ShortcutRecorderRepresentable(combo: $searchHistoryShortcut) { combo in
                    PreferencesManager.shared.searchHistoryShortcut = combo
                    SearchGlobalHotKeyManager.register()
                }
                .frame(height: 30)
                Text(L10n.t(.searchGlobalShortcutDescription))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
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

                SecureField(L10n.t(.syncPairingSecret), text: $syncPairingSecret)
                    .onSubmit { PreferencesManager.shared.syncPairingSecret = syncPairingSecret }
                    .onChange(of: syncPairingSecret) { newValue in
                        PreferencesManager.shared.syncPairingSecret = newValue
                    }
                Text(L10n.t(.syncPairingSecretHint))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                if syncPairingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.t(.syncPairingSecretDefaultWarning))
                        .font(AppFont.caption)
                        .foregroundStyle(.orange)
                }

                Text(L10n.t(.authorizedDevices))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t(.syncTargetsHint))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                Text(L10n.format(.syncLocalNameHint, PreferencesManager.shared.deviceName, String(PreferencesManager.shared.syncPeerId.prefix(8))))

                Button {
                    guard !isRefreshingDevices else { return }
                    isRefreshingDevices = true
                    // User refresh: prune ghosts + full /24 scan.
                    SyncManager.shared.refreshDiscovery(pruneCache: true, scanFullSubnet: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        availablePeers = SyncManager.shared.availablePeers
                        isRefreshingDevices = false
                    }
                } label: {
                    HStack {
                        if isRefreshingDevices {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.t(.refreshingDevices))
                        } else {
                            Text(L10n.t(.refreshDevices))
                        }
                    }
                }
                .disabled(!syncEnabled || isRefreshingDevices)

                let authDeviceRows = Self.authDeviceRows(
                    availablePeers: availablePeers,
                    clipboard: clipboardSyncTargets,
                    notification: notificationSyncTargets
                )
                if authDeviceRows.isEmpty {
                    Text(L10n.t(.noDevicesFound))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(authDeviceRows, id: \.peerId) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.displayName)
                                Spacer()
                                Text(row.isOnline ? L10n.t(.deviceOnline) : L10n.t(.deviceOffline))
                                    .font(AppFont.caption)
                                    .foregroundStyle(row.isOnline ? .green : .secondary)
                                if clipboardSyncTargets.contains(row.peerId)
                                    || notificationSyncTargets.contains(row.peerId) {
                                    Button {
                                        clipboardSyncTargets.remove(row.peerId)
                                        notificationSyncTargets.remove(row.peerId)
                                        PreferencesManager.shared.removeAuthorizedPeer(row.peerId)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if let hostPort = row.hostPort {
                                Text(hostPort)
                                    .font(AppFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Toggle(isOn: Binding(
                                get: { clipboardSyncTargets.contains(row.peerId) },
                                set: { enabled in
                                    if enabled {
                                        clipboardSyncTargets.insert(row.peerId)
                                    } else {
                                        clipboardSyncTargets.remove(row.peerId)
                                    }
                                    PreferencesManager.shared.setClipboardSync(
                                        peerId: row.peerId, enabled: enabled)
                                    if enabled {
                                        SyncManager.shared.refreshPendingDelivery(for: row.peerId)
                                    }
                                }
                            )) {
                                Text(L10n.t(.syncClipboardToDevice))
                                    .font(AppFont.caption)
                            }
                            Toggle(isOn: Binding(
                                get: { notificationSyncTargets.contains(row.peerId) },
                                set: { enabled in
                                    if enabled {
                                        notificationSyncTargets.insert(row.peerId)
                                    } else {
                                        notificationSyncTargets.remove(row.peerId)
                                    }
                                    PreferencesManager.shared.setNotificationSync(
                                        peerId: row.peerId, enabled: enabled)
                                    if enabled {
                                        SyncManager.shared.refreshPendingDelivery(for: row.peerId)
                                    }
                                }
                            )) {
                                Text(L10n.t(.syncNotificationsToDevice))
                                    .font(AppFont.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider()
                Text(L10n.t(.syncAddManualDevice))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t(.syncManualDeviceHint))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                Button {
                    manualPeerHost = ""
                    manualPeerPort = "\(PreferencesManager.shared.syncPort)"
                    showAddManualPeer = true
                } label: {
                    Label(L10n.t(.syncAdd), systemImage: "plus")
                }
                .disabled(!syncEnabled)

                ForEach(manualPeers, id: \.self) { entry in
                    HStack {
                        Text(entry)
                            .font(AppFont.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            PreferencesManager.shared.removeManualPeer(entry)
                            manualPeers = PreferencesManager.shared.manualSyncPeers
                            SyncManager.shared.triggerCrossBandDiscovery()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
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
        }
        .frame(width: AppWindowSize.settings.width)
        .frame(minHeight: AppWindowSize.settings.height, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .syncAvailableDevicesDidChange)) { notification in
            if let peers = notification.userInfo?["peers"] as? [DiscoveredPeer] {
                availablePeers = peers
            } else if notification.userInfo?["devices"] is [String] {
                // Legacy name-only payload carries no peer objects; read the
                // manager's current list instead.
                availablePeers = SyncManager.shared.availablePeers
            }
        }
        .onAppear {
            availablePeers = SyncManager.shared.availablePeers
            clipboardSyncTargets = Set(PreferencesManager.shared.clipboardSyncPeerIds)
            notificationSyncTargets = Set(PreferencesManager.shared.notificationSyncPeerIds)
            manualPeers = PreferencesManager.shared.manualSyncPeers
            // Dial authorized cache only — do not prune or /24-scan on open.
            if PreferencesManager.shared.isSyncEnabled {
                SyncManager.shared.triggerCrossBandDiscovery()
            }
        }
        .sheet(isPresented: $showAddManualPeer) {
            VStack(spacing: 16) {
                Text(L10n.t(.syncAddManualDevice)).font(.headline)
                TextField(L10n.t(.syncManualDeviceHost), text: $manualPeerHost)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(L10n.t(.syncManualDevicePort))
                    TextField("5566", text: $manualPeerPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack {
                    Button(L10n.t(.cancel)) { showAddManualPeer = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.t(.syncAdd)) {
                        let host = manualPeerHost.trimmingCharacters(in: .whitespaces)
                        let port = Int(manualPeerPort) ?? PreferencesManager.shared.syncPort
                        guard Self.isValidIPv4(host), (1...65535).contains(port) else { return }
                        let entry = "\(host):\(port)"
                        guard !PreferencesManager.shared.manualSyncPeers.contains(entry) else {
                            showAddManualPeer = false
                            return
                        }
                        PreferencesManager.shared.addManualPeer(entry)
                        manualPeers = PreferencesManager.shared.manualSyncPeers
                        showAddManualPeer = false
                        SyncManager.shared.triggerCrossBandDiscovery()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 340)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityManager.isTrusted
            launchAtLogin = LaunchAtLoginManager.isEnabled
            currentHistoryCount = ClipboardManager.shared.totalHistoryCount
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryDidChange)) { _ in
            currentHistoryCount = ClipboardManager.shared.totalHistoryCount
        }
    }

    private static let historyLimitRange = 1...1000

    private struct AuthDeviceRow: Identifiable {
        var id: String { peerId }
        let peerId: String
        let displayName: String
        let hostPort: String?
        let isOnline: Bool
    }

    /// Authorized peers (always) ∪ currently discovered (for new checkboxes).
    private static func authDeviceRows(
        availablePeers: [DiscoveredPeer],
        clipboard: Set<String>,
        notification: Set<String>
    ) -> [AuthDeviceRow] {
        let onlineIds = Set(availablePeers.map(\.peerId))
        let ids = clipboard.union(notification).union(onlineIds)
        let sync = SyncManager.shared
        return ids.sorted().map { peerId in
            let online = availablePeers.first(where: { $0.peerId == peerId })
            return AuthDeviceRow(
                peerId: peerId,
                displayName: online?.displayName ?? sync.resolvedPeerLabel(peerId: peerId),
                hostPort: online.map { "\($0.host):\($0.port)" } ?? sync.resolvedPeerHostPort(peerId: peerId),
                isOnline: online != nil
            )
        }
    }

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

    private static func isValidIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
        }
        return true
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
