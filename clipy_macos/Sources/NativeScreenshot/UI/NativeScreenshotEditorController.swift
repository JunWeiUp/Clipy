import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
@available(macOS 13.0, *)
final class NativeScreenshotEditorController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let base: NativeScreenshotCapturedImage
    private let onAction: (NativeScreenshotDeliveryAction, NativeScreenshotCapturedImage) -> Void
    private let onCancel: () -> Void
    private let canvas: NativeScreenshotAnnotationCanvasView
    private var panel: NSPanel?
    private var scrollView: NSScrollView?
    private var optionContent: NSView?
    private weak var optionsBar: NSView?
    private weak var dimensionsLabel: NSTextField?
    private weak var zoomButton: NSButton?
    /// nil means the image follows the available viewport; an explicit value is
    /// a display scale and never changes the exported image pixels.
    private var previewZoom: CGFloat?
    private weak var colorWell: NSColorWell?
    private weak var textField: NSTextField?
    private weak var richTextEditor: NSTextView?
    private var toolButtons: [NSButton] = []
    private var textInputValue = ""
    private let initialBeautify: NativeScreenshotBeautifyOptions?
    private let initialEffects: NativeScreenshotImageProcessor.Adjustments?
    private let activationID = UUID()
    private var activationRegistered = false
    private var closing = false
    private var busySheet: NSPanel?
    private var discardPromptOpen = false
    private var livePreview: LivePreview?

    private final class LivePreview: @unchecked Sendable {
        let imageView: NSImageView
        let controls: [NSView]
        let buildOperation: () -> ((CGImage) throws -> CGImage)?
        var source: CGImage?
        var generation = 0
        var active = true
        var pending: DispatchWorkItem?

        init(imageView: NSImageView, controls: [NSView],
             buildOperation: @escaping () -> ((CGImage) throws -> CGImage)?) {
            self.imageView = imageView
            self.controls = controls
            self.buildOperation = buildOperation
        }
    }

    init(
        base: NativeScreenshotCapturedImage,
        defaultsAlreadyApplied: Bool = false,
        onAction: @escaping (NativeScreenshotDeliveryAction, NativeScreenshotCapturedImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.base = base
        self.onAction = onAction
        self.onCancel = onCancel
        let prefs = PreferencesManager.shared
        initialBeautify = !defaultsAlreadyApplied && prefs.beautifyEnabled ? NativeScreenshotBeautifyOptions(
            mode: prefs.beautifyMode == 0 ? .window : .rounded,
            margin: CGFloat(prefs.beautifyPadding),
            cornerRadius: CGFloat(prefs.beautifyCornerRadius),
            shadowRadius: CGFloat(prefs.beautifyShadowRadius)) : nil
        let effects = NativeScreenshotImageProcessor.Adjustments(
            brightness: Float(prefs.effectsBrightness),
            contrast: Float(prefs.effectsContrast),
            saturation: Float(prefs.effectsSaturation),
            sharpness: Float(prefs.effectsSharpness))
        initialEffects = !defaultsAlreadyApplied && (effects.brightness != 0 || effects.contrast != 1
            || effects.saturation != 1 || effects.sharpness != 0) ? effects : nil
        canvas = NativeScreenshotAnnotationCanvasView(image: base.image)
        super.init()
        canvas.textFontSize = prefs.screenshotTextFontSize
        canvas.textBold = prefs.screenshotTextBold
        canvas.textItalic = prefs.screenshotTextItalic
        canvas.textBackgroundEnabled = prefs.screenshotTextBackgroundEnabled
        canvas.pressureEnabled = prefs.pencilPressureEnabled
        canvas.pencilSmoothing = NativeScreenshotPencilSmoothing(rawValue: prefs.pencilSmoothMode) ?? .smooth
        canvas.smartMarkerEnabled = prefs.smartMarkerEnabled
        if prefs.rememberLastTool,
           let raw = UserDefaults.standard.string(forKey: "nativeScreenshot.lastTool"),
           let kind = NativeScreenshotAnnotationKind(rawValue: raw),
           prefs.nativeScreenshotToolbarConfiguration.isToolEnabled(kind.rawValue) {
            canvas.tool = .annotation(kind)
        }
        canvas.textProvider = { [weak self] in self?.textInputValue ?? "" }
        canvas.onSampledColor = { [weak self] sampled in self?.showSampledColor(sampled) }
        canvas.onEscape = { [weak self] in self?.requestCancel() }
        canvas.onImageSizeChanged = { [weak self] in self?.fitCanvasToViewport() }
        canvas.onSelectionChanged = { [weak self] in self?.rebuildOptions() }
        canvas.onToolShortcut = { [weak self] kind in
            guard let self else { return }
            self.refreshToolSelection()
            self.rebuildOptions()
            if PreferencesManager.shared.rememberLastTool {
                UserDefaults.standard.set(kind?.rawValue, forKey: "nativeScreenshot.lastTool")
            }
        }
        canvas.onCopyImage = { [weak self] in self?.copyRenderedImage() }
        canvas.onSaveImage = { [weak self] in self?.deliver(.save) }
    }

    func show() {
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1100, height: 800)
        let width = min(1100, max(800, screenFrame.width - 80))
        let height = min(800, max(380, screenFrame.height - 80))
        let frame = CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = NativeScreenshotText.get(.editorTitle)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 800, height: 400)
        panel.center()

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let imageBar = makeImageBar(width: width)
        imageBar.frame.origin.y = height - 32
        let toolbar = makeToolbar(width: width)
        let options = makeOptionsBar(width: width)
        let actions = makeActionBar(width: width, height: height)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height - 32))
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.15, alpha: 1)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 116, right: 50)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -116, right: -50)
        scroll.autoresizingMask = [.width, .height]
        scroll.contentView = NativeScreenshotEditorClipView(frame: scroll.contentView.frame)
        scrollView = scroll
        let fit = min(
            (width - 74) / CGFloat(canvas.image.width),
            (height - 172) / CGFloat(canvas.image.height)
        )
        let canvasScale = max(0.05, min(1, fit))
        canvas.frame = CGRect(
            x: 0, y: 0,
            width: CGFloat(canvas.image.width) * canvasScale,
            height: CGFloat(canvas.image.height) * canvasScale
        )
        scroll.documentView = canvas
        root.addSubview(scroll)
        root.addSubview(options)
        root.addSubview(toolbar)
        root.addSubview(actions)
        root.addSubview(imageBar)
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        options.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        actions.autoresizingMask = [.minXMargin, .minYMargin]
        imageBar.autoresizingMask = [.width, .minYMargin]
        panel.contentView = root
        self.panel = panel
        NativeScreenshotWindowActivation.opened(activationID)
        activationRegistered = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        fitCanvasToViewport()
        applyInitialProcessing()
    }

    private func applyInitialProcessing() {
        guard initialBeautify != nil || initialEffects != nil else { return }
        let image = base.image
        let beautify = initialBeautify
        let effects = initialEffects
        beginBusySheet()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<CGImage, Error> {
                var prepared = image
                if let beautify {
                    prepared = try NativeScreenshotImageEditor.wrap(prepared, options: beautify)
                }
                if let effects {
                    prepared = try NativeScreenshotImageProcessor.adjust(prepared, using: effects)
                }
                return prepared
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBusySheet()
                guard !self.closing else { return }
                switch result {
                case let .success(prepared): self.canvas.installPreparedImage(prepared)
                case let .failure(error):
                    if let panel = self.panel { NSAlert(error: error).beginSheetModal(for: panel) }
                }
            }
        }
    }

    func close() {
        guard !closing else { return }
        closing = true
        livePreview?.active = false
        livePreview?.pending?.cancel()
        livePreview = nil
        endBusySheet()
        panel?.close()
        panel = nil
        releaseActivation()
    }

    func windowWillClose(_ notification: Notification) {
        let shouldNotify = !closing
        closing = true
        livePreview?.active = false
        livePreview?.pending?.cancel()
        livePreview = nil
        endBusySheet()
        releaseActivation()
        panel = nil
        if shouldNotify { onCancel() }
    }

    func windowDidResize(_ notification: Notification) {
        if previewZoom == nil { fitCanvasToViewport() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closing else { return true }
        guard busySheet == nil else { return false }
        guard canvas.hasUnsavedEdits else { return true }
        requestCancel()
        return false
    }

    private func requestCancel() {
        guard !closing, busySheet == nil, !discardPromptOpen else { return }
        guard canvas.hasUnsavedEdits else { cancelAndClose(); return }
        guard let panel else { return }
        discardPromptOpen = true
        let alert = NSAlert()
        alert.messageText = NativeScreenshotText.get(.unsavedChanges)
        alert.informativeText = NativeScreenshotText.get(.discardChangesExplanation)
        alert.addButton(withTitle: NativeScreenshotText.get(.keepEditing))
        alert.addButton(withTitle: NativeScreenshotText.get(.discardChanges))
        alert.beginSheetModal(for: panel) { [weak self] response in
            self?.discardPromptOpen = false
            if response == .alertSecondButtonReturn { self?.cancelAndClose() }
        }
    }

    private func cancelAndClose() {
        guard !closing else { return }
        close()
        onCancel()
    }

    private func releaseActivation() {
        guard activationRegistered else { return }
        activationRegistered = false
        NativeScreenshotWindowActivation.closed(activationID)
    }

    private func makeImageBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 32))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration.backgroundColor.cgColor
        let dimensions = NSTextField(labelWithString: "\(canvas.image.width) × \(canvas.image.height)")
        dimensions.frame = CGRect(x: 12, y: 6, width: 145, height: 18)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensions.textColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration.iconColor.withAlphaComponent(0.55)
        dimensions.toolTip = NativeScreenshotText.get(.pixelDimensions)
        bar.addSubview(dimensions)
        dimensionsLabel = dimensions
        var x: CGFloat = 170
        func add(_ symbol: String, _ key: NativeScreenshotText.Key, action: Selector) {
            let control = iconButton(symbol, title: NativeScreenshotText.get(key), action: action)
            control.frame = CGRect(x: x, y: 4, width: 24, height: 24)
            bar.addSubview(control)
            x += 28
        }
        add("crop", .chooseCrop, action: #selector(beginCropFromBar))
        add("arrow.left.and.right.righttriangle.left.righttriangle.right", .flipHorizontal,
            action: #selector(flipHorizontalFromBar))
        add("arrow.up.and.down.righttriangle.up.righttriangle.down", .flipVertical,
            action: #selector(flipVerticalFromBar))
        x += 8
        add("rectangle.badge.plus", .appendImage, action: #selector(appendImageFromBar))
        let zoom = NSButton(title: "100% ▾", target: self, action: #selector(showZoomMenu(_:)))
        zoom.isBordered = false
        zoom.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoom.contentTintColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration.iconColor.withAlphaComponent(0.7)
        zoom.frame = CGRect(x: width - 92, y: 4, width: 80, height: 24)
        zoom.autoresizingMask = [.minXMargin]
        zoom.toolTip = NativeScreenshotText.get(.zoomFit)
        bar.addSubview(zoom)
        zoomButton = zoom
        return bar
    }

    private func makeToolbar(width: CGFloat) -> NSView {
        let barWidth = min(width - 120, 820)
        let toolbar = chromeView(frame: CGRect(x: (width - barWidth) / 2, y: 20,
                                               width: barWidth, height: 44))
        let scroll = NSScrollView(frame: CGRect(x: 5, y: 4, width: barWidth - 10, height: 36))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        let row = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 36))
        let configuration = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
        var x: CGFloat = 4
        for kind in Self.editorToolOrder where configuration.isToolEnabled(kind?.rawValue ?? "select") {
            let title = kind.map(Self.title(for:)) ?? NativeScreenshotText.get(.selectMove)
            let shortcut = configuration.shortcut(forToolID: kind?.rawValue ?? "select")
            let tooltip = PreferencesManager.shared.showToolShortcutsInTooltips && shortcut != nil
                ? "\(title) (\(shortcut!.uppercased()))" : title
            let item = iconButton(Self.symbol(for: kind), title: tooltip,
                                  action: #selector(selectToolFromButton(_:)))
            item.setButtonType(.toggle)
            item.tag = kind.flatMap { NativeScreenshotAnnotationKind.allCases.firstIndex(of: $0) }
                .map { $0 + 1 } ?? 0
            item.frame = CGRect(x: x, y: 1, width: 34, height: 34)
            item.setAccessibilityIdentifier("editor.tool.\(kind?.rawValue ?? "select")")
            row.addSubview(item)
            toolButtons.append(item)
            x += 37
        }
        x += 4
        let colorWell = NSColorWell(frame: CGRect(x: x, y: 4, width: 30, height: 28))
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(changeColor(_:))
        colorWell.toolTip = NativeScreenshotText.get(.annotationColor)
        row.addSubview(colorWell)
        self.colorWell = colorWell
        x += 38
        let historyButtons: [(String, NativeScreenshotText.Key, Selector)] = [
            ("arrow.uturn.backward", .undo, #selector(undoEdit)),
            ("arrow.uturn.forward", .redo, #selector(redoEdit))
        ]
        for (symbol, key, action) in historyButtons {
            let item = iconButton(symbol, title: NativeScreenshotText.get(key), action: action)
            item.frame = CGRect(x: x, y: 1, width: 34, height: 34)
            row.addSubview(item)
            x += 37
        }
        let edits = NSPopUpButton(frame: CGRect(x: x, y: 2, width: 40, height: 32), pullsDown: true)
        edits.addItem(withTitle: "")
        edits.item(at: 0)?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: NativeScreenshotText.get(.imageEdits))
        for key: NativeScreenshotText.Key in [
            .chooseCrop, .applyCrop, .flipHorizontal, .flipVertical,
            .transform, .beautify, .imageEffects
        ] { edits.addItem(withTitle: NativeScreenshotText.get(key)) }
        edits.target = self
        edits.action = #selector(pickImageEdit(_:))
        edits.toolTip = NativeScreenshotText.get(.imageEdits)
        row.addSubview(edits)
        x += 43
        row.frame.size.width = x + 4
        scroll.documentView = row
        toolbar.addSubview(scroll)
        refreshToolSelection()
        return toolbar
    }

    private func makeActionBar(width: CGFloat, height: CGFloat) -> NSView {
        let configuration = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
        let actions: [(String?, String, String, Selector)] = [
            (nil, "checkmark", NativeScreenshotText.get(.done), #selector(confirmEdit)),
            (nil, "doc.on.doc", NativeScreenshotUserText.string("复制", "Copy"), #selector(copyFromButton)),
            ("save", "square.and.arrow.down", NativeScreenshotText.get(.save), #selector(saveFromButton)),
            ("pin", "pin", NativeScreenshotText.get(.pin), #selector(pinFromButton)),
            ("ocr", "text.viewfinder", NativeScreenshotText.get(.ocr), #selector(ocrFromButton)),
            ("qrCode", "qrcode.viewfinder", NativeScreenshotText.get(.qrCode), #selector(qrFromButton)),
            ("autoRedact", "eye.slash", NativeScreenshotText.get(.autoRedact), #selector(redactFromButton))
        ]
        let visible = actions.filter { $0.0.map(configuration.isActionEnabled) ?? true }
        let contentHeight = CGFloat(visible.count) * 38 + 12
        let barHeight = min(contentHeight, max(160, height - 140))
        let bar = chromeView(frame: CGRect(x: width - 66, y: height - 36 - barHeight,
                                           width: 46, height: barHeight))
        let scroll = NSScrollView(frame: CGRect(x: 2, y: 4, width: 42, height: barHeight - 8))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = contentHeight > barHeight
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        let column = NSView(frame: CGRect(x: 0, y: 0, width: 42, height: contentHeight))
        for (index, item) in visible.enumerated() {
            let button = iconButton(item.1, title: item.2, action: item.3)
            button.frame = CGRect(x: 3, y: contentHeight - 7 - CGFloat(index + 1) * 38,
                                  width: 36, height: 36)
            button.setAccessibilityIdentifier("editor.action.\(item.0 ?? "done")")
            column.addSubview(button)
        }
        scroll.documentView = column
        bar.addSubview(scroll)
        return bar
    }

    private func chromeView(frame: CGRect) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: frame)
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 11
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration.backgroundColor.cgColor
        return view
    }

    private func iconButton(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .recessed
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.contentTintColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration.iconColor
        button.toolTip = title
        button.target = self
        button.action = action
        return button
    }

    private static let editorToolOrder: [NativeScreenshotAnnotationKind?] = [
        .pencil, .line, .arrow, .rectangle, .ellipse, .highlighter, .richText,
        .number, nil, .pixelate, .spotlight, .magnifier, .stamp, .colorSampler,
        .ruler, .filledRectangle, .blur, .solidCensor, .eraseCensor
    ]

    static func editorModes(for kind: NativeScreenshotAnnotationKind) -> [NativeScreenshotAnnotationKind] {
        switch kind {
        case .rectangle, .filledRectangle: return [.rectangle, .filledRectangle]
        case .pixelate, .blur, .solidCensor, .eraseCensor:
            return [.pixelate, .blur, .solidCensor, .eraseCensor]
        default: return [kind]
        }
    }

    static func visibleEditorToolIDs(configuration: NativeScreenshotToolbarConfiguration) -> [String] {
        editorToolOrder.compactMap { kind -> String? in
            let id = kind?.rawValue ?? "select"
            return configuration.isToolEnabled(id) ? id : nil
        }
    }

    static func reachableEditorToolIDs(configuration: NativeScreenshotToolbarConfiguration) -> Set<String> {
        let visible = visibleEditorToolIDs(configuration: configuration)
        var ids = Set(visible)
        for id in visible {
            guard let kind = NativeScreenshotAnnotationKind(rawValue: id) else { continue }
            ids.formUnion(editorModes(for: kind).map(\.rawValue))
        }
        return ids
    }

    private static func symbol(for kind: NativeScreenshotAnnotationKind?) -> String {
        guard let kind else { return "cursorarrow" }
        switch kind {
        case .pencil: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .highlighter: return "highlighter"
        case .richText: return "textformat"
        case .number: return "1.circle"
        case .stamp: return "face.smiling"
        case .pixelate: return "square.grid.3x3"
        case .blur: return "drop.halffull"
        case .solidCensor: return "rectangle.fill"
        case .eraseCensor: return "eraser"
        case .magnifier: return "plus.magnifyingglass"
        case .ruler: return "ruler"
        case .colorSampler: return "eyedropper"
        case .spotlight: return "viewfinder"
        }
    }

    private func refreshToolSelection() {
        let selectedKind: NativeScreenshotAnnotationKind?
        if case let .annotation(kind) = canvas.tool {
            selectedKind = kind
        } else {
            selectedKind = nil
        }
        let configuration = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
        let displayedKind: NativeScreenshotAnnotationKind?
        if let selectedKind, !configuration.isToolEnabled(selectedKind.rawValue) {
            displayedKind = Self.editorModes(for: selectedKind).first {
                configuration.isToolEnabled($0.rawValue)
            }
        } else {
            displayedKind = selectedKind
        }
        let selected = displayedKind.flatMap {
            NativeScreenshotAnnotationKind.allCases.firstIndex(of: $0)
        }.map { $0 + 1 } ?? 0
        for button in toolButtons {
            button.state = button.tag == selected ? .on : .off
            button.contentTintColor = button.tag == selected ? configuration.accentColor : configuration.iconColor
        }
    }

    private func makeOptionsBar(width: CGFloat) -> NSView {
        let barWidth = min(width - 120, 720)
        let bar = chromeView(frame: CGRect(x: (width - barWidth) / 2, y: 68,
                                           width: barWidth, height: 44))
        let scroll = NSScrollView(frame: bar.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        let content = NSView(frame: CGRect(x: 0, y: 0, width: barWidth, height: 44))
        scroll.documentView = content
        bar.addSubview(scroll)
        optionsBar = bar
        optionContent = content
        rebuildOptions()
        return bar
    }

    private func rebuildOptions() {
        guard let content = optionContent else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 12
        func place(_ view: NSView, width: CGFloat) {
            view.frame = CGRect(x: x, y: 9, width: width, height: 28)
            content.addSubview(view)
            x += width + 9
        }
        func label(_ key: NativeScreenshotText.Key, width: CGFloat = 92) {
            let view = NSTextField(labelWithString: NativeScreenshotText.get(key))
            view.alignment = .right
            view.lineBreakMode = .byTruncatingTail
            place(view, width: width)
        }
        func slider(_ value: Double, range: ClosedRange<Double>, action: Selector,
                    width: CGFloat = 110) {
            let view = NSSlider(value: value, minValue: range.lowerBound,
                                maxValue: range.upperBound, target: self, action: action)
            view.isContinuous = false
            place(view, width: width)
        }
        func check(_ key: NativeScreenshotText.Key, value: Bool, action: Selector,
                   width: CGFloat = 100) {
            let view = NSButton(checkboxWithTitle: NativeScreenshotText.get(key),
                                target: self, action: action)
            view.state = value ? .on : .off
            place(view, width: width)
        }

        if case let .annotation(kind) = canvas.tool {
            label(.lineWidth, width: 55)
            slider(Double(canvas.style.lineWidth), range: 1...24,
                   action: #selector(changeLineWidth(_:)), width: 105)
            if kind == .richText || kind == .stamp {
                let input = NSTextField(frame: .zero)
                input.placeholderString = NativeScreenshotText.get(.textOrEmoji)
                input.stringValue = textInputValue
                input.toolTip = NativeScreenshotText.get(.textOrEmoji)
                input.delegate = self
                place(input, width: 132)
                textField = input
            }
        }

        switch canvas.tool {
        case .select:
            if canvas.hasSelectedAnnotation {
                place(button(NativeScreenshotText.get(.shrink), action: #selector(shrinkSelection)), width: 68)
                place(button(NativeScreenshotText.get(.enlarge), action: #selector(enlargeSelection)), width: 68)
                place(button(NativeScreenshotText.get(.deleteSelected), action: #selector(deleteSelection)), width: 100)
            }
            if canvas.selectedRichText != nil {
                place(button(NativeScreenshotText.get(.editText), action: #selector(editText)), width: 100)
                check(.bold, value: canvas.textBold, action: #selector(changeBold(_:)), width: 72)
                check(.italic, value: canvas.textItalic, action: #selector(changeItalic(_:)), width: 72)
                check(.underline, value: canvas.textUnderline, action: #selector(changeUnderline(_:)), width: 92)
                check(.outline, value: canvas.textOutlineWidth > 0,
                      action: #selector(changeOutline(_:)), width: 92)
                check(.textBackground, value: canvas.textBackgroundEnabled,
                      action: #selector(changeTextBackground(_:)), width: 120)
                label(.fontSize, width: 62)
                slider(Double(canvas.textFontSize), range: 10...72,
                       action: #selector(changeFontSize(_:)), width: 100)
            }
        case .crop:
            place(button(NativeScreenshotText.get(.applyCrop), action: #selector(applyCrop)), width: 110)
        case let .annotation(kind):
            switch kind {
            case .rectangle, .filledRectangle:
                let modes = Self.editorModes(for: kind)
                let control = NSSegmentedControl(labels: [
                    NativeScreenshotUserText.string("轮廓", "Outline"),
                    NativeScreenshotUserText.string("填充", "Fill")
                ], trackingMode: .selectOne, target: self,
                   action: #selector(changeRectangleMode(_:)))
                control.selectedSegment = modes.firstIndex(of: kind) ?? 0
                place(control, width: 150)
            case .pixelate, .blur, .solidCensor, .eraseCensor:
                let modes = Self.editorModes(for: kind)
                let control = NSSegmentedControl(labels: [
                    NativeScreenshotUserText.string("马赛克", "Pixelate"),
                    NativeScreenshotUserText.string("模糊", "Blur"),
                    NativeScreenshotUserText.string("纯色", "Solid"),
                    NativeScreenshotUserText.string("擦除", "Erase")
                ], trackingMode: .selectOne, target: self,
                   action: #selector(changeCensorMode(_:)))
                control.selectedSegment = modes.firstIndex(of: kind) ?? 0
                place(control, width: 294)
                if kind == .pixelate {
                    label(.pixelBlock)
                    slider(Double(canvas.pixelBlockSize), range: 2...64,
                           action: #selector(changePixelBlock(_:)))
                } else if kind == .blur {
                    label(.blurRadius)
                    slider(Double(canvas.blurRadius), range: 1...40,
                           action: #selector(changeBlurRadius(_:)))
                }
            case .arrow:
                label(.arrowStyle)
                let picker = NSPopUpButton(frame: .zero, pullsDown: false)
                for key: NativeScreenshotText.Key in [
                    .arrowSolid, .arrowDashed, .arrowCurved,
                    .arrowCurvedDashed, .arrowSketch, .arrowDoubleHeaded
                ] { picker.addItem(withTitle: NativeScreenshotText.get(key)) }
                picker.selectItem(at: canvas.arrowStyle.rawValue)
                picker.target = self
                picker.action = #selector(changeArrowStyle(_:))
                place(picker, width: 150)
            case .pencil:
                label(.smoothing)
                let picker = NSPopUpButton(frame: .zero, pullsDown: false)
                for key: NativeScreenshotText.Key in [.smoothingNone, .smoothingSmooth, .smoothingRefined] {
                    picker.addItem(withTitle: NativeScreenshotText.get(key))
                }
                picker.selectItem(at: canvas.pencilSmoothing.rawValue)
                picker.target = self
                picker.action = #selector(changeSmoothing(_:))
                place(picker, width: 120)
                check(.pressure, value: canvas.pressureEnabled,
                      action: #selector(changePressure(_:)), width: 95)
            case .richText:
                check(.bold, value: canvas.textBold, action: #selector(changeBold(_:)), width: 72)
                check(.italic, value: canvas.textItalic, action: #selector(changeItalic(_:)), width: 72)
                check(.underline, value: canvas.textUnderline, action: #selector(changeUnderline(_:)), width: 92)
                check(.outline, value: canvas.textOutlineWidth > 0,
                      action: #selector(changeOutline(_:)), width: 92)
                check(.textBackground, value: canvas.textBackgroundEnabled,
                      action: #selector(changeTextBackground(_:)), width: 120)
                label(.fontSize, width: 62)
                slider(Double(canvas.textFontSize), range: 10...72,
                       action: #selector(changeFontSize(_:)), width: 100)
                let background = NSColorWell(frame: .zero)
                background.color = .systemYellow
                background.target = self
                background.action = #selector(changeTextBackgroundColor(_:))
                place(background, width: 36)
                place(button(NativeScreenshotText.get(.editText), action: #selector(editText)), width: 92)
            case .stamp:
                place(button(NativeScreenshotText.get(.importImage), action: #selector(importStamp)), width: 160)
                place(button(NativeScreenshotText.get(.useEmoji), action: #selector(clearStampImage)), width: 110)
            case .highlighter:
                check(.smartMarker, value: canvas.smartMarkerEnabled,
                      action: #selector(changeSmartMarker(_:)), width: 150)
            case .magnifier:
                label(.magnifierZoom)
                slider(Double(canvas.magnifierScale), range: 1.25...4,
                       action: #selector(changeMagnifierScale(_:)))
            default:
                break
            }
        }
        content.frame.size.width = max(x + 14, optionsBar?.frame.width ?? 0)
        optionsBar?.isHidden = x == 12
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = title
        return button
    }

    @objc private func selectToolFromButton(_ sender: NSButton) {
        let kind = sender.tag == 0 ? nil : NativeScreenshotAnnotationKind.allCases[sender.tag - 1]
        guard PreferencesManager.shared.nativeScreenshotToolbarConfiguration
            .isToolEnabled(kind?.rawValue ?? "select") else { return }
        if let kind {
            canvas.clearSelection()
            canvas.tool = .annotation(kind)
        } else {
            canvas.tool = .select
        }
        if PreferencesManager.shared.rememberLastTool {
            if case let .annotation(kind) = canvas.tool {
                UserDefaults.standard.set(kind.rawValue, forKey: "nativeScreenshot.lastTool")
            } else {
                UserDefaults.standard.removeObject(forKey: "nativeScreenshot.lastTool")
            }
        }
        refreshToolSelection()
        rebuildOptions()
        panel?.makeFirstResponder(canvas)
    }

    @objc private func changeColor(_ sender: NSColorWell) {
        guard let color = sender.color.usingColorSpace(.deviceRGB) else { return }
        canvas.style.strokeColor = NativeScreenshotColor(
            red: color.redComponent, green: color.greenComponent,
            blue: color.blueComponent, alpha: color.alphaComponent
        )
        canvas.style.fillColor = canvas.style.strokeColor
        canvas.updateSelectedRichTextStyle()
        panel?.makeFirstResponder(canvas)
    }

    @objc private func changeLineWidth(_ sender: NSSlider) {
        canvas.style.lineWidth = CGFloat(sender.doubleValue)
        panel?.makeFirstResponder(canvas)
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject? === textField {
            textInputValue = textField?.stringValue ?? ""
            canvas.textOverride = nil
        }
        if let control = obj.object as? NSView,
           livePreview?.controls.contains(where: { $0 === control }) == true {
            refreshLivePreview()
        }
    }

    @objc private func changeArrowStyle(_ sender: NSPopUpButton) {
        canvas.arrowStyle = NativeScreenshotArrowStyle(rawValue: sender.indexOfSelectedItem) ?? .solid
    }

    @objc private func changeRectangleMode(_ sender: NSSegmentedControl) {
        let modes = Self.editorModes(for: .rectangle)
        guard modes.indices.contains(sender.selectedSegment) else { return }
        selectEditorMode(modes[sender.selectedSegment])
    }

    @objc private func changeCensorMode(_ sender: NSSegmentedControl) {
        let modes = Self.editorModes(for: .pixelate)
        guard modes.indices.contains(sender.selectedSegment) else { return }
        selectEditorMode(modes[sender.selectedSegment])
    }

    private func selectEditorMode(_ kind: NativeScreenshotAnnotationKind) {
        canvas.tool = .annotation(kind)
        if PreferencesManager.shared.rememberLastTool {
            UserDefaults.standard.set(kind.rawValue, forKey: "nativeScreenshot.lastTool")
        }
        refreshToolSelection()
        rebuildOptions()
        panel?.makeFirstResponder(canvas)
    }

    @objc private func changeSmoothing(_ sender: NSPopUpButton) {
        canvas.pencilSmoothing = NativeScreenshotPencilSmoothing(rawValue: sender.indexOfSelectedItem) ?? .smooth
    }

    @objc private func changePressure(_ sender: NSButton) { canvas.pressureEnabled = sender.state == .on }
    @objc private func changeBold(_ sender: NSButton) {
        canvas.textBold = sender.state == .on
        canvas.updateSelectedRichTextStyle()
    }
    @objc private func changeItalic(_ sender: NSButton) {
        canvas.textItalic = sender.state == .on
        canvas.updateSelectedRichTextStyle()
    }
    @objc private func changeUnderline(_ sender: NSButton) {
        canvas.textUnderline = sender.state == .on
        canvas.updateSelectedRichTextStyle()
    }
    @objc private func changeOutline(_ sender: NSButton) {
        canvas.textOutlineWidth = sender.state == .on ? 1 : 0
        canvas.updateSelectedRichTextStyle()
    }
    @objc private func changeTextBackground(_ sender: NSButton) {
        canvas.textBackgroundEnabled = sender.state == .on
        canvas.updateSelectedRichTextStyle()
    }
    @objc private func changeFontSize(_ sender: NSSlider) {
        canvas.textFontSize = CGFloat(sender.doubleValue)
        canvas.updateSelectedRichTextStyle()
    }
    @objc private func changeSmartMarker(_ sender: NSButton) {
        canvas.smartMarkerEnabled = sender.state == .on
    }
    @objc private func changePixelBlock(_ sender: NSSlider) {
        canvas.pixelBlockSize = CGFloat(sender.doubleValue)
    }
    @objc private func changeBlurRadius(_ sender: NSSlider) {
        canvas.blurRadius = CGFloat(sender.doubleValue)
    }
    @objc private func changeMagnifierScale(_ sender: NSSlider) {
        canvas.magnifierScale = CGFloat(sender.doubleValue)
    }
    @objc private func changeTextBackgroundColor(_ sender: NSColorWell) {
        guard let color = sender.color.usingColorSpace(.deviceRGB) else { return }
        canvas.textBackgroundColor = NativeScreenshotColor(
            red: color.redComponent, green: color.greenComponent,
            blue: color.blueComponent, alpha: color.alphaComponent)
        canvas.updateSelectedRichTextStyle()
    }

    @objc private func shrinkSelection() { canvas.scaleSelection(by: 0.9) }
    @objc private func enlargeSelection() { canvas.scaleSelection(by: 1.1) }
    @objc private func deleteSelection() { canvas.deleteSelection() }

    @objc private func editText() {
        guard let panel else { return }
        let alert = NSAlert()
        alert.messageText = NativeScreenshotText.get(.editText)
        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 430, height: 250))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 430, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isEditable = true
        editor.isRichText = true
        editor.usesFontPanel = true
        editor.allowsUndo = true
        let initialRuns = canvas.selectedRichTextRuns ?? [NativeScreenshotTextRun(
            text: canvas.textOverride ?? textField?.stringValue ?? "",
            color: canvas.style.strokeColor, fontSize: canvas.textFontSize,
            bold: canvas.textBold, italic: canvas.textItalic,
            underline: canvas.textUnderline, outlineWidth: canvas.textOutlineWidth,
            backgroundColor: canvas.textBackgroundEnabled ? canvas.textBackgroundColor : nil)]
        editor.textStorage?.setAttributedString(NativeScreenshotRichText.attributedString(from: initialRuns))
        scroll.documentView = editor
        accessory.addSubview(scroll)
        richTextEditor = editor
        let controls: [(NativeScreenshotText.Key, Selector, CGFloat)] = [
            (.bold, #selector(toggleRichEditorBold), 58),
            (.italic, #selector(toggleRichEditorItalic), 58),
            (.underline, #selector(toggleRichEditorUnderline), 82),
            (.outline, #selector(toggleRichEditorOutline), 74),
            (.textBackground, #selector(toggleRichEditorBackground), 118)
        ]
        var x: CGFloat = 0
        for (key, action, width) in controls {
            let button = NSButton(title: NativeScreenshotText.get(key), target: self, action: action)
            button.frame = CGRect(x: x, y: 178, width: width, height: 28)
            accessory.addSubview(button)
            x += width + 5
        }
        let fontButton = NSButton(title: NativeScreenshotText.get(.font), target: self,
                                  action: #selector(showRichEditorFontPanel))
        fontButton.frame = CGRect(x: 0, y: 216, width: 100, height: 24)
        accessory.addSubview(fontButton)
        let foreground = NSColorWell(frame: CGRect(x: 110, y: 216, width: 42, height: 24))
        foreground.color = .labelColor
        foreground.toolTip = NativeScreenshotText.get(.annotationColor)
        foreground.target = self
        foreground.action = #selector(changeRichEditorForeground(_:))
        accessory.addSubview(foreground)
        let background = NSColorWell(frame: CGRect(x: 160, y: 216, width: 42, height: 24))
        background.color = .systemYellow
        background.toolTip = NativeScreenshotText.get(.textBackground)
        background.target = self
        background.action = #selector(changeRichEditorBackgroundColor(_:))
        accessory.addSubview(background)
        alert.accessoryView = accessory
        alert.addButton(withTitle: NativeScreenshotText.get(.apply))
        alert.addButton(withTitle: NativeScreenshotText.get(.cancel))
        alert.beginSheetModal(for: panel) { [weak self] response in
            self?.richTextEditor = nil
            guard response == .alertFirstButtonReturn else { return }
            let runs = NativeScreenshotRichText.runs(from: editor.attributedString())
            if self?.canvas.replaceSelectedRichText(runs) != true {
                self?.canvas.textOverride = editor.string
            }
            let value = editor.string.replacingOccurrences(of: "\n", with: " ")
            self?.textInputValue = value
            self?.textField?.stringValue = value
        }
        alert.window.makeFirstResponder(editor)
    }

    @objc private func toggleRichEditorBold() { toggleRichEditorFontTrait(.boldFontMask) }
    @objc private func toggleRichEditorItalic() { toggleRichEditorFontTrait(.italicFontMask) }
    private func toggleRichEditorFontTrait(_ trait: NSFontTraitMask) {
        guard let editor = richTextEditor, let storage = editor.textStorage else { return }
        let selection = editor.selectedRange()
        let font = (selection.location < storage.length
                    ? storage.attribute(.font, at: selection.location, effectiveRange: nil)
                    : editor.typingAttributes[.font]) as? NSFont ?? NSFont.systemFont(ofSize: 24)
        let manager = NSFontManager.shared
        let enabled = !manager.traits(of: font).contains(trait)
        if selection.length > 0 {
            var changes: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                let current = value as? NSFont ?? font
                let changed = enabled ? manager.convert(current, toHaveTrait: trait)
                    : manager.convert(current, toNotHaveTrait: trait)
                changes.append((range, changed))
            }
            for (range, changed) in changes {
                storage.addAttribute(.font, value: changed, range: range)
            }
        } else {
            var attributes = editor.typingAttributes
            attributes[.font] = enabled ? manager.convert(font, toHaveTrait: trait)
                : manager.convert(font, toNotHaveTrait: trait)
            editor.typingAttributes = attributes
        }
        editor.window?.makeFirstResponder(editor)
    }
    @objc private func showRichEditorFontPanel() {
        NSFontManager.shared.orderFrontFontPanel(nil)
    }
    @objc private func changeRichEditorForeground(_ sender: NSColorWell) {
        setRichEditorAttribute(.foregroundColor, value: sender.color)
    }
    @objc private func changeRichEditorBackgroundColor(_ sender: NSColorWell) {
        setRichEditorAttribute(.backgroundColor, value: sender.color)
    }
    @objc private func toggleRichEditorUnderline() {
        changeRichEditorAttribute(.underlineStyle, enabledValue: NSUnderlineStyle.single.rawValue)
    }
    @objc private func toggleRichEditorOutline() {
        changeRichEditorAttribute(.strokeWidth, enabledValue: -4)
    }
    @objc private func toggleRichEditorBackground() {
        changeRichEditorAttribute(.backgroundColor, enabledValue: NSColor.systemYellow)
    }

    private func changeRichEditorAttribute(_ key: NSAttributedString.Key, enabledValue: Any) {
        guard let editor = richTextEditor, let storage = editor.textStorage else { return }
        let selection = editor.selectedRange()
        let existing = selection.location < storage.length
            ? storage.attribute(key, at: selection.location, effectiveRange: nil) : editor.typingAttributes[key]
        let enabled = existing == nil || ((existing as? NSNumber)?.intValue == 0)
        if selection.length > 0 {
            if enabled { storage.addAttribute(key, value: enabledValue, range: selection) }
            else { storage.removeAttribute(key, range: selection) }
        } else {
            var attributes = editor.typingAttributes
            attributes[key] = enabled ? enabledValue : nil
            editor.typingAttributes = attributes
        }
        editor.window?.makeFirstResponder(editor)
    }

    private func setRichEditorAttribute(_ key: NSAttributedString.Key, value: Any) {
        guard let editor = richTextEditor, let storage = editor.textStorage else { return }
        let selection = editor.selectedRange()
        if selection.length > 0 {
            storage.addAttribute(key, value: value, range: selection)
        } else {
            var attributes = editor.typingAttributes
            attributes[key] = value
            editor.typingAttributes = attributes
        }
        editor.window?.makeFirstResponder(editor)
    }

    @objc private func importStamp() {
        guard let panel else { return }
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.allowsMultipleSelection = false
        chooser.canChooseDirectories = false
        chooser.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = chooser.url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            self?.canvas.stampImage = image
        }
    }

    @objc private func clearStampImage() { canvas.stampImage = nil }

    private func showSampledColor(_ sampled: NativeScreenshotColor) {
        let color = NSColor(calibratedRed: sampled.red, green: sampled.green,
                            blue: sampled.blue, alpha: sampled.alpha)
        colorWell?.color = color
    }

    private func fitCanvasToViewport() {
        guard let scrollView else { return }
        let available = scrollView.contentSize
        let image = canvas.image
        let fit = min((available.width - 24) / CGFloat(image.width),
                      (available.height - 24) / CGFloat(image.height))
        let scale = previewZoom ?? max(0.05, min(1, fit))
        canvas.frame = CGRect(x: 0, y: 0,
                              width: CGFloat(image.width) * scale,
                              height: CGFloat(image.height) * scale)
        dimensionsLabel?.stringValue = "\(image.width) × \(image.height)"
        zoomButton?.title = "\(Int((scale * 100).rounded()))% ▾"
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func setPreviewZoom(_ zoom: CGFloat?) {
        previewZoom = zoom
        fitCanvasToViewport()
        panel?.makeFirstResponder(canvas)
    }

    @objc private func zoom50() { setPreviewZoom(0.5) }
    @objc private func zoom100() { setPreviewZoom(1) }
    @objc private func zoom200() { setPreviewZoom(2) }
    @objc private func zoomFit() { setPreviewZoom(nil) }
    @objc private func zoomIn() { setPreviewZoom(min(8, (previewZoom ?? currentFitScale()) * 1.25)) }
    @objc private func zoomOut() { setPreviewZoom(max(0.1, (previewZoom ?? currentFitScale()) / 1.25)) }

    private func currentFitScale() -> CGFloat {
        guard let scrollView else { return 1 }
        let size = scrollView.contentSize
        return max(0.05, min(1, (size.width - 24) / CGFloat(canvas.image.width),
                            (size.height - 24) / CGFloat(canvas.image.height)))
    }

    @objc private func showZoomMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let zoomActions: [(String, Selector)] = [
            (NativeScreenshotUserText.string("放大", "Zoom In"), #selector(zoomIn)),
            (NativeScreenshotUserText.string("缩小", "Zoom Out"), #selector(zoomOut)),
            (NativeScreenshotText.get(.zoomFit), #selector(zoomFit)),
            (NativeScreenshotText.get(.zoom50), #selector(zoom50)),
            (NativeScreenshotText.get(.zoom100), #selector(zoom100)),
            (NativeScreenshotText.get(.zoom200), #selector(zoom200))
        ]
        for (title, action) in zoomActions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func beginCropFromBar() {
        canvas.tool = .crop
        refreshToolSelection()
        rebuildOptions()
        panel?.makeFirstResponder(canvas)
    }

    @objc private func flipHorizontalFromBar() {
        performImageTransform {
            try NativeScreenshotImageEditor.flip($0, horizontal: true, vertical: false)
        }
    }

    @objc private func flipVerticalFromBar() {
        performImageTransform {
            try NativeScreenshotImageEditor.flip($0, horizontal: false, vertical: true)
        }
    }

    @objc private func appendImageFromBar() {
        guard let panel, busySheet == nil else { return }
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.allowsMultipleSelection = false
        chooser.canChooseDirectories = false
        chooser.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = chooser.url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let incoming = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let self else { return }
            let direction = NSAlert()
            direction.messageText = NativeScreenshotText.get(.appendImage)
            direction.addButton(withTitle: NativeScreenshotText.get(.appendBelow))
            direction.addButton(withTitle: NativeScreenshotText.get(.appendRight))
            direction.addButton(withTitle: NativeScreenshotText.get(.cancel))
            direction.beginSheetModal(for: panel) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .alertFirstButtonReturn:
                    self.performImageTransform {
                        try NativeScreenshotImageEditor.append($0, image: incoming, direction: .below)
                    }
                case .alertSecondButtonReturn:
                    self.performImageTransform {
                        try NativeScreenshotImageEditor.append($0, image: incoming, direction: .right)
                    }
                default: break
                }
            }
        }
    }

    @objc private func pickImageEdit(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        sender.selectItem(at: 0)
        switch index {
        case 1:
            canvas.tool = .crop
            refreshToolSelection()
            rebuildOptions()
            panel?.makeFirstResponder(canvas)
        case 2: applyCrop()
        case 3: performImageTransform { try NativeScreenshotImageEditor.flip($0, horizontal: true, vertical: false) }
        case 4: performImageTransform { try NativeScreenshotImageEditor.flip($0, horizontal: false, vertical: true) }
        case 5: showTransformSettings()
        case 6: showBeautifySettings()
        case 7: showImageEffectsSettings()
        default: break
        }
    }

    @objc private func applyCrop() {
        guard let crop = canvas.cropSelection else {
            showMessage(.noSelection)
            return
        }
        performImageTransform { try NativeScreenshotImageEditor.crop($0, to: crop) }
        canvas.tool = .select
        refreshToolSelection()
        rebuildOptions()
    }

    private func performImageTransform(_ operation: @escaping (CGImage) throws -> CGImage) {
        guard busySheet == nil else { return }
        if !canvas.canPreserveImageUndo {
            let warning = NSAlert()
            warning.messageText = NativeScreenshotText.get(.largeImageUndoWarning)
            warning.addButton(withTitle: NativeScreenshotText.get(.apply))
            warning.addButton(withTitle: NativeScreenshotText.get(.cancel))
            guard warning.runModal() == .alertFirstButtonReturn else { return }
        }
        let snapshot = canvas.renderSnapshot()
        beginBusySheet()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<CGImage?, Error> {
                let flattened = try snapshot.document.annotations.isEmpty ? snapshot.image
                    : NativeScreenshotAnnotationRenderer.render(
                        baseImage: snapshot.image, document: snapshot.document)
                let transformed = try operation(flattened)
                return transformed === flattened ? nil : transformed
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBusySheet()
                guard !self.closing, self.canvas.contentGeneration == snapshot.generation else { return }
                switch result {
                case let .success(image):
                    if let image { self.canvas.commitImageTransform(image) }
                    self.panel?.makeFirstResponder(self.canvas)
                case let .failure(error):
                    if let panel = self.panel { NSAlert(error: error).beginSheetModal(for: panel) }
                }
            }
        }
    }

    private func beginBusySheet() {
        guard let panel, busySheet == nil else { return }
        let sheet = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 250, height: 90),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = NativeScreenshotText.get(.processingImage)
        let indicator = NSProgressIndicator(frame: CGRect(x: 22, y: 28, width: 28, height: 28))
        indicator.style = .spinning
        indicator.startAnimation(nil)
        let label = NSTextField(labelWithString: NativeScreenshotText.get(.processingImage))
        label.frame = CGRect(x: 62, y: 28, width: 170, height: 24)
        sheet.contentView?.addSubview(indicator)
        sheet.contentView?.addSubview(label)
        busySheet = sheet
        panel.beginSheet(sheet)
    }

    private func endBusySheet() {
        guard let sheet = busySheet else { return }
        busySheet = nil
        panel?.endSheet(sheet)
        sheet.close()
    }

    private func showTransformSettings() {
        let scale = NSTextField(string: "100")
        let degrees = NSTextField(string: "0")
        showForm(.transform, controls: [(.scalePercent, scale), (.rotateDegrees, degrees)]) { [weak self] in
            guard let percent = Double(scale.stringValue), percent >= 10, percent <= 400,
                  let angle = Double(degrees.stringValue), angle.isFinite,
                  abs(angle) <= 360 else {
                self?.showMessage(.invalidTransform)
                return
            }
            guard percent != 100 || angle != 0 else { return }
            self?.performImageTransform { image in
                let resized = percent == 100 ? image
                    : try NativeScreenshotImageEditor.scale(image, by: CGFloat(percent / 100))
                return angle == 0 ? resized
                    : try NativeScreenshotImageEditor.rotate(resized, clockwiseDegrees: CGFloat(angle))
            }
        }
    }

    private func showBeautifySettings() {
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: [NativeScreenshotText.get(.roundedMode),
                                   NativeScreenshotText.get(.windowMode)])
        let margin = NSTextField(string: "32")
        let corner = NSTextField(string: "16")
        let shadow = NSTextField(string: "18")
        let rows: [(NativeScreenshotText.Key, NSView)] = [
            (.beautify, mode), (.margin, margin), (.cornerRadius, corner), (.shadow, shadow)
        ]
        func options() -> NativeScreenshotBeautifyOptions? {
            guard let m = Double(margin.stringValue), (0...120).contains(m),
                  let c = Double(corner.stringValue), (0...40).contains(c),
                  let s = Double(shadow.stringValue), (0...60).contains(s) else { return nil }
            return NativeScreenshotBeautifyOptions(
                mode: mode.indexOfSelectedItem == 1 ? .window : .rounded,
                margin: CGFloat(m), cornerRadius: CGFloat(c), shadowRadius: CGFloat(s))
        }
        showPreviewForm(.beautify, controls: rows, buildOperation: {
            guard let value = options() else { return nil }
            return { try NativeScreenshotImageEditor.wrap($0, options: value) }
        }) { [weak self] in
            guard let value = options() else { self?.showMessage(.invalidTransform); return }
            self?.performImageTransform { try NativeScreenshotImageEditor.wrap($0, options: value) }
        }
    }

    private func showImageEffectsSettings() {
        let brightness = NSTextField(string: "0")
        let contrast = NSTextField(string: "1")
        let saturation = NSTextField(string: "1")
        let sharpness = NSTextField(string: "0")
        let rows: [(NativeScreenshotText.Key, NSView)] = [
            (.brightness, brightness), (.contrast, contrast),
            (.saturation, saturation), (.sharpness, sharpness)
        ]
        func adjustments() -> NativeScreenshotImageProcessor.Adjustments? {
            guard let b = Float(brightness.stringValue), (-0.5...0.5).contains(b),
                  let c = Float(contrast.stringValue), (0.5...1.5).contains(c),
                  let s = Float(saturation.stringValue), (0...2).contains(s),
                  let h = Float(sharpness.stringValue), (0...1).contains(h) else { return nil }
            return NativeScreenshotImageProcessor.Adjustments(
                brightness: b, contrast: c, saturation: s, sharpness: h)
        }
        showPreviewForm(.imageEffects, controls: rows, buildOperation: {
            guard let value = adjustments() else { return nil }
            return { try NativeScreenshotImageProcessor.adjust($0, using: value) }
        }) { [weak self] in
            guard let value = adjustments() else { self?.showMessage(.invalidTransform); return }
            self?.performImageTransform { try NativeScreenshotImageProcessor.adjust($0, using: value) }
        }
    }

    private func showPreviewForm(
        _ title: NativeScreenshotText.Key,
        controls: [(NativeScreenshotText.Key, NSView)],
        buildOperation: @escaping () -> ((CGImage) throws -> CGImage)?,
        onApply: @escaping () -> Void
    ) {
        guard let panel else { return }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 370))
        let preview = NSImageView(frame: CGRect(x: 0, y: 150, width: 400, height: 220))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(preview)
        for (index, row) in controls.enumerated() {
            let label = NSTextField(labelWithString: NativeScreenshotText.get(row.0))
            label.frame = CGRect(x: 0, y: CGFloat(controls.count - index - 1) * 36 + 4,
                                 width: 140, height: 24)
            row.1.frame = CGRect(x: 148, y: label.frame.minY, width: 246, height: 26)
            if let field = row.1 as? NSTextField { field.delegate = self }
            if let picker = row.1 as? NSPopUpButton {
                picker.target = self
                picker.action = #selector(refreshLivePreview)
            }
            content.addSubview(label)
            content.addSubview(row.1)
        }
        let state = LivePreview(imageView: preview, controls: controls.map(\.1),
                                buildOperation: buildOperation)
        livePreview?.active = false
        livePreview = state
        let alert = NSAlert()
        alert.messageText = NativeScreenshotText.get(title)
        alert.accessoryView = content
        alert.addButton(withTitle: NativeScreenshotText.get(.apply))
        alert.addButton(withTitle: NativeScreenshotText.get(.cancel))
        alert.beginSheetModal(for: panel) { [weak self] response in
            state.active = false
            state.pending?.cancel()
            if self?.livePreview === state { self?.livePreview = nil }
            if response == .alertFirstButtonReturn { onApply() }
        }
        let baseImage = canvas.image
        let document = canvas.previewDocument
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let source = Self.boundedPreviewSource(
                baseImage: baseImage, document: document, maximumDimension: 480)
            DispatchQueue.main.async {
                guard state.active, self?.livePreview === state else { return }
                state.source = source
                self?.refreshLivePreview()
            }
        }
    }

    @objc private func refreshLivePreview() {
        guard let state = livePreview, state.active, let source = state.source else { return }
        state.generation += 1
        let generation = state.generation
        state.pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard state.active, self?.livePreview === state,
                  let operation = state.buildOperation() else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = try? operation(source)
                DispatchQueue.main.async {
                    guard state.active, self?.livePreview === state,
                          state.generation == generation, let result else { return }
                    state.imageView.image = NSImage(cgImage: result,
                                                    size: NSSize(width: result.width, height: result.height))
                }
            }
        }
        state.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }

    private nonisolated static func thumbnail(_ image: CGImage, maximumDimension: Int) -> CGImage? {
        let scale = min(1, CGFloat(maximumDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Build the entire preview at thumbnail resolution. This keeps temporary
    /// bitmap allocations bounded even for a very large source screenshot.
    nonisolated static func boundedPreviewSource(
        baseImage: CGImage,
        document: NativeScreenshotAnnotationDocument,
        maximumDimension: Int
    ) -> CGImage? {
        guard let base = thumbnail(baseImage, maximumDimension: maximumDimension) else { return nil }
        guard !document.annotations.isEmpty else { return base }
        let factor = CGFloat(base.width) / CGFloat(baseImage.width)
        var scaled = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: base.width, height: base.height))
        for annotation in document.annotations {
            var copy = annotation
            if case let .magnifier(source, destination) = annotation.content {
                copy.content = .magnifier(
                    source: CGRect(x: source.minX * factor, y: source.minY * factor,
                                   width: source.width * factor, height: source.height * factor),
                    destination: CGRect(x: destination.minX * factor, y: destination.minY * factor,
                                        width: destination.width * factor,
                                        height: destination.height * factor))
            } else {
                copy.content = annotation.content.scaled(by: factor, around: .zero)
            }
            copy.style.lineWidth = max(0.5, annotation.style.lineWidth * factor)
            _ = scaled.insert(copy)
        }
        return (try? NativeScreenshotAnnotationRenderer.render(baseImage: base, document: scaled)) ?? base
    }

    private func showForm(
        _ title: NativeScreenshotText.Key,
        controls: [(NativeScreenshotText.Key, NSView)],
        onApply: @escaping () -> Void
    ) {
        guard let panel else { return }
        let content = NSView(frame: CGRect(x: 0, y: 0,
                                           width: 340, height: CGFloat(controls.count * 36)))
        for (index, row) in controls.enumerated() {
            let label = NSTextField(labelWithString: NativeScreenshotText.get(row.0))
            label.frame = CGRect(x: 0, y: CGFloat(controls.count - index - 1) * 36 + 4,
                                 width: 140, height: 24)
            let control = row.1
            control.frame = CGRect(x: 148, y: label.frame.minY,
                                   width: 188, height: 26)
            content.addSubview(label)
            content.addSubview(control)
        }
        let alert = NSAlert()
        alert.messageText = NativeScreenshotText.get(title)
        alert.accessoryView = content
        alert.addButton(withTitle: NativeScreenshotText.get(.apply))
        alert.addButton(withTitle: NativeScreenshotText.get(.cancel))
        alert.beginSheetModal(for: panel) { response in
            if response == .alertFirstButtonReturn { onApply() }
        }
    }

    private func showMessage(_ key: NativeScreenshotText.Key) {
        guard let panel else { return }
        let alert = NSAlert()
        alert.messageText = NativeScreenshotText.get(key)
        alert.addButton(withTitle: NativeScreenshotText.get(.done))
        alert.beginSheetModal(for: panel)
    }

    @objc private func undoEdit() { canvas.undo() }
    @objc private func redoEdit() { canvas.redo() }
    @objc private func confirmEdit() { deliver(.confirm) }
    @objc private func copyFromButton() { copyRenderedImage() }
    @objc private func saveFromButton() { deliver(.save) }
    @objc private func pinFromButton() { deliver(.pin) }
    @objc private func ocrFromButton() { deliver(.ocr) }
    @objc private func qrFromButton() { deliver(.qrCode) }
    @objc private func redactFromButton() { deliver(.autoRedact) }

    private func copyRenderedImage() {
        let snapshot = canvas.renderSnapshot()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<Data, Error> {
                let image = try snapshot.document.annotations.isEmpty ? snapshot.image
                    : NativeScreenshotAnnotationRenderer.render(
                        baseImage: snapshot.image, document: snapshot.document)
                return try NativeScreenshotImageProcessor.encode(image, as: .png)
            }
            DispatchQueue.main.async {
                guard let self, !self.closing,
                      self.canvas.contentGeneration == snapshot.generation else { return }
                switch result {
                case let .success(data):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(data, forType: .png)
                case let .failure(error):
                    if let panel = self.panel { NSAlert(error: error).beginSheetModal(for: panel) }
                }
            }
        }
    }

    private func deliver(_ action: NativeScreenshotDeliveryAction) {
        guard busySheet == nil else { return }
        let snapshot = canvas.renderSnapshot()
        beginBusySheet()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try snapshot.document.annotations.isEmpty ? snapshot.image
                : NativeScreenshotAnnotationRenderer.render(
                    baseImage: snapshot.image, document: snapshot.document) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBusySheet()
                guard !self.closing, self.canvas.contentGeneration == snapshot.generation else { return }
                switch result {
                case let .success(image):
                    self.onAction(action, NativeScreenshotCapturedImage(
                        image: image, sourceRect: self.base.sourceRect,
                        pixelsPerPoint: self.base.pixelsPerPoint))
                case let .failure(error):
                    if let panel = self.panel { NSAlert(error: error).beginSheetModal(for: panel) }
                }
            }
        }
    }

    private static func title(for kind: NativeScreenshotAnnotationKind) -> String {
        switch kind {
        case .pencil: return NativeScreenshotText.get(.pencil)
        case .line: return NativeScreenshotText.get(.line)
        case .arrow: return NativeScreenshotText.get(.arrow)
        case .rectangle: return NativeScreenshotText.get(.rectangle)
        case .filledRectangle: return NativeScreenshotText.get(.filledRectangle)
        case .ellipse: return NativeScreenshotText.get(.ellipse)
        case .highlighter: return NativeScreenshotText.get(.highlighter)
        case .richText: return NativeScreenshotText.get(.richText)
        case .number: return NativeScreenshotText.get(.number)
        case .stamp: return NativeScreenshotText.get(.stamp)
        case .pixelate: return NativeScreenshotText.get(.pixelate)
        case .blur: return NativeScreenshotText.get(.blur)
        case .solidCensor: return NativeScreenshotText.get(.solidCensor)
        case .eraseCensor: return NativeScreenshotText.get(.eraseCensor)
        case .magnifier: return NativeScreenshotText.get(.magnifier)
        case .ruler: return NativeScreenshotText.get(.ruler)
        case .colorSampler: return NativeScreenshotText.get(.colorSampler)
        case .spotlight: return NativeScreenshotText.get(.spotlight)
        }
    }

}

/// Keep a smaller image centered while the user resizes the detached editor.
@available(macOS 13.0, *)
private final class NativeScreenshotEditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if documentView.frame.width < rect.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if documentView.frame.height < rect.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}

enum NativeScreenshotCanvasTool {
    case select
    case crop
    case annotation(NativeScreenshotAnnotationKind)
}

@available(macOS 13.0, *)
final class NativeScreenshotAnnotationCanvasView: NSView {
    private static let internalAnnotationType = NSPasteboard.PasteboardType(
        "com.clipyclone.screenshot.annotation")
    private static var internalClipboard: (annotation: NativeScreenshotAnnotation, changeCount: Int)?
    private(set) var image: CGImage
    private var baselineImage: CGImage
    private var document: NativeScreenshotAnnotationDocument
    var previewDocument: NativeScreenshotAnnotationDocument { document }
    struct RenderSnapshot {
        let image: CGImage
        let document: NativeScreenshotAnnotationDocument
        let generation: UInt64
    }
    private(set) var contentGeneration: UInt64 = 0
    private var displayImage: CGImage?
    private var transientPreviewImage: CGImage?
    private var displayAttemptedGeneration: UInt64?
    private var displayWork: DispatchWorkItem?
    private let displayQueue = DispatchQueue(label: "clipy.screenshot.canvas-preview", qos: .userInitiated)
    private var cachedImage: CGImage?
    private var cachedRevision: UInt64?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var samples: [CGPoint] = []
    private var pressureSamples: [NativeScreenshotStrokeSample] = []
    private var movingAnnotationID: UUID?
    private var selectedAnnotationID: UUID?
    private struct ImageSnapshot {
        let image: CGImage
        let document: NativeScreenshotAnnotationDocument
    }
    private var imageUndo: [ImageSnapshot] = []
    private var imageRedo: [ImageSnapshot] = []
    private let imageUndoByteLimit = 256 * 1024 * 1024

    var tool: NativeScreenshotCanvasTool = .select
    var style = NativeScreenshotAnnotationStyle()
    var textProvider: (() -> String)?
    var textOverride: String?
    var onSampledColor: ((NativeScreenshotColor) -> Void)?
    var onEscape: (() -> Void)?
    var onImageSizeChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onContentChanged: (() -> Void)?
    var onToolShortcut: ((NativeScreenshotAnnotationKind?) -> Void)?
    var onCopyImage: (() -> Void)?
    var onSaveImage: (() -> Void)?
    var arrowStyle: NativeScreenshotArrowStyle = .solid
    var pencilSmoothing: NativeScreenshotPencilSmoothing = .smooth
    var pressureEnabled = false
    var textBold = false
    var textItalic = false
    var textUnderline = false
    var textOutlineWidth: CGFloat = 0
    var textBackgroundEnabled = false
    var textBackgroundColor: NativeScreenshotColor = .yellow
    var textFontSize: CGFloat = 24
    var textFontName: String?
    var stampImage: CGImage?
    var smartMarkerEnabled = false
    var pixelBlockSize: CGFloat = 12
    var blurRadius: CGFloat = 12
    var magnifierScale: CGFloat = 1.5
    private(set) var cropSelection: CGRect?

    var canPreserveImageUndo: Bool { image.bytesPerRow * image.height <= imageUndoByteLimit }
    var hasUnsavedEdits: Bool { image !== baselineImage || !document.annotations.isEmpty }
    var hasImageTransform: Bool { image !== baselineImage }
    var hasSelectedAnnotation: Bool { selectedAnnotationID != nil }

    init(image: CGImage) {
        self.image = image
        baselineImage = image
        document = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: image.width, height: image.height)
        )
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleDisplayPreview() }
        else {
            displayWork?.cancel()
            displayWork = nil
            if displayImage == nil { displayAttemptedGeneration = nil }
        }
    }

    func renderSnapshot() -> RenderSnapshot {
        RenderSnapshot(image: image, document: document, generation: contentGeneration)
    }

    func renderedImage() throws -> CGImage {
        if let cachedImage, cachedRevision == document.revision { return cachedImage }
        if document.annotations.isEmpty { return image }
        let result = try NativeScreenshotAnnotationRenderer.render(baseImage: image, document: document)
        if result.bytesPerRow * result.height <= imageUndoByteLimit {
            cachedImage = result
            cachedRevision = document.revision
        }
        return result
    }

    func showTransientPreview(_ preview: CGImage?) {
        transientPreviewImage = preview
        needsDisplay = true
    }

    func undo() {
        if document.undo() {
            invalidateRendered()
        } else if let previous = imageUndo.popLast() {
            imageRedo.append(ImageSnapshot(image: image, document: document))
            image = previous.image
            document = previous.document
            selectedAnnotationID = nil
            cropSelection = nil
            onImageSizeChanged?()
            invalidateRendered()
        }
    }

    func redo() {
        if document.redo() {
            invalidateRendered()
        } else if let next = imageRedo.popLast() {
            imageUndo.append(ImageSnapshot(image: image, document: document))
            image = next.image
            document = next.document
            selectedAnnotationID = nil
            cropSelection = nil
            onImageSizeChanged?()
            invalidateRendered()
        }
    }

    func scaleSelection(by factor: CGFloat) {
        guard let selectedAnnotationID,
              var annotation = document.annotations.first(where: { $0.id == selectedAnnotationID }) else { return }
        let center = CGPoint(x: annotation.content.editingBounds(lineWidth: annotation.style.lineWidth).midX,
                             y: annotation.content.editingBounds(lineWidth: annotation.style.lineWidth).midY)
        annotation.content = annotation.content.scaled(by: factor, around: center)
        annotation.style.lineWidth = max(0.5, annotation.style.lineWidth * factor)
        if document.replace(annotation) {
            imageRedo.removeAll()
            invalidateRendered()
        }
    }

    func selectAnnotation(at point: CGPoint) {
        let tolerance = max(6, 6 * CGFloat(image.width) / max(1, bounds.width))
        let annotation = document.annotation(at: point, tolerance: tolerance)
        selectedAnnotationID = annotation?.id
        if case let .richText(_, runs)? = annotation?.content,
           let first = runs.first {
            textOverride = runs.map(\.text).joined()
            textFontSize = first.fontSize
            textFontName = first.fontName
            textBold = first.bold
            textItalic = first.italic
            textUnderline = first.underline
            textOutlineWidth = first.outlineWidth
            textBackgroundEnabled = first.backgroundColor != nil
            if let background = first.backgroundColor { textBackgroundColor = background }
            style.strokeColor = first.color
            style.fillColor = first.color
        }
        onSelectionChanged?()
        needsDisplay = true
    }

    func clearSelection() {
        selectedAnnotationID = nil
        onSelectionChanged?()
        needsDisplay = true
    }

    var selectedRichText: String? {
        guard let selectedAnnotationID,
              let annotation = document.annotations.first(where: { $0.id == selectedAnnotationID }),
              case let .richText(_, runs) = annotation.content else { return nil }
        return runs.map(\.text).joined()
    }

    var selectedRichTextRuns: [NativeScreenshotTextRun]? {
        guard let selectedAnnotationID,
              let annotation = document.annotations.first(where: { $0.id == selectedAnnotationID }),
              case let .richText(_, runs) = annotation.content else { return nil }
        return runs
    }

    @discardableResult
    func replaceSelectedText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let current = selectedRichTextRuns else { return false }
        var replacement = current.first ?? NativeScreenshotTextRun(text: text)
        replacement.text = text
        return replaceSelectedRichText([replacement])
    }

    @discardableResult
    func replaceSelectedRichText(_ runs: [NativeScreenshotTextRun]) -> Bool {
        guard runs.contains(where: { !$0.text.isEmpty }),
              let selectedAnnotationID,
              var annotation = document.annotations.first(where: { $0.id == selectedAnnotationID }),
              case let .richText(rect, _) = annotation.content else { return false }
        annotation.content = .richText(rect: fittingTextRect(rect, runs: runs), runs: runs)
        guard document.replace(annotation) else { return false }
        textOverride = nil
        imageRedo.removeAll()
        invalidateRendered()
        return true
    }

    @discardableResult
    func updateSelectedRichTextStyle() -> Bool {
        guard let selectedAnnotationID,
              var annotation = document.annotations.first(where: { $0.id == selectedAnnotationID }),
              case let .richText(rect, runs) = annotation.content else { return false }
        guard runs.contains(where: { !$0.text.isEmpty }) else { return false }
        let editedRuns = runs.map { run in
            var edited = run
            edited.color = style.strokeColor
            edited.fontSize = textFontSize
            edited.fontName = textFontName
            edited.bold = textBold
            edited.italic = textItalic
            edited.underline = textUnderline
            edited.outlineWidth = textOutlineWidth
            edited.backgroundColor = textBackgroundEnabled ? textBackgroundColor : nil
            return edited
        }
        annotation.content = .richText(rect: fittingTextRect(rect, runs: editedRuns), runs: editedRuns)
        guard document.replace(annotation) else { return false }
        imageRedo.removeAll()
        invalidateRendered()
        return true
    }

    @discardableResult
    func insertAnnotation(_ annotation: NativeScreenshotAnnotation) -> Bool {
        guard document.insert(annotation) else { return false }
        selectedAnnotationID = annotation.id
        imageRedo.removeAll()
        invalidateRendered()
        return true
    }

    @discardableResult
    func insertAnnotations(_ annotations: [NativeScreenshotAnnotation]) -> Int {
        let inserted = document.insertBatch(annotations)
        guard inserted > 0 else { return 0 }
        selectedAnnotationID = nil
        imageRedo.removeAll()
        invalidateRendered()
        return inserted
    }

    func deleteSelection() {
        guard let selectedAnnotationID, document.remove(id: selectedAnnotationID) else { return }
        self.selectedAnnotationID = nil
        imageRedo.removeAll()
        invalidateRendered()
    }

    @discardableResult
    func duplicateSelection() -> Bool {
        guard let selectedAnnotationID,
              let selected = document.annotations.first(where: { $0.id == selectedAnnotationID }) else {
            return false
        }
        return insertCopy(of: selected)
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let selectedAnnotationID,
              let selected = document.annotations.first(where: { $0.id == selectedAnnotationID }) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data([1]), forType: Self.internalAnnotationType)
        Self.internalClipboard = (selected, pasteboard.changeCount)
        return true
    }

    @discardableResult
    func pasteSelection() -> Bool {
        let pasteboard = NSPasteboard.general
        if let copied = Self.internalClipboard,
           copied.changeCount == pasteboard.changeCount,
           pasteboard.data(forType: Self.internalAnnotationType) != nil {
            return insertCopy(of: copied.annotation)
        }
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let source = try? NativeScreenshotImageProcessor.cgImage(from: image),
              source.width > 0, source.height > 0,
              source.width <= 8_192, source.height <= 8_192,
              source.width <= 16_000_000 / source.height else { return false }
        let maxSide = min(CGFloat(self.image.width), CGFloat(self.image.height)) * 0.65
        let factor = min(1, maxSide / CGFloat(max(source.width, source.height)))
        let size = CGSize(width: max(1, CGFloat(source.width) * factor),
                          height: max(1, CGFloat(source.height) * factor))
        let rect = CGRect(x: max(0, (CGFloat(self.image.width) - size.width) / 2),
                          y: max(0, (CGFloat(self.image.height) - size.height) / 2),
                          width: size.width, height: size.height)
        return insertAnnotation(NativeScreenshotAnnotation(
            content: .stamp(rect: rect, content: .image(source)), style: style))
    }

    private func insertCopy(of original: NativeScreenshotAnnotation) -> Bool {
        var copy = original
        copy.id = UUID()
        copy.content = original.content.translated(by: CGSize(width: 16, height: 16))
        return insertAnnotation(copy)
    }

    func applyImageTransform(_ operation: (CGImage) throws -> CGImage) throws {
        let flattened = try renderedImage()
        let transformed = try operation(flattened)
        guard transformed !== flattened else { return }
        commitImageTransform(transformed)
    }

    func commitImageTransform(_ transformed: CGImage) {
        if canPreserveImageUndo {
            imageUndo.append(ImageSnapshot(image: image, document: document))
            while imageUndo.count > 1 && imageUndo.reduce(0, {
                $0 + $1.image.bytesPerRow * $1.image.height
            }) > imageUndoByteLimit {
                imageUndo.removeFirst()
            }
        } else {
            imageUndo.removeAll()
        }
        imageRedo.removeAll()
        image = transformed
        document = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: transformed.width, height: transformed.height))
        selectedAnnotationID = nil
        cropSelection = nil
        onImageSizeChanged?()
        invalidateRendered()
    }

    func installPreparedImage(_ prepared: CGImage) {
        guard document.annotations.isEmpty else { return }
        image = prepared
        baselineImage = prepared
        document = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: prepared.width, height: prepared.height))
        onImageSizeChanged?()
        invalidateRendered()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let transientPreviewImage {
            NSColor.black.setFill()
            bounds.fill()
            let width = CGFloat(transientPreviewImage.width)
            let height = CGFloat(transientPreviewImage.height)
            let scale = min(bounds.width / max(1, width), bounds.height / max(1, height))
            let fitted = CGRect(x: (bounds.width - width * scale) / 2,
                                y: (bounds.height - height * scale) / 2,
                                width: width * scale, height: height * scale)
            NSImage(cgImage: transientPreviewImage,
                    size: CGSize(width: width, height: height)).draw(in: fitted)
        } else if let displayImage {
            NSImage(cgImage: displayImage, size: bounds.size).draw(in: bounds)
        } else {
            NSColor.black.setFill()
            bounds.fill()
            scheduleDisplayPreview()
            if displayWork == nil, displayAttemptedGeneration == contentGeneration {
                let message = NativeScreenshotText.get(.previewUnavailable)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white
                ]
                let size = message.size(withAttributes: attributes)
                message.draw(at: CGPoint(x: max(0, (bounds.width - size.width) / 2),
                                         y: max(0, (bounds.height - size.height) / 2)),
                             withAttributes: attributes)
            }
        }
        if let selectedAnnotationID,
           let annotation = document.annotations.first(where: { $0.id == selectedAnnotationID }) {
            strokeGuide(annotation.content.editingBounds(lineWidth: annotation.style.lineWidth),
                        color: .controlAccentColor)
        }
        if let cropSelection {
            strokeGuide(cropSelection, color: .systemYellow)
        }
        guard let start = dragStart, let end = dragCurrent else { return }
        switch tool {
        case .select: return
        case .annotation, .crop: break
        }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        if samples.count > 1 {
            path.move(to: viewPoint(samples[0]))
            for sample in samples.dropFirst() { path.line(to: viewPoint(sample)) }
        } else {
            let a = viewPoint(start)
            let b = viewPoint(end)
            path.appendRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                   width: abs(a.x - b.x), height: abs(a.y - b.y)))
        }
        path.stroke()
    }

    private func strokeGuide(_ pixelRect: CGRect, color: NSColor) {
        let topLeft = viewPoint(pixelRect.origin)
        let bottomRight = viewPoint(CGPoint(x: pixelRect.maxX, y: pixelRect.maxY))
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.setLineDash([5, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = pixelPoint(event)
        dragStart = point
        dragCurrent = point
        samples = [point]
        pressureSamples = [NativeScreenshotStrokeSample(point, pressure: strokePressure(event))]
        switch tool {
        case .select:
            selectAnnotation(at: point)
            movingAnnotationID = selectedAnnotationID
        case .crop:
            cropSelection = nil
            selectedAnnotationID = nil
        case .annotation:
            selectedAnnotationID = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = pixelPoint(event)
        dragCurrent = point
        if case let .annotation(kind) = tool,
           kind == .pencil || kind == .highlighter {
            samples.append(point)
            pressureSamples.append(NativeScreenshotStrokeSample(
                point, pressure: strokePressure(event)))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = pixelPoint(event)
        var changedPixels = false
        switch tool {
        case .select:
            if let movingAnnotationID {
                let dx = end.x - start.x
                let dy = end.y - start.y
                if abs(dx) > 0.5 || abs(dy) > 0.5 {
                    let changed = document.move(id: movingAnnotationID,
                                                by: CGSize(width: dx, height: dy))
                    if changed {
                        changedPixels = true
                        imageRedo.removeAll()
                    }
                }
            }
        case .crop:
            let rect = dragRect(from: start, to: end)
            cropSelection = rect.width >= 2 && rect.height >= 2 ? rect : nil
        case let .annotation(kind):
            if kind == .colorSampler {
                sampleColor(at: end)
            } else if let content = annotationContent(kind: kind, start: start, end: end) {
                var annotationStyle = style
                if kind == .highlighter && smartMarkerEnabled {
                    annotationStyle.lineWidth = max(12, min(120, abs(end.y - start.y)))
                }
                let annotation = NativeScreenshotAnnotation(content: content, style: annotationStyle)
                changedPixels = insertAnnotation(annotation)
            }
        }
        dragStart = nil
        dragCurrent = nil
        movingAnnotationID = nil
        samples.removeAll()
        pressureSamples.removeAll()
        if changedPixels { invalidateRendered() } else { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if selectedAnnotationID != nil { clearSelection() }
            else {
                switch tool {
                case .select: onEscape?()
                case .crop, .annotation:
                    tool = .select
                    onToolShortcut?(nil)
                }
            }
        } else if event.modifierFlags.contains(.command) && event.keyCode == 6 {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
        } else if event.modifierFlags.contains(.command) && event.keyCode == 8 {
            if !copySelection() { onCopyImage?() }
        } else if event.modifierFlags.contains(.command) && event.keyCode == 9 {
            _ = pasteSelection()
        } else if event.modifierFlags.contains(.command) && event.keyCode == 2 {
            _ = duplicateSelection()
        } else if event.modifierFlags.contains(.command) && event.keyCode == 1 {
            onSaveImage?()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
        } else if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            super.keyDown(with: event)
        } else if let key = event.charactersIgnoringModifiers?.lowercased(),
                  let toolID = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
                    .toolID(forShortcut: key) {
            let kind = NativeScreenshotAnnotationKind(rawValue: toolID)
            if let kind { tool = .annotation(kind) } else { tool = .select }
            clearSelection()
            onToolShortcut?(kind)
        } else {
            super.keyDown(with: event)
        }
    }

    private func strokePressure(_ event: NSEvent) -> CGFloat {
        guard pressureEnabled, event.pressure > 0 else { return 1 }
        return max(0.1, min(1, CGFloat(event.pressure)))
    }

    private func dragRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    func annotationContent(
        kind: NativeScreenshotAnnotationKind, start: CGPoint, end: CGPoint
    ) -> NativeScreenshotAnnotationContent? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: max(1, abs(start.x - end.x)),
                          height: max(1, abs(start.y - end.y)))
        switch kind {
        case .pencil:
            let points = pressureSamples.isEmpty
                ? [NativeScreenshotStrokeSample(start), NativeScreenshotStrokeSample(end)]
                : pressureSamples + [NativeScreenshotStrokeSample(end,
                    pressure: pressureSamples.last?.pressure ?? 1)]
            return .pencil(samples: points, smoothing: pencilSmoothing)
        case .line: return .line(start: start, end: end)
        case .arrow: return .arrow(start: start, end: end, style: arrowStyle)
        case .rectangle: return .rectangle(rect)
        case .filledRectangle: return .filledRectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .highlighter: return .highlighter(points: samples + [end])
        case .richText:
            let value = textOverride ?? textProvider?() ?? ""
            guard !value.isEmpty else { return nil }
            let runs = [NativeScreenshotTextRun(
                                text: value, color: style.strokeColor,
                                fontName: textFontName,
                                fontSize: textFontSize, bold: textBold, italic: textItalic,
                                underline: textUnderline, outlineWidth: textOutlineWidth,
                                backgroundColor: textBackgroundEnabled ? textBackgroundColor : nil)]
            let textRect = CGRect(x: rect.minX, y: rect.minY,
                                  width: max(120, rect.width), height: max(44, rect.height))
            return .richText(rect: fittingTextRect(textRect, runs: runs), runs: runs)
        case .number:
            return .number(center: end, value: document.nextNumber)
        case .stamp:
            let input = textProvider?() ?? ""
            let value = input.isEmpty ? "⭐️" : input
            return .stamp(rect: CGRect(x: rect.minX, y: rect.minY,
                                       width: max(48, rect.width), height: max(48, rect.height)),
                          content: stampImage.map(NativeScreenshotStamp.image) ?? .emoji(value))
        case .pixelate: return .pixelate(rect: rect, blockSize: pixelBlockSize)
        case .blur: return .blur(rect: rect, radius: blurRadius)
        case .solidCensor: return .solidCensor(rect)
        case .eraseCensor: return .eraseCensor(rect)
        case .magnifier:
            let width = min(CGFloat(image.width), max(24, rect.width * magnifierScale))
            let height = min(CGFloat(image.height), max(24, rect.height * magnifierScale))
            let destination = CGRect(
                x: min(max(0, rect.maxX + 16), CGFloat(image.width) - width),
                y: min(max(0, rect.minY), CGFloat(image.height) - height),
                width: width, height: height
            )
            return .magnifier(source: rect, destination: destination)
        case .ruler: return .ruler(start: start, end: end)
        case .colorSampler: return nil
        case .spotlight: return .spotlight(rect)
        }
    }

    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(CGFloat(image.width), max(0, local.x * CGFloat(image.width) / max(1, bounds.width))),
            y: min(CGFloat(image.height), max(0, local.y * CGFloat(image.height) / max(1, bounds.height)))
        )
    }

    private func viewPoint(_ pixel: CGPoint) -> CGPoint {
        CGPoint(x: pixel.x * bounds.width / CGFloat(image.width),
                y: pixel.y * bounds.height / CGFloat(image.height))
    }

    private func fittingTextRect(_ rect: CGRect, runs: [NativeScreenshotTextRun]) -> CGRect {
        let width = max(1, min(rect.width, CGFloat(image.width)))
        let required = NativeScreenshotRichText.requiredHeight(for: runs, width: width)
        let height = min(CGFloat(image.height), max(rect.height, required))
        return CGRect(x: min(max(0, rect.minX), max(0, CGFloat(image.width) - width)),
                      y: min(max(0, rect.minY), max(0, CGFloat(image.height) - height)),
                      width: width, height: height)
    }

    private func invalidateRendered() {
        contentGeneration &+= 1
        transientPreviewImage = nil
        cachedImage = nil
        cachedRevision = nil
        displayImage = nil
        displayAttemptedGeneration = nil
        displayWork?.cancel()
        displayWork = nil
        scheduleDisplayPreview()
        needsDisplay = true
        onContentChanged?()
    }

    private func scheduleDisplayPreview() {
        guard window != nil, displayImage == nil,
              displayAttemptedGeneration != contentGeneration else { return }
        displayAttemptedGeneration = contentGeneration
        let snapshot = renderSnapshot()
        let work = DispatchWorkItem { [weak self] in
            let preview = NativeScreenshotEditorController.boundedPreviewSource(
                baseImage: snapshot.image, document: snapshot.document,
                maximumDimension: 2048)
            DispatchQueue.main.async {
                guard let self, self.window != nil,
                      self.contentGeneration == snapshot.generation else { return }
                self.displayWork = nil
                self.displayImage = preview
                self.needsDisplay = true
            }
        }
        displayWork = work
        displayQueue.async(execute: work)
    }

    private func sampleColor(at point: CGPoint) {
        let snapshot = renderSnapshot()
        if snapshot.document.annotations.isEmpty {
            if let sampled = NativeScreenshotAnnotationRenderer.sampleColor(at: point, in: snapshot.image) {
                applySampledColor(sampled)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rendered = try? NativeScreenshotAnnotationRenderer.render(
                baseImage: snapshot.image, document: snapshot.document)
            let sampled = rendered.flatMap {
                NativeScreenshotAnnotationRenderer.sampleColor(at: point, in: $0)
            }
            DispatchQueue.main.async {
                guard let self, self.contentGeneration == snapshot.generation,
                      let sampled else { return }
                self.applySampledColor(sampled)
            }
        }
    }

    private func applySampledColor(_ sampled: NativeScreenshotColor) {
        style.strokeColor = sampled
        style.fillColor = sampled
        onSampledColor?(sampled)
    }
}
