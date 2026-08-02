import SwiftUI

struct ScreenshotSettingsView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @State private var screenshotShortcutEnabled: Bool
    @State private var screenshotShortcut: ShortcutCombo?
    @State private var screenshotDefaultMode: ScreenshotCaptureMode
    @State private var screenshotMagnifierEnabled: Bool
    @State private var screenshotElementSnapEnabled: Bool
    @State private var screenshotAutoSaveEnabled: Bool
    @State private var screenshotSaveDirectoryPath: String
    @State private var screenshotResolution: ScreenshotResolution
    @State private var screenshotPostCaptureAction: ScreenshotPostCaptureAction
    @State private var screenshotOCRLanguage: ScreenshotOCRLanguage
    @State private var screenCaptureGranted: Bool
    @State private var accessibilityGranted: Bool

    init() {
        let prefs = PreferencesManager.shared
        _screenshotShortcutEnabled = State(initialValue: prefs.isScreenshotShortcutEnabled)
        _screenshotShortcut = State(initialValue: prefs.screenshotShortcut)
        _screenshotDefaultMode = State(initialValue: prefs.screenshotDefaultMode)
        _screenshotMagnifierEnabled = State(initialValue: prefs.isScreenshotMagnifierEnabled)
        _screenshotElementSnapEnabled = State(initialValue: prefs.isScreenshotElementSnapEnabled)
        _screenshotAutoSaveEnabled = State(initialValue: prefs.isScreenshotAutoSaveEnabled)
        _screenshotSaveDirectoryPath = State(initialValue: prefs.screenshotSaveDirectoryPath)
        _screenshotResolution = State(initialValue: prefs.screenshotResolution)
        _screenshotPostCaptureAction = State(initialValue: prefs.screenshotPostCaptureAction)
        _screenshotOCRLanguage = State(initialValue: prefs.screenshotOCRLanguage)
        _screenCaptureGranted = State(initialValue: ScreenCapturePermissionManager.isAuthorized)
        _accessibilityGranted = State(initialValue: AccessibilityManager.isTrusted)
    }

    var body: some View {
        let _ = languageObserver.revision

        AppFormWindowLayout {
            ScrollView {
                Form {
                    Section {
                        HStack {
                            Text(L10n.t(.screenCapturePermission))
                                .font(AppFont.caption)
                            Spacer()
                            Text(screenCaptureGranted ? L10n.t(.accessibilityGranted) : L10n.t(.accessibilityNotGranted))
                                .font(AppFont.caption)
                                .foregroundStyle(screenCaptureGranted ? .green : .orange)
                        }

                        HStack {
                            Button(L10n.t(.requestScreenCaptureAccess)) {
                                ScreenCapturePermissionManager.requestAccess()
                            }
                            .buttonStyle(.bordered)

                            Button(L10n.t(.openSystemSettings)) {
                                ScreenCapturePermissionManager.openSettings()
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(L10n.t(.screenCapturePermissionHint))
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Toggle(L10n.t(.screenshotShortcut), isOn: $screenshotShortcutEnabled)
                            .onChange(of: screenshotShortcutEnabled) { newValue in
                                PreferencesManager.shared.isScreenshotShortcutEnabled = newValue
                                ScreenshotGlobalHotKeyManager.register()
                            }
                        ShortcutRecorderRepresentable(combo: $screenshotShortcut) { combo in
                            PreferencesManager.shared.screenshotShortcut = combo
                            ScreenshotGlobalHotKeyManager.register()
                        }
                        .frame(height: 30)

                        Picker(L10n.t(.screenshotDefaultMode), selection: $screenshotDefaultMode) {
                            Text(L10n.t(.screenshotRegion)).tag(ScreenshotCaptureMode.region)
                            Text(L10n.t(.screenshotWindow)).tag(ScreenshotCaptureMode.window)
                            Text(L10n.t(.screenshotFullscreen)).tag(ScreenshotCaptureMode.fullscreen)
                        }
                        .onChange(of: screenshotDefaultMode) { newValue in
                            PreferencesManager.shared.screenshotDefaultMode = newValue
                        }

                        Picker(L10n.t(.screenshotPostAction), selection: $screenshotPostCaptureAction) {
                            ForEach(ScreenshotPostCaptureAction.allCases) { action in
                                Text(action.displayName()).tag(action)
                            }
                        }
                        .onChange(of: screenshotPostCaptureAction) { newValue in
                            PreferencesManager.shared.screenshotPostCaptureAction = newValue
                        }

                        Picker(L10n.t(.screenshotResolution), selection: $screenshotResolution) {
                            ForEach(ScreenshotResolution.allCases) { resolution in
                                Text(resolution.displayName()).tag(resolution)
                            }
                        }
                        .onChange(of: screenshotResolution) { newValue in
                            PreferencesManager.shared.screenshotResolution = newValue
                        }

                        Picker(L10n.t(.screenshotOCRLanguage), selection: $screenshotOCRLanguage) {
                            ForEach(ScreenshotOCRLanguage.allCases) { language in
                                Text(language.displayName()).tag(language)
                            }
                        }
                        .onChange(of: screenshotOCRLanguage) { newValue in
                            PreferencesManager.shared.screenshotOCRLanguage = newValue
                        }

                        Toggle(L10n.t(.screenshotMagnifier), isOn: $screenshotMagnifierEnabled)
                            .onChange(of: screenshotMagnifierEnabled) { newValue in
                                PreferencesManager.shared.isScreenshotMagnifierEnabled = newValue
                            }

                        Toggle(L10n.t(.screenshotElementSnap), isOn: $screenshotElementSnapEnabled)
                            .onChange(of: screenshotElementSnapEnabled) { newValue in
                                PreferencesManager.shared.isScreenshotElementSnapEnabled = newValue
                            }

                        if screenshotElementSnapEnabled && !accessibilityGranted {
                            Text(L10n.t(.screenshotElementSnapAccessibilityHint))
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle(L10n.t(.screenshotAutoSave), isOn: $screenshotAutoSaveEnabled)
                            .onChange(of: screenshotAutoSaveEnabled) { newValue in
                                PreferencesManager.shared.isScreenshotAutoSaveEnabled = newValue
                            }

                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.t(.screenshotSavePath))
                                    .font(AppFont.body)
                                Text(screenshotSaveDirectoryPath)
                                    .font(AppFont.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button(L10n.t(.screenshotChooseSavePath)) {
                                chooseScreenshotSaveDirectory()
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(!screenshotAutoSaveEnabled)
                        .opacity(screenshotAutoSaveEnabled ? 1 : 0.55)
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t(.screenshotShortcutDescription))
                            Text(L10n.t(.screenshotResolutionHint))
                            Text(L10n.t(.screenshotPostActionHint))
                            Text(L10n.t(.screenshotOCRLanguageHint))
                        }
                        .font(AppFont.caption)
                    }
                }
            }
        }
        .frame(width: AppWindowSize.screenshotSettings.width)
        .frame(minHeight: AppWindowSize.screenshotSettings.height, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityManager.isTrusted
            screenCaptureGranted = ScreenCapturePermissionManager.isAuthorized
        }
    }

    private func chooseScreenshotSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t(.ok)
        panel.directoryURL = URL(fileURLWithPath: screenshotSaveDirectoryPath, isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            screenshotSaveDirectoryPath = url.path
            PreferencesManager.shared.screenshotSaveDirectoryPath = url.path
        }
    }
}
