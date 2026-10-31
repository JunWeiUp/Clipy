import Cocoa

extension Notification.Name {
    static let toolbarColorsDidChange = Notification.Name("toolbarColorsDidChange")
}

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction {
    case tool(AnnotationTool)
    case color
    case sizeDisplay
    case undo
    case redo
    case copy
    case save
    case pin
    case ocr
    case autoRedact
    case beautify
    case beautifyStyle
    case cancel
    case moveSelection
    case delayCapture
    case upload
    case share
    case removeBackground
    case invertColors
    case loupe
    case translate
    case record  // enters recording mode (shows recording toolbar)
    case startRecord  // actually starts recording
    case stopRecord
    case mouseHighlight
    case systemAudio
    case micAudio
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
    case showKeystrokes
    case webcam
    case recordSettings  // recording mode: open format/FPS/when-done popover
    case effects  // image effects (CIFilter adjustments + presets)
    case toggleAnnotationTools  // V3 capture bar: show / hide the annotation strip + options row
}

/// V3 capture/recording bars use labelled buttons (mac-capture.html `.capbar`,
/// mac-recording.html `.ctl`); the annotation strip keeps square icons.
enum ToolbarButtonStyle {
    case icon      // 32pt square icon
    case mode      // icon above label (capture bar modes)
    case option    // inline icon + label
    case primary   // filled call-to-action (Copy / Start Recording)
    case toggle    // inline icon + label, dimmed when off
    case square    // 36pt icon tile (recording bar)
    case close     // 32pt round ×
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let tooltip: String
    var isSelected: Bool = false
    var tintColor: NSColor = ToolbarLayout.iconColor
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
    var label: String? = nil
    var style: ToolbarButtonStyle = .icon
    /// Draw a hairline separator before this button.
    var groupStart: Bool = false
    /// Fill for `.primary` buttons (defaults to the accent color).
    var fillColor: NSColor? = nil
}

enum ToolbarCustomAction: Int {
    #if !OFFLINE
    case upload = 1001
    #endif
    case pin = 1002
    case ocr = 1003
    case beautify = 1004
    case removeBackground = 1005
    case autoRedact = 1006
    case reserved1007 = 1007
    case translate = 1008
    case record = 1009
    case scrollCapture = 1010
    case invertColors = 1011
    case share = 1012
    case effects = 1013

    static var allKnownActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [
            .pin, .ocr, .beautify, .removeBackground, .autoRedact, .reserved1007,
            .translate, .record, .scrollCapture, .invertColors, .share, .effects,
        ])
        return actions
    }

    static var bottomToolbarActions: [ToolbarCustomAction] {
        [.invertColors, .effects, .beautify, .removeBackground]
    }

    static var rightToolbarActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = [.share]
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .translate, .scrollCapture, .record])
        return actions
    }

    var settingsLabel: String {
        switch self {
        #if !OFFLINE
        case .upload: return L("Upload")
        #endif
        case .pin: return L("Pin (floating window)")
        case .ocr: return L("OCR & QR")
        case .beautify: return L("Beautify")
        case .removeBackground: return L("Remove Background")
        case .autoRedact: return L("Auto-Redact sensitive data")
        case .reserved1007: return ""
        case .translate: return L("Translate")
        case .record: return L("Record screen")
        case .scrollCapture: return L("Scroll Capture")
        case .invertColors: return L("Invert Colors")
        case .share: return L("Share")
        case .effects: return L("Adjust (Image Effects)")
        }
    }

    func makeToolbarButton(
        beautifyEnabled: Bool = false,
        translateEnabled: Bool = false,
        effectsActive: Bool = false,
        isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> ToolbarButton? {
        switch self {
        #if !OFFLINE
        case .upload:
            var button = ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", tooltip: L("Upload"))
            button.hasContextMenu = true
            return button
        #endif
        case .pin:
            return ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin"))
        case .ocr:
            return ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", tooltip: L("OCR & QR"))
        case .beautify:
            var button = ToolbarButton(action: .beautify, sfSymbol: "sparkles", tooltip: L("Beautify"))
            if beautifyEnabled {
                button.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            return button
        case .removeBackground:
            if #available(macOS 14.0, *) {
                return ToolbarButton(
                    action: .removeBackground,
                    sfSymbol: "person.crop.circle.dashed",
                    tooltip: L("Remove Background")
                )
            }
            return nil
        case .autoRedact, .reserved1007:
            return nil
        case .translate:
            var button = ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: L("Translate"))
            button.isSelected = translateEnabled
            button.hasContextMenu = true
            return button
        case .record:
            guard !isEditorMode else { return nil }
            var button = ToolbarButton(action: .record, sfSymbol: "video.fill", tooltip: L("Record"))
            button.tintColor = ToolbarLayout.iconColor
            return button
        case .scrollCapture:
            guard !isRecording && !isEditorMode else { return nil }
            return ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", tooltip: L("Scroll Capture"))
        case .invertColors:
            return ToolbarButton(
                action: .invertColors,
                sfSymbol: "circle.righthalf.filled.inverse",
                tooltip: L("Invert Colors")
            )
        case .share:
            return ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: L("Share"))
        case .effects:
            var button = ToolbarButton(action: .effects, sfSymbol: "slider.horizontal.3", tooltip: L("Adjust"))
            if effectsActive {
                button.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            return button
        }
    }
}

enum ToolbarActionPreferences {
    static let enabledDefaultsKey = "enabledActions"
    static let knownDefaultsKey = "knownActionTags"

    static var allKnownRawValues: [Int] {
        ToolbarCustomAction.allKnownActions.map(\.rawValue)
    }

    static var defaultEnabledRawValues: [Int] {
        allKnownRawValues
    }

    static func enabledRawValuesAfterMigration() -> [Int]? {
        var enabledActions = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int]
        let knownActionTags = UserDefaults.standard.array(forKey: knownDefaultsKey) as? [Int]
        let newTags = allKnownRawValues.filter { !(knownActionTags ?? []).contains($0) }

        if !newTags.isEmpty {
            if enabledActions == nil {
                enabledActions = allKnownRawValues
            } else if knownActionTags == nil {
                // Upgrading from a version before knownActionTags tracking was added.
            } else {
                enabledActions = enabledActions! + newTags
            }
            UserDefaults.standard.set(enabledActions, forKey: enabledDefaultsKey)
            UserDefaults.standard.set(allKnownRawValues, forKey: knownDefaultsKey)
        }

        return enabledActions
    }

    static func isEnabled(_ action: ToolbarCustomAction, in enabledActions: [Int]?) -> Bool {
        enabledActions == nil || enabledActions!.contains(action.rawValue)
    }
}

class ToolbarLayout {

    // Capture tools share the app accent, with dark chrome for canvas contrast.
    // Explicit user-customized toolbar colors continue to take precedence.
    static let defaultAccentColor = NSColor.controlAccentColor
    static let defaultIconColor = NSColor.white
    static let defaultBgColor = NSColor(white: 0.12, alpha: 1.0)

    // User-customizable colors — read from UserDefaults with defaults matching the original look
    static var accentColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarAccentColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultAccentColor
    }
    static var iconColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarIconColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultIconColor
    }
    static var bgColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarBgColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultBgColor
    }
    static var handleColor: NSColor { accentColor }
    static let cornerRadius: CGFloat = AppCornerRadius.medium

    /// Save accent color to UserDefaults.
    static func saveAccentColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarAccentColor")
        }
    }

    /// Save icon color to UserDefaults.
    static func saveIconColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarIconColor")
        }
    }

    /// Appearance matching the toolbar background brightness.
    /// Dark background → `.darkAqua`, light background → `.aqua`.
    static var appearance: NSAppearance? {
        let color = bgColor.usingColorSpace(.deviceRGB) ?? bgColor
        var brightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return NSAppearance(named: brightness > 0.5 ? .aqua : .darkAqua)
    }

    /// Save background color to UserDefaults.
    static func saveBgColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarBgColor")
        }
    }

    /// Reset all colors to defaults.
    static func resetColors() {
        UserDefaults.standard.removeObject(forKey: "toolbarAccentColor")
        UserDefaults.standard.removeObject(forKey: "toolbarIconColor")
        UserDefaults.standard.removeObject(forKey: "toolbarBgColor")
    }

    // Bottom toolbar items (drawing tools + colors + undo/redo + processing actions)
    static func bottomButtons(
        selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false,
        beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, isRecording: Bool = false,
        effectsActive: Bool = false
    ) -> [ToolbarButton] {
        // Hide the bottom bar entirely while recording
        if isRecording { return [] }

        var buttons: [ToolbarButton] = []

        // Get enabled tools from UserDefaults — migrate: only add tools that are brand-new.
        // Track introduced tools in `knownToolRawValues` so user-disabled tools are never re-enabled.
        let allKnownToolRawValues = AnnotationTool.allCases
            .filter { $0 != .select && $0 != .translateOverlay }
            .map { $0.rawValue }
        var enabledRawValues = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let knownToolRawValues = UserDefaults.standard.array(forKey: "knownToolRawValues") as? [Int]
        let newToolRaws = allKnownToolRawValues.filter { !(knownToolRawValues ?? []).contains($0) }
        if !newToolRaws.isEmpty {
            if enabledRawValues == nil {
                // Fresh install: enable everything.
                enabledRawValues = allKnownToolRawValues
            } else if knownToolRawValues == nil {
                // Upgrading from a version before knownToolRawValues tracking was added.
                // Respect the existing enabledTools as-is; just mark all current tools as known.
            } else {
                // Normal upgrade: new tools introduced — add them enabled by default.
                enabledRawValues = (enabledRawValues! + newToolRaws)
            }
            UserDefaults.standard.set(enabledRawValues, forKey: "enabledTools")
            UserDefaults.standard.set(allKnownToolRawValues, forKey: "knownToolRawValues")
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil, "pencil", L("Pencil (Draw)")),
            (.line, "line.diagonal", L("Line")),
            (.arrow, "arrow.up.right", L("Arrow")),
            (.rectangle, "square", L("Rectangle")),
            (.ellipse, "circle", L("Ellipse")),
            (.marker, {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker")),
            (.text, "textformat", L("Text")),
            (.number, "list.number", L("Number")),
            (.pixelate, "square.grid.2x2", L("Censor (Pixelate / Blur / Solid)")),
            (.highlight, "sun.max", L("Highlight (Spotlight)")),
            (.loupe, "plus.magnifyingglass", L("Magnify (Loupe)")),
            (.stamp, "face.smiling", L("Stamp / Emoji")),
            (.colorSampler, "eyedropper", L("Color Picker")),
            (.measure, "ruler", L("Measure (px)")),
        ]

        for (tool, symbol, tip) in tools {
            // Skip if disabled
            if let enabledRawValues = enabledRawValues, !enabledRawValues.contains(tool.rawValue) {
                continue
            }
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            switch tool {
            case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe:
                break  // options shown in the tool options row, not via right-click
            default:
                break
            }
            buttons.append(btn)
        }

        // Color button
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"))
        colorBtn.bgColor = selectedColor
        colorBtn.groupStart = !buttons.isEmpty
        buttons.append(colorBtn)

        // Undo / Redo
        buttons.append(
            ToolbarButton(
                action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo")))
        buttons.append(
            ToolbarButton(
                action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo")))

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        var firstImageAction = true
        for action in ToolbarCustomAction.bottomToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if var button = action.makeToolbarButton(
                beautifyEnabled: beautifyEnabled,
                effectsActive: effectsActive,
                isRecording: isRecording
            ) {
                button.groupStart = firstImageAction
                firstImageAction = false
                buttons.append(button)
            }
        }

        return buttons
    }

    // Right toolbar items (output actions + cancel + delay)
    static func rightButtons(
        beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false,
        translateEnabled: Bool = false, isRecording: Bool = false,
        isEditorMode: Bool = false, annotationToolsVisible: Bool = true
    ) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        // Recording setup bar (mac-recording.html "录制准备"): start · toggles · settings / move / cancel.
        if isRecording {
            var startBtn = ToolbarButton(
                action: .startRecord, sfSymbol: "_record.dot", tooltip: L("Start Recording"))
            startBtn.style = .primary
            startBtn.label = L("Start Recording")
            startBtn.fillColor = .systemRed
            buttons.append(startBtn)

            func toggle(_ action: ToolbarButtonAction, _ symbol: String, _ label: String, _ tip: String, on: Bool, menu: Bool = false) -> ToolbarButton {
                var button = ToolbarButton(action: action, sfSymbol: symbol, tooltip: tip)
                button.style = .toggle
                button.label = label
                button.isSelected = on
                button.hasContextMenu = menu
                return button
            }
            let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            var mouseBtn = toggle(.mouseHighlight, "cursorarrow.click.2", L("Clicks"), L("Highlight Mouse Clicks"), on: mouseHighlightOn)
            mouseBtn.groupStart = true
            buttons.append(mouseBtn)
            let keystrokesOn = UserDefaults.standard.bool(forKey: "recordKeystroke")
            buttons.append(toggle(.showKeystrokes, "keyboard", L("Keys"), L("Show Keystrokes"), on: keystrokesOn, menu: true))
            let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            buttons.append(toggle(.systemAudio, audioOn ? "speaker.wave.2" : "speaker.slash", L("System Audio"), L("Record System Audio"), on: audioOn))
            let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")
            buttons.append(toggle(.micAudio, micOn ? "mic" : "mic.slash", L("Microphone"), L("Record Microphone"), on: micOn, menu: true))
            let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")
            let webcamSymbol: String = {
                if #available(macOS 14.0, *) { return "web.camera" }
                return "camera"
            }()
            buttons.append(toggle(.webcam, webcamSymbol, L("Camera"), L("Webcam Overlay"), on: webcamOn, menu: true))

            var gear = ToolbarButton(action: .recordSettings, sfSymbol: "gearshape", tooltip: L("Recording Settings"))
            gear.style = .square
            gear.groupStart = true
            buttons.append(gear)
            var move = ToolbarButton(
                action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right", tooltip: L("Move Selection"))
            move.style = .square
            buttons.append(move)
            var cancel = ToolbarButton(action: .stopRecord, sfSymbol: "xmark", tooltip: L("Cancel Recording"))
            cancel.style = .close
            buttons.append(cancel)
            return buttons
        }

        if !isEditorMode {
            return captureBarButtons(translateEnabled: translateEnabled, annotationToolsVisible: annotationToolsVisible)
        }

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()

        // Cancel, move-selection, editor — not shown in editor window
        if !isEditorMode {
            buttons.append(
                ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))
            buttons.append(
                ToolbarButton(
                    action: .detach, sfSymbol: "arrow.up.forward.app",
                    tooltip: L("Open in Editor Window")))
        }
        // Copy and save are always present
        buttons.append(
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        var saveBtn = ToolbarButton(
            action: .save, sfSymbol: "square.and.arrow.down.fill",
            tooltip: saveTooltip
        )
        saveBtn.hasContextMenu = true
        buttons.append(saveBtn)

        for action in ToolbarCustomAction.rightToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                translateEnabled: translateEnabled,
                isRecording: isRecording,
                isEditorMode: isEditorMode
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }

    /// V3 capture bar (mac-capture.html `.capbar`): modes · options · Copy · ×.
    /// Same actions as the former vertical output strip; each respects the
    /// "enabled actions" preference. Moving the selection stays on Space.
    static func captureBarButtons(translateEnabled: Bool, annotationToolsVisible: Bool) -> [ToolbarButton] {
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        func enabled(_ action: ToolbarCustomAction) -> Bool { ToolbarActionPreferences.isEnabled(action, in: enabledActions) }
        func make(_ action: ToolbarButtonAction, _ symbol: String, _ label: String, _ tip: String, _ style: ToolbarButtonStyle) -> ToolbarButton {
            var button = ToolbarButton(action: action, sfSymbol: symbol, tooltip: tip)
            button.style = style
            button.label = label
            return button
        }
        var buttons: [ToolbarButton] = []
        var annotate = make(.toggleAnnotationTools, "pencil", L("Annotate"), L("Show / hide annotation tools"), .mode)
        annotate.isSelected = annotationToolsVisible
        buttons.append(annotate)
        if enabled(.pin) { buttons.append(make(.pin, "pin", L("Pin"), L("Pin (floating window)"), .mode)) }
        if enabled(.ocr) { buttons.append(make(.ocr, "text.viewfinder", L("Recognize Text"), L("OCR & QR"), .mode)) }
        if enabled(.translate) {
            var translate = make(.translate, "translate", L("Translate"), L("Translate"), .mode)
            translate.isSelected = translateEnabled
            translate.hasContextMenu = true
            buttons.append(translate)
        }
        if enabled(.scrollCapture) { buttons.append(make(.scrollCapture, "scroll", L("Scroll Capture"), L("Scroll Capture"), .mode)) }
        if enabled(.record) { buttons.append(make(.record, "record.circle", L("Record Video"), L("Record screen"), .mode)) }

        var edit = make(.detach, "arrow.up.right.square", L("Edit Window"), L("Open in Editor Window"), .option)
        edit.groupStart = true
        buttons.append(edit)
        if enabled(.share) { buttons.append(make(.share, "square.and.arrow.up", L("Share"), L("Share"), .option)) }
        #if !OFFLINE
        if enabled(.upload) {
            var upload = make(.upload, "icloud.and.arrow.up", L("Upload"), L("Upload"), .option)
            upload.hasContextMenu = true
            buttons.append(upload)
        }
        #endif
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        var save = make(.save, "square.and.arrow.down", L("Save"), saveTooltip, .option)
        save.hasContextMenu = true
        buttons.append(save)
        buttons.append(make(.copy, "doc.on.doc", L("Copy"), L("Copy"), .primary))
        var cancel = ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel"))
        cancel.style = .close
        buttons.append(cancel)
        return buttons
    }

}
