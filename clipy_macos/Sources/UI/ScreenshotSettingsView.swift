import AVFoundation
import SwiftUI

/// Screenshot preference sections, embedded page-by-page into the main
/// `SettingsView` document (one instance per page ID).
struct ScreenshotSettingsView: View {
  @EnvironmentObject private var languageObserver: AppLanguageObserver
  let pageID: String
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
  @State private var inputMonitoringGranted: Bool
  @State private var microphoneGranted: Bool
  @State private var cameraGranted: Bool

  // 录屏
  @State private var recordingOnStop: String
  @State private var recordingFPS: Int
  @State private var hideRecordingHUD: Bool
  @State private var recordSystemAudio: Bool
  @State private var recordMicAudio: Bool
  @State private var recordWebcam: Bool
  @State private var recordMouseHighlight: Bool
  @State private var recordKeystroke: Bool
  @State private var keystrokeShowAll: Bool
  @State private var webcamPosition: String
  @State private var webcamSize: String
  @State private var webcamShape: String

  // 输出与缩略图
  @State private var showFloatingThumbnail: Bool
  @State private var thumbnailStacking: Bool
  @State private var thumbnailScale: Double
  @State private var thumbnailCorner: String
  @State private var quickCaptureMode: Int
  @State private var captureCursor: Bool
  @State private var imageFormat: String
  @State private var imageQuality: Double
  @State private var downscaleRetina: Bool
  @State private var playCopySound: Bool

  // 滚动与绘制辅助
  @State private var scrollMaxHeight: Int
  @State private var scrollAutoScrollEnabled: Bool
  @State private var scrollAutoScrollSpeed: Int
  @State private var scrollFrozenDetection: Bool
  @State private var snapGuidesEnabled: Bool
  @State private var rememberLastTool: Bool
  @State private var showToolShortcutsInTooltips: Bool
  @State private var pencilPressureEnabled: Bool
  @State private var pencilSmoothMode: Int
  @State private var smartMarkerEnabled: Bool

  // 美化与特效
  @State private var beautifyEnabled: Bool
  @State private var beautifyMode: Int
  @State private var beautifyPadding: Double
  @State private var beautifyCornerRadius: Double
  @State private var beautifyShadowRadius: Double
  @State private var effectsBrightness: Double
  @State private var effectsContrast: Double
  @State private var effectsSaturation: Double
  @State private var effectsSharpness: Double

  init(pageID: String) {
    self.pageID = pageID
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
    #if CLIPY_CORE_TESTS
    if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil {
      _screenCaptureGranted = State(initialValue: false)
      _accessibilityGranted = State(initialValue: false)
      _inputMonitoringGranted = State(initialValue: false)
      _microphoneGranted = State(initialValue: false)
      _cameraGranted = State(initialValue: false)
    } else {
    _screenCaptureGranted = State(initialValue: ScreenCapturePermissionManager.isAuthorized)
    _accessibilityGranted = State(initialValue: AccessibilityManager.isTrusted)
    _inputMonitoringGranted = State(initialValue: KeystrokeOverlay.hasInputMonitoringPermission)
    _microphoneGranted = State(
      initialValue: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    _cameraGranted = State(
      initialValue: AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    }
    #else
    _screenCaptureGranted = State(initialValue: ScreenCapturePermissionManager.isAuthorized)
    _accessibilityGranted = State(initialValue: AccessibilityManager.isTrusted)
    _inputMonitoringGranted = State(initialValue: KeystrokeOverlay.hasInputMonitoringPermission)
    _microphoneGranted = State(
      initialValue: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    _cameraGranted = State(
      initialValue: AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    #endif

    _recordingOnStop = State(initialValue: prefs.recordingOnStop)
    _recordingFPS = State(initialValue: prefs.recordingFPS)
    _hideRecordingHUD = State(initialValue: prefs.hideRecordingHUD)
    _recordSystemAudio = State(initialValue: prefs.recordSystemAudio)
    _recordMicAudio = State(initialValue: prefs.recordMicAudio)
    _recordWebcam = State(initialValue: prefs.recordWebcam)
    _recordMouseHighlight = State(initialValue: prefs.recordMouseHighlight)
    _recordKeystroke = State(initialValue: prefs.recordKeystroke)
    _keystrokeShowAll = State(initialValue: prefs.keystrokeShowAll)
    _webcamPosition = State(initialValue: prefs.webcamPosition)
    _webcamSize = State(initialValue: prefs.webcamSize)
    _webcamShape = State(initialValue: prefs.webcamShape)

    _showFloatingThumbnail = State(initialValue: prefs.showFloatingThumbnail)
    _thumbnailStacking = State(initialValue: prefs.thumbnailStacking)
    _thumbnailScale = State(initialValue: prefs.thumbnailScale)
    _thumbnailCorner = State(initialValue: prefs.thumbnailCorner)
    _quickCaptureMode = State(initialValue: prefs.quickCaptureMode)
    _captureCursor = State(initialValue: prefs.captureCursor)
    _imageFormat = State(initialValue: prefs.imageFormat)
    _imageQuality = State(initialValue: prefs.imageQuality)
    _downscaleRetina = State(initialValue: prefs.downscaleRetina)
    _playCopySound = State(initialValue: prefs.playCopySound)

    _scrollMaxHeight = State(initialValue: prefs.scrollMaxHeight)
    _scrollAutoScrollEnabled = State(initialValue: prefs.scrollAutoScrollEnabled)
    _scrollAutoScrollSpeed = State(initialValue: prefs.scrollAutoScrollSpeed)
    _scrollFrozenDetection = State(initialValue: prefs.scrollFrozenDetection)
    _snapGuidesEnabled = State(initialValue: prefs.snapGuidesEnabled)
    _rememberLastTool = State(initialValue: prefs.rememberLastTool)
    _showToolShortcutsInTooltips = State(initialValue: prefs.showToolShortcutsInTooltips)
    _pencilPressureEnabled = State(initialValue: prefs.pencilPressureEnabled)
    _pencilSmoothMode = State(initialValue: prefs.pencilSmoothMode)
    _smartMarkerEnabled = State(initialValue: prefs.smartMarkerEnabled)

    _beautifyEnabled = State(initialValue: prefs.beautifyEnabled)
    _beautifyMode = State(initialValue: prefs.beautifyMode)
    _beautifyPadding = State(initialValue: prefs.beautifyPadding)
    _beautifyCornerRadius = State(initialValue: prefs.beautifyCornerRadius)
    _beautifyShadowRadius = State(initialValue: prefs.beautifyShadowRadius)
    _effectsBrightness = State(initialValue: prefs.effectsBrightness)
    _effectsContrast = State(initialValue: prefs.effectsContrast)
    _effectsSaturation = State(initialValue: prefs.effectsSaturation)
    _effectsSharpness = State(initialValue: prefs.effectsSharpness)
  }

  /// Prefix used for screenshot page IDs inside the main settings document.
  static let pagePrefix = "screenshot."

  /// Screenshot pages shown in the main settings sidebar. Permissions are
  /// rendered by the shared "permissions" page instead.
  static var settingsPages: [AppSettingsPage] {
    [
      .init(id: pagePrefix + "capture", title: L10n.t(.screenshot), symbol: "viewfinder"),
      .init(id: pagePrefix + "recording", title: L("Recording"), symbol: "record.circle"),
      .init(id: pagePrefix + "output", title: L10n.t(.designOutput), symbol: "square.and.arrow.down"),
      .init(id: pagePrefix + "scroll", title: L10n.t(.designDrawing), symbol: "pencil.tip.crop.circle"),
      .init(id: pagePrefix + "effects", title: L10n.t(.designEffects), symbol: "wand.and.stars"),
    ]
  }

  var body: some View {
    let _ = languageObserver.revision

    Group {
      if pageID == "permissions" { permissionsPage }
      if pageID == "capture" { capturePage }
      if pageID == "recording" { recordingPage }
      if pageID == "output" { outputPage }
      if pageID == "scroll" { scrollPage }
      if pageID == "effects" { effectsPage }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      refreshPermissionStatuses()
    }
  }

  // MARK: - 权限

  @ViewBuilder private var permissionsPage: some View {
    SettingsSubheader(settingsText("系统权限", "System Permissions"))
    SettingsCard {
      permissionRow(
        symbol: "display", tint: .blue,
        name: L("Screen Recording"),
        hint: L("Required for screenshots and recording"),
        granted: screenCaptureGranted,
        onRequest: { ScreenCapturePermissionManager.requestAccess() },
        onOpenSettings: { ScreenCapturePermissionManager.openSettings() }
      )
      permissionRow(
        symbol: "accessibility", tint: .purple,
        name: L("Accessibility"),
        hint: L("Paste simulation and element snap"),
        granted: accessibilityGranted,
        onRequest: { AccessibilityManager.requestSystemPrompt() },
        onOpenSettings: { AccessibilityManager.openSettings() }
      )
      permissionRow(
        symbol: "keyboard", tint: .orange,
        name: L("Input Monitoring"),
        hint: L("Keystroke display and mouse click highlight"),
        granted: inputMonitoringGranted,
        onRequest: { KeystrokeOverlay.requestInputMonitoringPermission() },
        onOpenSettings: { PermissionDeepLink.openInputMonitoringSettings() }
      )
      permissionRow(
        symbol: "mic", tint: .red,
        name: L("Microphone"),
        hint: L("Record voice during screen recording"),
        granted: microphoneGranted,
        onRequest: {
          AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
          }
        },
        onOpenSettings: { PermissionDeepLink.openMicrophoneSettings() }
      )
      permissionRow(
        symbol: "camera", tint: .green,
        name: L("Camera"),
        hint: L("Webcam overlay during recording"),
        granted: cameraGranted,
        onRequest: {
          AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
          }
        },
        onOpenSettings: { PermissionDeepLink.openCameraSettings() }
      )
    }
    SettingsFootnote(L10n.t(.screenCapturePermissionHint))
  }

  // MARK: - 截图

  @ViewBuilder private var capturePage: some View {
    SettingsCard {
      SettingsRow(title: L10n.t(.screenshotShortcut), detail: L10n.t(.screenshotShortcutDescription)) {
        ShortcutRecorderRepresentable(combo: $screenshotShortcut) { combo in
          PreferencesManager.shared.screenshotShortcut = combo
          ScreenshotGlobalHotKeyManager.register()
        }
        .frame(width: 150, height: 26)
        SettingsSwitch(isOn: $screenshotShortcutEnabled)
      }
      .onChange(of: screenshotShortcutEnabled) { newValue in
        PreferencesManager.shared.isScreenshotShortcutEnabled = newValue
        ScreenshotGlobalHotKeyManager.register()
      }
      SettingsRow(title: L10n.t(.screenshotDefaultMode)) {
        Picker("", selection: $screenshotDefaultMode) {
          Text(L10n.t(.screenshotRegion)).tag(ScreenshotCaptureMode.region)
          Text(L10n.t(.screenshotWindow)).tag(ScreenshotCaptureMode.window)
          Text(L10n.t(.screenshotFullscreen)).tag(ScreenshotCaptureMode.fullscreen)
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: screenshotDefaultMode) { newValue in
        PreferencesManager.shared.screenshotDefaultMode = newValue
      }
      SettingsRow(title: L10n.t(.screenshotPostAction), detail: L10n.t(.screenshotPostActionHint)) {
        Picker("", selection: $screenshotPostCaptureAction) {
          ForEach(ScreenshotPostCaptureAction.allCases) { action in
            Text(action.displayName()).tag(action)
          }
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: screenshotPostCaptureAction) { newValue in
        PreferencesManager.shared.screenshotPostCaptureAction = newValue
      }
      SettingsRow(title: L10n.t(.screenshotResolution), detail: L10n.t(.screenshotResolutionHint)) {
        Picker("", selection: $screenshotResolution) {
          ForEach(ScreenshotResolution.allCases) { resolution in
            Text(resolution.displayName()).tag(resolution)
          }
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: screenshotResolution) { newValue in
        PreferencesManager.shared.screenshotResolution = newValue
      }
      SettingsRow(title: L10n.t(.screenshotOCRLanguage), detail: L10n.t(.screenshotOCRLanguageHint)) {
        Picker("", selection: $screenshotOCRLanguage) {
          ForEach(ScreenshotOCRLanguage.allCases) { language in
            Text(language.displayName()).tag(language)
          }
        }
        .labelsHidden().fixedSize()
      }
      .onChange(of: screenshotOCRLanguage) { newValue in
        PreferencesManager.shared.screenshotOCRLanguage = newValue
      }
      SettingsRow(title: L10n.t(.screenshotMagnifier)) { SettingsSwitch(isOn: $screenshotMagnifierEnabled) }
        .onChange(of: screenshotMagnifierEnabled) { newValue in
          PreferencesManager.shared.isScreenshotMagnifierEnabled = newValue
        }
      SettingsRow(title: L10n.t(.screenshotElementSnap), detail: L10n.t(.screenshotElementSnapAccessibilityHint)) {
        SettingsSwitch(isOn: $screenshotElementSnapEnabled)
      }
      .onChange(of: screenshotElementSnapEnabled) { newValue in
        PreferencesManager.shared.isScreenshotElementSnapEnabled = newValue
      }
      SettingsRow(title: L10n.t(.screenshotAutoSave)) { SettingsSwitch(isOn: $screenshotAutoSaveEnabled) }
        .onChange(of: screenshotAutoSaveEnabled) { newValue in
          PreferencesManager.shared.isScreenshotAutoSaveEnabled = newValue
        }
      if screenshotAutoSaveEnabled {
        SettingsRow(title: L10n.t(.screenshotSavePath), detail: screenshotSaveDirectoryPath) {
          Button(L10n.t(.screenshotChooseSavePath)) { chooseScreenshotSaveDirectory() }
            .buttonStyle(SettingsButtonStyle())
        }
      }
    }
  }

  // MARK: - 录屏

  @ViewBuilder private var recordingPage: some View {
    SettingsCard {
      pickerRow(L("After Recording"), selection: $recordingOnStop, options: [
        ("editor", L("Open editor")), ("finder", L("Show in Finder")), ("clipboard", L("Copy to clipboard")),
      ]) { PreferencesManager.shared.recordingOnStop = $0 }
      pickerRow(L("Frame Rate (FPS)"), selection: $recordingFPS, options: [15, 24, 30, 60].map { ($0, "\($0)") }) {
        PreferencesManager.shared.recordingFPS = $0
      }
      toggleRow(L("Hide Recording Timer HUD"), isOn: $hideRecordingHUD) { PreferencesManager.shared.hideRecordingHUD = $0 }
      toggleRow(L("Record System Audio"), isOn: $recordSystemAudio) { PreferencesManager.shared.recordSystemAudio = $0 }
      toggleRow(L("Record Microphone"), isOn: $recordMicAudio) { PreferencesManager.shared.recordMicAudio = $0 }
      toggleRow(L("Webcam Overlay"), isOn: $recordWebcam) { PreferencesManager.shared.recordWebcam = $0 }
      if recordWebcam {
        pickerRow(L("Webcam Position"), selection: $webcamPosition, options: Self.cornerOptions) {
          PreferencesManager.shared.webcamPosition = $0
        }
        pickerRow(L("Webcam Size"), selection: $webcamSize, options: [
          ("small", L("Small")), ("medium", L("Medium")), ("large", L("Large")), ("xlarge", L("Huge")),
        ]) { PreferencesManager.shared.webcamSize = $0 }
        pickerRow(L("Webcam Shape"), selection: $webcamShape, options: [
          ("circle", L("Circle")), ("roundedRect", L("Rounded Rectangle")),
        ]) { PreferencesManager.shared.webcamShape = $0 }
      }
      toggleRow(L("Mouse Click Highlight"), isOn: $recordMouseHighlight) { PreferencesManager.shared.recordMouseHighlight = $0 }
      toggleRow(L("Keystroke Display"), isOn: $recordKeystroke) { PreferencesManager.shared.recordKeystroke = $0 }
      if recordKeystroke {
        pickerRow(L("Keystroke Mode"), selection: $keystrokeShowAll, options: [
          (false, L("Shortcuts Only")), (true, L("All Keystrokes")),
        ]) { PreferencesManager.shared.keystrokeShowAll = $0 }
      }
    }
  }

  // MARK: - 输出与缩略图

  @ViewBuilder private var outputPage: some View {
    SettingsSubheader(L("Output & Thumbnails"))
    SettingsCard {
      toggleRow(L("Show Floating Thumbnail After Capture"), isOn: $showFloatingThumbnail) {
        PreferencesManager.shared.showFloatingThumbnail = $0
      }
      if showFloatingThumbnail {
        toggleRow(L("Stack Thumbnails for Consecutive Captures"), isOn: $thumbnailStacking) {
          PreferencesManager.shared.thumbnailStacking = $0
        }
        pickerRow(L("Thumbnail Position"), selection: $thumbnailCorner, options: Self.cornerOptions) {
          PreferencesManager.shared.thumbnailCorner = $0
        }
        SettingsRow(title: L("Thumbnail Size")) {
          SettingsSlider(value: $thumbnailScale, range: 0.5...2.0, step: 0.1, format: { String(format: "%.1f×", $0) }) {
            PreferencesManager.shared.thumbnailScale = thumbnailScale
          }
        }
      }
      pickerRow(L("Quick Capture Action"), selection: $quickCaptureMode, options: [
        (0, L("Save Only")), (1, L("Copy to clipboard")), (2, L("Save and Copy")), (3, L("Thumbnail Only")),
      ]) { PreferencesManager.shared.quickCaptureMode = $0 }
      toggleRow(L("Capture Mouse Cursor"), isOn: $captureCursor) { PreferencesManager.shared.captureCursor = $0 }
      toggleRow(L("Downscale Retina Screenshots to 1×"), isOn: $downscaleRetina) { PreferencesManager.shared.downscaleRetina = $0 }
      toggleRow(L("Play Sound After Capture"), isOn: $playCopySound) { PreferencesManager.shared.playCopySound = $0 }
      pickerRow(L("Save Format"), selection: $imageFormat, options: [
        ("png", "PNG"), ("jpeg", "JPEG"), ("heic", "HEIC"), ("webp", "WebP"),
      ]) { PreferencesManager.shared.imageFormat = $0 }
      if imageFormat != "png" {
        SettingsRow(title: L("Quality")) {
          SettingsSlider(value: $imageQuality, range: 0.1...1.0, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) }) {
            PreferencesManager.shared.imageQuality = imageQuality
          }
        }
      }
    }
  }

  // MARK: - 滚动与绘制辅助

  @ViewBuilder private var scrollPage: some View {
    SettingsSubheader(L("Scroll Capture & Drawing Aids"))
    SettingsCard {
      SettingsRow(title: L("Scroll Capture"))
      SettingsRow(title: String(format: L("Max Height: %d px"), scrollMaxHeight)) {
        Stepper("", value: $scrollMaxHeight, in: 2000...40000, step: 1000).labelsHidden().controlSize(.small)
      }
      .onChange(of: scrollMaxHeight) { newValue in
        PreferencesManager.shared.scrollMaxHeight = newValue
      }
      toggleRow(L("Auto Scroll"), isOn: $scrollAutoScrollEnabled) { PreferencesManager.shared.scrollAutoScrollEnabled = $0 }
      if scrollAutoScrollEnabled {
        pickerRow(L("Auto Scroll Speed"), selection: $scrollAutoScrollSpeed, options: (1...5).map { ($0, "\($0)") }) {
          PreferencesManager.shared.scrollAutoScrollSpeed = $0
        }
      }
      toggleRow(L("Detect Frozen Headers"), isOn: $scrollFrozenDetection) { PreferencesManager.shared.scrollFrozenDetection = $0 }
      toggleRow(L("Show Alignment Guides"), isOn: $snapGuidesEnabled) { PreferencesManager.shared.snapGuidesEnabled = $0 }
      toggleRow(L("Remember Last Used Tool"), isOn: $rememberLastTool) { PreferencesManager.shared.rememberLastTool = $0 }
      toggleRow(L("Show Shortcuts in Tooltips"), isOn: $showToolShortcutsInTooltips) {
        PreferencesManager.shared.showToolShortcutsInTooltips = $0
      }
      toggleRow(L("Pencil Pressure (Apple Pencil)"), isOn: $pencilPressureEnabled) {
        PreferencesManager.shared.pencilPressureEnabled = $0
      }
      pickerRow(L("Pencil Smoothing"), selection: $pencilSmoothMode, options: [
        (0, L("None")), (1, L("Smooth")), (2, L("Refined")),
      ]) { PreferencesManager.shared.pencilSmoothMode = $0 }
      toggleRow(L("Smart Marker (Fit Text Line Height)"), isOn: $smartMarkerEnabled) {
        PreferencesManager.shared.smartMarkerEnabled = $0
      }
    }
  }

  // MARK: - 美化与特效

  @ViewBuilder private var effectsPage: some View {
    SettingsSubheader(L("Beautify & Image Effects (Defaults)"))
    SettingsCard {
      toggleRow(L("Enable Beautify Wrap by Default"), isOn: $beautifyEnabled) { PreferencesManager.shared.beautifyEnabled = $0 }
      pickerRow(L("Beautify Mode"), selection: $beautifyMode, options: [
        (0, L("Window (with Traffic Lights)")), (1, L("Rounded")),
      ]) { PreferencesManager.shared.beautifyMode = $0 }
      sliderRow(L("Margin"), value: $beautifyPadding, range: 0...120, step: 2, format: { "\(Int($0))" }) {
        PreferencesManager.shared.beautifyPadding = beautifyPadding
      }
      sliderRow(L("Rounded"), value: $beautifyCornerRadius, range: 0...40, step: 1, format: { "\(Int($0))" }) {
        PreferencesManager.shared.beautifyCornerRadius = beautifyCornerRadius
      }
      sliderRow(L("Shadow"), value: $beautifyShadowRadius, range: 0...60, step: 1, format: { "\(Int($0))" }) {
        PreferencesManager.shared.beautifyShadowRadius = beautifyShadowRadius
      }
      sliderRow(L("Brightness"), value: $effectsBrightness, range: -0.5...0.5, format: { String(format: "%.1f", $0) }) {
        PreferencesManager.shared.effectsBrightness = effectsBrightness
      }
      sliderRow(L("Contrast"), value: $effectsContrast, range: 0.5...1.5, format: { String(format: "%.1f", $0) }) {
        PreferencesManager.shared.effectsContrast = effectsContrast
      }
      sliderRow(L("Saturation"), value: $effectsSaturation, range: 0...2, format: { String(format: "%.1f", $0) }) {
        PreferencesManager.shared.effectsSaturation = effectsSaturation
      }
      sliderRow(L("Sharpness"), value: $effectsSharpness, range: 0...1, format: { String(format: "%.1f", $0) }) {
        PreferencesManager.shared.effectsSharpness = effectsSharpness
      }
    }
  }

  // MARK: - Row helpers

  private static var cornerOptions: [(String, String)] {
    [("bottomRight", L("Bottom Right")), ("bottomLeft", L("Bottom Left")),
     ("topRight", L("Top Right")), ("topLeft", L("Top Left"))]
  }

  private func toggleRow(_ title: String, isOn: Binding<Bool>, save: @escaping (Bool) -> Void) -> some View {
    SettingsRow(title: title) { SettingsSwitch(isOn: isOn) }
      .onChange(of: isOn.wrappedValue) { save($0) }
  }

  private func pickerRow<Value: Hashable>(
    _ title: String, selection: Binding<Value>, options: [(Value, String)], save: @escaping (Value) -> Void
  ) -> some View {
    SettingsRow(title: title) {
      Picker("", selection: selection) {
        ForEach(options.indices, id: \.self) { index in
          Text(options[index].1).tag(options[index].0)
        }
      }
      .labelsHidden().fixedSize()
    }
    .onChange(of: selection.wrappedValue) { save($0) }
  }

  private func sliderRow(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil,
    format: @escaping (Double) -> String, commit: @escaping () -> Void
  ) -> some View {
    SettingsRow(title: title) {
      SettingsSlider(value: value, range: range, step: step, format: format, onCommit: commit)
    }
  }

  /// Re-read every permission status (called on activate + after a request dialog closes).
  private func refreshPermissionStatuses() {
    #if CLIPY_CORE_TESTS
    if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return }
    #endif
    screenCaptureGranted = ScreenCapturePermissionManager.isAuthorized
    accessibilityGranted = AccessibilityManager.isTrusted
    inputMonitoringGranted = KeystrokeOverlay.hasInputMonitoringPermission
    microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
  }

  /// Permission row (V3): tinted icon, name + purpose, and either a green
  /// "granted" tag (click opens System Settings) or a Request button.
  private func permissionRow(
    symbol: String,
    tint: SettingsPalette.Tint,
    name: String,
    hint: String,
    granted: Bool,
    onRequest: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void
  ) -> some View {
    SettingsRow(icon: SettingsRowIcon(symbol: symbol, tint: tint), title: name, detail: hint) {
      if granted {
        Button(action: onOpenSettings) {
          SettingsStatusTag(text: L10n.t(.accessibilityGranted))
        }
        .buttonStyle(.plain)
        .help(L10n.t(.openSystemSettings))
      } else {
        Button(L("Request Permission"), action: onRequest)
          .buttonStyle(SettingsButtonStyle(prominent: true))
          .help(L("Request Permission"))
      }
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
