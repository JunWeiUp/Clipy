import AVFoundation
import SwiftUI

struct ScreenshotSettingsView: View {
  @EnvironmentObject private var languageObserver: AppLanguageObserver
  @State private var selectedSettingsPage = "capture"
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
    _inputMonitoringGranted = State(initialValue: KeystrokeOverlay.hasInputMonitoringPermission)
    _microphoneGranted = State(
      initialValue: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    _cameraGranted = State(
      initialValue: AVCaptureDevice.authorizationStatus(for: .video) == .authorized)

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

  private var settingsPages: [AppSettingsPage] {
    [
      .init(id: "capture", title: L10n.t(.screenshot), symbol: "viewfinder"),
      .init(id: "recording", title: L("Recording"), symbol: "record.circle"),
      .init(id: "output", title: L10n.t(.designOutput), symbol: "square.and.arrow.down"),
      .init(id: "scroll", title: L10n.t(.designDrawing), symbol: "pencil.tip.crop.circle"),
      .init(id: "effects", title: L10n.t(.designEffects), symbol: "slider.horizontal.3"),
      .init(id: "permissions", title: L10n.t(.designPermissions), symbol: "hand.raised"),
    ]
  }

  var body: some View {
    let _ = languageObserver.revision

    AppSettingsLayout(selection: $selectedSettingsPage, pages: settingsPages) { pageID in

      if pageID == "permissions" {
        // MARK: - 权限
        Section {
          permissionRow(
            name: L("Screen Recording"),
            hint: L("Required for screenshots and recording"),
            granted: screenCaptureGranted,
            onRequest: { ScreenCapturePermissionManager.requestAccess() },
            onOpenSettings: { ScreenCapturePermissionManager.openSettings() }
          )
          permissionRow(
            name: L("Accessibility"),
            hint: L("Paste simulation and element snap"),
            granted: accessibilityGranted,
            onRequest: { AccessibilityManager.requestSystemPrompt() },
            onOpenSettings: { AccessibilityManager.openSettings() }
          )
          permissionRow(
            name: L("Input Monitoring"),
            hint: L("Keystroke display and mouse click highlight"),
            granted: inputMonitoringGranted,
            onRequest: { KeystrokeOverlay.requestInputMonitoringPermission() },
            onOpenSettings: { PermissionDeepLink.openInputMonitoringSettings() }
          )
          permissionRow(
            name: L("Microphone"),
            hint: L("Record voice during screen recording"),
            granted: microphoneGranted,
            onRequest: {
              AVCaptureDevice.requestAccess(for: .audio) { _ in refreshPermissionStatuses() }
            },
            onOpenSettings: { PermissionDeepLink.openMicrophoneSettings() }
          )
          permissionRow(
            name: L("Camera"),
            hint: L("Webcam overlay during recording"),
            granted: cameraGranted,
            onRequest: {
              AVCaptureDevice.requestAccess(for: .video) { _ in refreshPermissionStatuses() }
            },
            onOpenSettings: { PermissionDeepLink.openCameraSettings() }
          )
        } header: {
          Text(L("Permissions"))
        } footer: {
          Text(L10n.t(.screenCapturePermissionHint))
            .font(AppFont.caption)
        }

      }
      if pageID == "capture" {
        // MARK: - 截图(原有)
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
              Text(L10n.t(.screenshotSavePath)).font(AppFont.body)
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
        } header: {
          Text(L("Screenshot"))
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
      if pageID == "recording" {
        // MARK: - 录屏
        Section(L("Recording")) {
          Picker(L("After Recording"), selection: $recordingOnStop) {
            Text(L("Open editor")).tag("editor")
            Text(L("Show in Finder")).tag("finder")
            Text(L("Copy to clipboard")).tag("clipboard")
          }
          .onChange(of: recordingOnStop) { newValue in
            PreferencesManager.shared.recordingOnStop = newValue
          }
          Picker(L("Frame Rate (FPS)"), selection: $recordingFPS) {
            ForEach([15, 24, 30, 60], id: \.self) { fps in
              Text("\(fps)").tag(fps)
            }
          }
          .onChange(of: recordingFPS) { newValue in
            PreferencesManager.shared.recordingFPS = newValue
          }
          Toggle(L("Hide Recording Timer HUD"), isOn: $hideRecordingHUD)
            .onChange(of: hideRecordingHUD) { newValue in
              PreferencesManager.shared.hideRecordingHUD = newValue
            }
          Toggle(L("Record System Audio"), isOn: $recordSystemAudio)
            .onChange(of: recordSystemAudio) { newValue in
              PreferencesManager.shared.recordSystemAudio = newValue
            }
          Toggle(L("Record Microphone"), isOn: $recordMicAudio)
            .onChange(of: recordMicAudio) { newValue in
              PreferencesManager.shared.recordMicAudio = newValue
            }
          Toggle(L("Webcam Overlay"), isOn: $recordWebcam)
            .onChange(of: recordWebcam) { newValue in
              PreferencesManager.shared.recordWebcam = newValue
            }
          if recordWebcam {
            Picker(L("Webcam Position"), selection: $webcamPosition) {
              Text(L("Bottom Right")).tag("bottomRight")
              Text(L("Bottom Left")).tag("bottomLeft")
              Text(L("Top Right")).tag("topRight")
              Text(L("Top Left")).tag("topLeft")
            }
            .onChange(of: webcamPosition) { newValue in
              PreferencesManager.shared.webcamPosition = newValue
            }
            Picker(L("Webcam Size"), selection: $webcamSize) {
              Text(L("Small")).tag("small")
              Text(L("Medium")).tag("medium")
              Text(L("Large")).tag("large")
              Text(L("Huge")).tag("xlarge")
            }
            .onChange(of: webcamSize) { newValue in
              PreferencesManager.shared.webcamSize = newValue
            }
            Picker(L("Webcam Shape"), selection: $webcamShape) {
              Text(L("Circle")).tag("circle")
              Text(L("Rounded Rectangle")).tag("roundedRect")
            }
            .onChange(of: webcamShape) { newValue in
              PreferencesManager.shared.webcamShape = newValue
            }
          }
          Toggle(L("Mouse Click Highlight"), isOn: $recordMouseHighlight)
            .onChange(of: recordMouseHighlight) { newValue in
              PreferencesManager.shared.recordMouseHighlight = newValue
            }
          Toggle(L("Keystroke Display"), isOn: $recordKeystroke)
            .onChange(of: recordKeystroke) { newValue in
              PreferencesManager.shared.recordKeystroke = newValue
            }
          if recordKeystroke {
            Picker(L("Keystroke Mode"), selection: $keystrokeShowAll) {
              Text(L("Shortcuts Only")).tag(false)
              Text(L("All Keystrokes")).tag(true)
            }
            .onChange(of: keystrokeShowAll) { newValue in
              PreferencesManager.shared.keystrokeShowAll = newValue
            }
          }
        }

      }
      if pageID == "output" {
        // MARK: - 输出与缩略图
        Section(L("Output & Thumbnails")) {
          Toggle(L("Show Floating Thumbnail After Capture"), isOn: $showFloatingThumbnail)
            .onChange(of: showFloatingThumbnail) { newValue in
              PreferencesManager.shared.showFloatingThumbnail = newValue
            }
          if showFloatingThumbnail {
            Toggle(L("Stack Thumbnails for Consecutive Captures"), isOn: $thumbnailStacking)
              .onChange(of: thumbnailStacking) { newValue in
                PreferencesManager.shared.thumbnailStacking = newValue
              }
            Picker(L("Thumbnail Position"), selection: $thumbnailCorner) {
              Text(L("Bottom Right")).tag("bottomRight")
              Text(L("Bottom Left")).tag("bottomLeft")
              Text(L("Top Right")).tag("topRight")
              Text(L("Top Left")).tag("topLeft")
            }
            .onChange(of: thumbnailCorner) { newValue in
              PreferencesManager.shared.thumbnailCorner = newValue
            }
            HStack {
              Text(L("Thumbnail Size"))
              Spacer()
              Slider(value: $thumbnailScale, in: 0.5...2.0, step: 0.1) { editing in
                if !editing {
                  PreferencesManager.shared.thumbnailScale = thumbnailScale
                }
              }
              Text(String(format: "%.1f×", thumbnailScale))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            }
          }
          Picker(L("Quick Capture Action"), selection: $quickCaptureMode) {
            Text(L("Save Only")).tag(0)
            Text(L("Copy to clipboard")).tag(1)
            Text(L("Save and Copy")).tag(2)
            Text(L("Thumbnail Only")).tag(3)
          }
          .onChange(of: quickCaptureMode) { newValue in
            PreferencesManager.shared.quickCaptureMode = newValue
          }
          Toggle(L("Capture Mouse Cursor"), isOn: $captureCursor)
            .onChange(of: captureCursor) { newValue in
              PreferencesManager.shared.captureCursor = newValue
            }
          Toggle(L("Downscale Retina Screenshots to 1×"), isOn: $downscaleRetina)
            .onChange(of: downscaleRetina) { newValue in
              PreferencesManager.shared.downscaleRetina = newValue
            }
          Toggle(L("Play Sound After Capture"), isOn: $playCopySound)
            .onChange(of: playCopySound) { newValue in
              PreferencesManager.shared.playCopySound = newValue
            }
          Picker(L("Save Format"), selection: $imageFormat) {
            Text("PNG").tag("png")
            Text("JPEG").tag("jpeg")
            Text("HEIC").tag("heic")
            Text("WebP").tag("webp")
          }
          .onChange(of: imageFormat) { newValue in
            PreferencesManager.shared.imageFormat = newValue
          }
          if imageFormat != "png" {
            HStack {
              Text(L("Quality"))
              Spacer()
              Slider(value: $imageQuality, in: 0.1...1.0, step: 0.05) { editing in
                if !editing {
                  PreferencesManager.shared.imageQuality = imageQuality
                }
              }
              Text(String(format: "%.0f%%", imageQuality * 100))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            }
          }
        }

      }
      if pageID == "scroll" {
        // MARK: - 滚动与绘制辅助
        Section(L("Scroll Capture & Drawing Aids")) {
          Text(L("Scroll Capture")).font(AppFont.body)
          Stepper(
            String(format: L("Max Height: %d px"), scrollMaxHeight), value: $scrollMaxHeight,
            in: 2000...40000, step: 1000
          )
          .onChange(of: scrollMaxHeight) { newValue in
            PreferencesManager.shared.scrollMaxHeight = newValue
          }
          Toggle(L("Auto Scroll"), isOn: $scrollAutoScrollEnabled)
            .onChange(of: scrollAutoScrollEnabled) { newValue in
              PreferencesManager.shared.scrollAutoScrollEnabled = newValue
            }
          if scrollAutoScrollEnabled {
            Picker(L("Auto Scroll Speed"), selection: $scrollAutoScrollSpeed) {
              ForEach(1...5, id: \.self) { s in
                Text("\(s)").tag(s)
              }
            }
            .onChange(of: scrollAutoScrollSpeed) { newValue in
              PreferencesManager.shared.scrollAutoScrollSpeed = newValue
            }
          }
          Toggle(L("Detect Frozen Headers"), isOn: $scrollFrozenDetection)
            .onChange(of: scrollFrozenDetection) { newValue in
              PreferencesManager.shared.scrollFrozenDetection = newValue
            }
          Divider()
          Toggle(L("Show Alignment Guides"), isOn: $snapGuidesEnabled)
            .onChange(of: snapGuidesEnabled) { newValue in
              PreferencesManager.shared.snapGuidesEnabled = newValue
            }
          Toggle(L("Remember Last Used Tool"), isOn: $rememberLastTool)
            .onChange(of: rememberLastTool) { newValue in
              PreferencesManager.shared.rememberLastTool = newValue
            }
          Toggle(L("Show Shortcuts in Tooltips"), isOn: $showToolShortcutsInTooltips)
            .onChange(of: showToolShortcutsInTooltips) { newValue in
              PreferencesManager.shared.showToolShortcutsInTooltips = newValue
            }
          Toggle(L("Pencil Pressure (Apple Pencil)"), isOn: $pencilPressureEnabled)
            .onChange(of: pencilPressureEnabled) { newValue in
              PreferencesManager.shared.pencilPressureEnabled = newValue
            }
          Picker(L("Pencil Smoothing"), selection: $pencilSmoothMode) {
            Text(L("None")).tag(0)
            Text(L("Smooth")).tag(1)
            Text(L("Refined")).tag(2)
          }
          .onChange(of: pencilSmoothMode) { newValue in
            PreferencesManager.shared.pencilSmoothMode = newValue
          }
          Toggle(L("Smart Marker (Fit Text Line Height)"), isOn: $smartMarkerEnabled)
            .onChange(of: smartMarkerEnabled) { newValue in
              PreferencesManager.shared.smartMarkerEnabled = newValue
            }
        }

      }
      if pageID == "effects" {
        // MARK: - 美化与特效
        Section(L("Beautify & Image Effects (Defaults)")) {
          Toggle(L("Enable Beautify Wrap by Default"), isOn: $beautifyEnabled)
            .onChange(of: beautifyEnabled) { newValue in
              PreferencesManager.shared.beautifyEnabled = newValue
            }
          Picker(L("Beautify Mode"), selection: $beautifyMode) {
            Text(L("Window (with Traffic Lights)")).tag(0)
            Text(L("Rounded")).tag(1)
          }
          .onChange(of: beautifyMode) { newValue in
            PreferencesManager.shared.beautifyMode = newValue
          }
          HStack {
            Text(L("Margin"))
            Spacer()
            Slider(value: $beautifyPadding, in: 0...120, step: 2) { editing in
              if !editing {
                PreferencesManager.shared.beautifyPadding = beautifyPadding
              }
            }
            Text("\(Int(beautifyPadding))")
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 32, alignment: .trailing)
          }
          HStack {
            Text(L("Rounded"))
            Spacer()
            Slider(value: $beautifyCornerRadius, in: 0...40, step: 1) { editing in
              if !editing {
                PreferencesManager.shared.beautifyCornerRadius = beautifyCornerRadius
              }
            }
            Text("\(Int(beautifyCornerRadius))")
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 32, alignment: .trailing)
          }
          HStack {
            Text(L("Shadow"))
            Spacer()
            Slider(value: $beautifyShadowRadius, in: 0...60, step: 1) { editing in
              if !editing {
                PreferencesManager.shared.beautifyShadowRadius = beautifyShadowRadius
              }
            }
            Text("\(Int(beautifyShadowRadius))")
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 32, alignment: .trailing)
          }
          Divider()
          HStack {
            Text(L("Brightness"))
            Spacer()
            Slider(value: $effectsBrightness, in: -0.5...0.5) { editing in
              if !editing {
                PreferencesManager.shared.effectsBrightness = effectsBrightness
              }
            }
            Text(String(format: "%+.2f", effectsBrightness))
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 44, alignment: .trailing)
          }
          HStack {
            Text(L("Contrast"))
            Spacer()
            Slider(value: $effectsContrast, in: 0.5...1.5) { editing in
              if !editing {
                PreferencesManager.shared.effectsContrast = effectsContrast
              }
            }
            Text(String(format: "%.2f", effectsContrast))
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 44, alignment: .trailing)
          }
          HStack {
            Text(L("Saturation"))
            Spacer()
            Slider(value: $effectsSaturation, in: 0...2) { editing in
              if !editing {
                PreferencesManager.shared.effectsSaturation = effectsSaturation
              }
            }
            Text(String(format: "%.2f", effectsSaturation))
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 44, alignment: .trailing)
          }
          HStack {
            Text(L("Sharpness"))
            Spacer()
            Slider(value: $effectsSharpness, in: 0...1) { editing in
              if !editing {
                PreferencesManager.shared.effectsSharpness = effectsSharpness
              }
            }
            Text(String(format: "%.2f", effectsSharpness))
              .font(AppFont.caption)
              .foregroundStyle(.secondary)
              .frame(width: 44, alignment: .trailing)
          }
        }
      }

    }
    .frame(minWidth: AppWindowSize.settingsMin.width)
    .frame(minHeight: AppWindowSize.settingsMin.height, alignment: .top)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      refreshPermissionStatuses()
    }
  }

  /// Re-read every permission status (called on activate + after a request dialog closes).
  private func refreshPermissionStatuses() {
    screenCaptureGranted = ScreenCapturePermissionManager.isAuthorized
    accessibilityGranted = AccessibilityManager.isTrusted
    inputMonitoringGranted = KeystrokeOverlay.hasInputMonitoringPermission
    microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
  }

  /// Compact single-line permission row — exactly four elements horizontally:
  /// status dot · name · hint · status text. No buttons: clicking the row
  /// requests the permission (first time) or opens System Settings (already
  /// granted). This keeps the 5-row permission block minimal.
  @ViewBuilder
  private func permissionRow(
    name: String,
    hint: String,
    granted: Bool,
    onRequest: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void
  ) -> some View {
    HStack(spacing: AppSpacing.sm) {
      Circle()
        .fill(granted ? Color.green : Color.orange)
        .frame(width: 8, height: 8)
      Text(name).font(AppFont.body)
      Text(hint)
        .font(AppFont.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: AppSpacing.sm)
      Text(granted ? L10n.t(.accessibilityGranted) : L10n.t(.accessibilityNotGranted))
        .font(AppFont.caption)
        .foregroundStyle(granted ? .green : .orange)
    }
    .contentShape(Rectangle())
    .onTapGesture { granted ? onOpenSettings() : onRequest() }
    .help(granted ? L10n.t(.openSystemSettings) : L("Request Permission"))
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
