import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var languageObserver: AppLanguageObserver
  @State private var selectedSettingsPage = "general"
  @State private var selectedLanguage: AppLanguage
  @State private var selectedAppearance: AppAppearancePreference
  @State private var launchAtLogin: Bool
  @State private var historyLimit: Int
  @State private var historyLimitText: String
  @FocusState private var historyLimitFocused: Bool
  @State private var currentHistoryCount: Int
  @State private var historyRetentionDays: Int
  @State private var historyEncryptionEnabled: Bool
  @State private var historyImageOCRIndexing: Bool
  @State private var searchGlobalShortcutEnabled: Bool
  @State private var searchHistoryShortcut: ShortcutCombo?
  @State private var wordShortcutEnabled: Bool
  @State private var wordLookupShortcut: ShortcutCombo?
  @State private var wordShortcutFailed = false
  @State private var isReencryptingHistory = false

  init() {
    let prefs = PreferencesManager.shared
    _selectedLanguage = State(initialValue: prefs.appLanguage)
    _selectedAppearance = State(initialValue: prefs.appAppearance)
    #if CLIPY_CORE_TESTS
    _launchAtLogin = State(initialValue: ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] == nil && LaunchAtLoginManager.isEnabled)
    #else
    _launchAtLogin = State(initialValue: LaunchAtLoginManager.isEnabled)
    #endif
    let limit = prefs.historyLimit
    _historyLimit = State(initialValue: limit)
    _historyLimitText = State(initialValue: "\(limit)")
    #if CLIPY_CORE_TESTS
    if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil {
      _currentHistoryCount = State(initialValue: 12)
    } else {
      _currentHistoryCount = State(initialValue: ClipboardManager.shared.totalHistoryCount)
    }
    #else
    _currentHistoryCount = State(initialValue: ClipboardManager.shared.totalHistoryCount)
    #endif
    _historyRetentionDays = State(initialValue: prefs.historyRetentionDays)
    _historyEncryptionEnabled = State(initialValue: prefs.isHistoryEncryptionEnabled)
    _historyImageOCRIndexing = State(initialValue: prefs.isHistoryImageOCRIndexingEnabled)
    _searchGlobalShortcutEnabled = State(initialValue: prefs.isSearchGlobalShortcutEnabled)
    _searchHistoryShortcut = State(initialValue: prefs.searchHistoryShortcut)
    _wordShortcutEnabled = State(initialValue: prefs.isWordShortcutEnabled)
    _wordLookupShortcut = State(initialValue: prefs.wordLookupShortcut)
  }

  private var settingsPages: [AppSettingsPage] {
    return [
      .init(id: "general", title: L10n.t(.designGeneral), symbol: "gearshape"),
      .init(id: "history", title: L10n.t(.history), symbol: "clock.arrow.circlepath"),
      .init(id: "shortcuts", title: L10n.t(.shortcut), symbol: "keyboard"),
    ]
      + ScreenshotSettingsView.settingsPages
      + [
        .init(id: "permissions", title: L10n.t(.designPermissions), symbol: "hand.raised"),
        .init(id: "about", title: L10n.t(.settingsAbout), symbol: "info.circle"),
      ]
  }

  /// Retention choices in days; 0 keeps history forever.
  private static let retentionOptions = [0, 7, 30, 90, 365]

  var body: some View {
    let _ = languageObserver.revision

    AppSettingsLayout(selection: $selectedSettingsPage, pages: settingsPages) { pageID in
      if pageID == "general" { generalPage }
      if pageID == "history" { historyPage }
      if pageID == "shortcuts" { shortcutsPage }
      if pageID.hasPrefix(ScreenshotSettingsView.pagePrefix) {
        ScreenshotSettingsView(
          pageID: String(pageID.dropFirst(ScreenshotSettingsView.pagePrefix.count)))
      }
      if pageID == "permissions" {
        ScreenshotSettingsView(pageID: "permissions")
      }
      if pageID == "about" { aboutPage }
    }
    .frame(
      minWidth: AppWindowSize.settingsMin.width,
      minHeight: AppWindowSize.settingsMin.height)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      launchAtLogin = LaunchAtLoginManager.isEnabled
      currentHistoryCount = ClipboardManager.shared.totalHistoryCount
    }
    .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryDidChange)) { _ in
      currentHistoryCount = ClipboardManager.shared.totalHistoryCount
    }
  }

  // MARK: - Pages

  @ViewBuilder private var generalPage: some View {
    SettingsCard {
      SettingsRow(title: L10n.t(.language)) {
        Picker("", selection: $selectedLanguage) {
          ForEach(AppLanguage.allCases, id: \.self) { language in
            Text(language.displayName).tag(language)
          }
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: selectedLanguage) { newValue in
        PreferencesManager.shared.appLanguage = newValue
      }
      SettingsRow(title: L10n.t(.appearance)) {
        Picker("", selection: $selectedAppearance) {
          ForEach(AppAppearancePreference.allCases, id: \.self) { appearance in
            Text(appearance.displayName).tag(appearance)
          }
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: selectedAppearance) { newValue in
        PreferencesManager.shared.appAppearance = newValue
      }
      MenuBarOverflowSettingsView()
      SettingsRow(title: L10n.t(.launchAtLogin)) { SettingsSwitch(isOn: $launchAtLogin) }
        .onChange(of: launchAtLogin) { newValue in
          // Skip the write when re-syncing from the system on activation.
          guard newValue != LaunchAtLoginManager.isEnabled else { return }
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
  }

  @ViewBuilder private var historyPage: some View {
    SettingsCard {
      SettingsRow(title: L10n.t(.historyLimit)) {
        TextField("", text: $historyLimitText)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .modifier(SettingsTextFieldStyle(height: 22))
          .frame(width: 64)
          .focused($historyLimitFocused)
          .onSubmit { commitHistoryLimitText() }
        Stepper("", value: $historyLimit, in: Self.historyLimitRange, step: 100).controlSize(.small)
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
      SettingsRow(title: L10n.t(.historyRetention), detail: L10n.format(.historyLimitCaption, currentHistoryCount)) {
        Picker("", selection: $historyRetentionDays) {
          ForEach(Self.retentionOptions, id: \.self) { days in
            Text(days == 0 ? L10n.t(.historyRetentionForever) : L10n.format(.historyRetentionDays, days))
              .tag(days)
          }
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: historyRetentionDays) { newValue in
        PreferencesManager.shared.historyRetentionDays = newValue
        ClipboardManager.shared.applyHistoryLimit()
      }
    }
    SettingsSubheader(L10n.t(.excludedApps))
    ExcludedAppsEditor()
    SettingsSubheader(settingsText("安全与搜索", "Security & Search"))
    SettingsCard {
      SettingsRow(title: L10n.t(.encryptHistoryAtRest), detail: L10n.t(.encryptHistoryAtRestDescription)) {
        if isReencryptingHistory {
          ProgressView().controlSize(.small)
            .help(L10n.t(.historyEncryptionInProgress))
        }
        SettingsSwitch(isOn: $historyEncryptionEnabled)
          .disabled(isReencryptingHistory)
      }
      .onChange(of: historyEncryptionEnabled) { newValue in
        guard newValue != PreferencesManager.shared.isHistoryEncryptionEnabled else { return }
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
        SettingsCaptionRow(L10n.t(.historyEncryptionInProgress))
      }
      SettingsRow(title: L10n.t(.historyImageOCRIndexing), detail: L10n.t(.historyImageOCRIndexingDescription)) {
        SettingsSwitch(isOn: $historyImageOCRIndexing)
      }
      .onChange(of: historyImageOCRIndexing) { newValue in
        PreferencesManager.shared.isHistoryImageOCRIndexingEnabled = newValue
      }
    }
  }

  @ViewBuilder private var shortcutsPage: some View {
    SettingsCard {
      SettingsRow(title: L10n.t(.searchGlobalShortcut), detail: L10n.t(.searchGlobalShortcutDescription)) {
        ShortcutRecorderRepresentable(combo: $searchHistoryShortcut) { combo in
          PreferencesManager.shared.searchHistoryShortcut = combo
          SearchGlobalHotKeyManager.register()
        }
        .frame(width: 150, height: 26)
        SettingsSwitch(isOn: $searchGlobalShortcutEnabled)
      }
      .onChange(of: searchGlobalShortcutEnabled) { newValue in
        PreferencesManager.shared.isSearchGlobalShortcutEnabled = newValue
        SearchGlobalHotKeyManager.register()
      }
      SettingsRow(title: L10n.t(.wordShortcut), detail: L10n.t(.wordShortcutDescription)) {
        ShortcutRecorderRepresentable(combo: $wordLookupShortcut) { combo in
          PreferencesManager.shared.wordLookupShortcut = combo
          wordShortcutFailed = !WordGlobalHotKeyManager.register()
        }
        .frame(width: 150, height: 26)
        SettingsSwitch(isOn: $wordShortcutEnabled)
      }
      .onChange(of: wordShortcutEnabled) { value in
        PreferencesManager.shared.isWordShortcutEnabled = value
        wordShortcutFailed = !WordGlobalHotKeyManager.register()
      }
      if wordShortcutFailed {
        SettingsCaptionRow(L10n.t(.wordShortcutConflict), color: SettingsPalette.warn)
      }
    }
  }

  @ViewBuilder private var aboutPage: some View {
    SettingsCard {
      SettingsCustomRow(searchText: "ClipyClone \(L10n.t(.settingsVersion)) \(AppVersion.displayString)") {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 46, height: 46)
        VStack(alignment: .leading, spacing: 2) {
          Text("ClipyClone").font(.system(size: 18, weight: .bold)).foregroundStyle(SettingsPalette.text)
          Text("\(L10n.t(.settingsVersion)) \(AppVersion.displayString)")
            .font(.system(size: 12)).foregroundStyle(SettingsPalette.text3)
            .textSelection(.enabled)
        }
        Spacer(minLength: 0)
        Button(settingsText("重新打开使用向导", "Open setup guide")) {
          OnboardingWindow.shared.show()
        }
        .buttonStyle(SettingsButtonStyle())
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 2)
    }
    SettingsSubheader(settingsText("诊断", "Diagnostics"))
    SettingsCard {
      SettingsRow(
        icon: SettingsRowIcon(symbol: "doc.text"),
        title: settingsText("诊断日志", "Diagnostic logs"),
        detail: L10n.t(.diagnosticsHint)
      ) {
        Button(L10n.t(.showLogs)) { LogWindow.show() }
          .buttonStyle(SettingsButtonStyle())
        Button(L10n.t(.openLogFolder)) {
          NSWorkspace.shared.open(LogManager.logDirectory)
        }
        .buttonStyle(SettingsButtonStyle())
      }
    }
  }

  private static let historyLimitRange = 1...100_000

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

  static func confirm(
    title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void
  ) {
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
