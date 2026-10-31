import Cocoa

/// V3 editor chrome (UI/design-v3/screens/mac-annotation.html):
/// unified 52pt title-bar row (window title · drawing tools · crop/flip/add capture ·
/// undo/redo · zoom), dark canvas, 268pt inspector (tool header, color, tool
/// options, Beautify, Image Effects) and a 54pt action footer.
/// Every control routes to the existing OverlayView / delegate commands.
final class EditorChromeView: NSView {
    weak var overlayView: OverlayView? { didSet { refreshFromOverlay() } }
    /// Drawing-tool strip created by OverlayView (tools only in editor mode).
    weak var toolStrip: ToolbarStripView? { didSet { if oldValue !== toolStrip { needsLayout = true } } }
    var onDone: (() -> Void)?

    static let toolbarHeight: CGFloat = 52
    static let footerHeight: CGFloat = 54
    static let inspectorWidth: CGFloat = 268

    /// Not flipped: an NSScrollView inside a flipped parent erases sibling drawing
    /// when the hierarchy is cached (snapshot). Layout is written top-down and
    /// converted with `fl(_:)`.
    private func fl(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Colors (mac.css tokens)
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static let toolBackground = dynamic(NSColor(white: 0.985, alpha: 1), NSColor(srgbRed: 0.137, green: 0.137, blue: 0.153, alpha: 1))
    static let inspectorBackground = dynamic(.white, NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1))
    static let line = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09))
    static let fill = dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06))
    static let selection = dynamic(NSColor.controlAccentColor.withAlphaComponent(0.11), NSColor.controlAccentColor.withAlphaComponent(0.2))

    // MARK: Title-bar row
    private let titleLabel = NSTextField(labelWithString: "")
    private let cropButton = EditorIconButton(symbol: "crop", tip: L("Crop"))
    private let flipHButton = EditorIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", tip: L("Flip Horizontal"))
    private let flipVButton = EditorIconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", tip: L("Flip Vertical"))
    private let addCaptureButton = EditorIconButton(symbol: "photo.badge.plus", tip: L("Add Capture"))
    private let undoButton = EditorIconButton(symbol: "arrow.uturn.backward", tip: L("Undo"))
    private let redoButton = EditorIconButton(symbol: "arrow.uturn.forward", tip: L("Redo"))
    private let zoomButton = EditorZoomButton()
    private var toolSeparatorX: CGFloat = 0
    private var undoSeparatorX: CGFloat = 0

    // MARK: Inspector
    private let inspectorScroll = NSScrollView()
    private let inspectorDocument = FlippedView()
    private var optionsView: ToolOptionsRowView?
    private let headerIcon = NSImageView()
    private let headerIconBox = TileView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerSelection = NSTextField(labelWithString: "")
    private let colorTitle = NSTextField(labelWithString: L("Color"))
    private let colorHex = NSTextField(labelWithString: "")
    private var colorSwatches: [TileView] = []
    private let opacityLabel = NSTextField(labelWithString: L("Opacity"))
    private let opacitySlider = NSSlider(value: 1, minValue: 0.05, maxValue: 1, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "100%")
    private let moreColorsButton = NSButton()
    private let toolHint = NSTextField(wrappingLabelWithString: L("Click the canvas to sample a color; it becomes the current annotation color."))
    private let divider1 = FlippedView()
    private let beautifyTitle = NSTextField(labelWithString: L("Beautify"))
    private let beautifySwitch = NSSwitch()
    private let beautifyMode = NSSegmentedControl()
    private var gradientTiles: [TileView] = []
    private let gradientMoreTile = TileView()
    private var beautifyRows: [(NSTextField, NSSlider, NSTextField)] = []
    private let divider2 = FlippedView()
    private let effectsTitle = NSTextField(labelWithString: L("Adjust (Image Effects)"))
    private let effectsReset = NSButton()
    private var presetTiles: [TileView] = []
    private var effectRows: [(NSTextField, NSSlider, NSTextField)] = []
    private let invertButton = NSButton()
    private let removeBackgroundButton = NSButton()

    // MARK: Footer
    private let statusLabel = NSTextField(labelWithString: "")
    private var footerLeading: [NSButton] = []
    private let pinButton = EditorFooterButton()
    private let shareButton = EditorFooterButton()
    private let ocrButton = EditorFooterButton()
    private let translateButton = EditorFooterButton()
    #if !OFFLINE
    private let uploadButton = EditorFooterButton()
    #endif
    private let copyButton = EditorFooterButton()
    private let saveButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let doneButton = EditorFooterButton()
    private var footerSeparatorX: CGFloat = 0
    private var pixelSize: (Int, Int) = (0, 0)
    private var isDoneVisible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUpTitleRow()
        setUpInspector()
        setUpFooter()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setUpTitleRow() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        for (button, action) in [(cropButton, #selector(cropClicked)), (flipHButton, #selector(flipHClicked)),
                                 (flipVButton, #selector(flipVClicked)), (addCaptureButton, #selector(addCaptureClicked)),
                                 (undoButton, #selector(undoClicked)), (redoButton, #selector(redoClicked))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        zoomButton.target = self
        zoomButton.action = #selector(zoomButtonClicked)
        addSubview(zoomButton)
    }

    private func label(_ field: NSTextField, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) {
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        inspectorDocument.addSubview(field)
    }

    private func setUpInspector() {
        inspectorScroll.drawsBackground = false
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.autohidesScrollers = true
        inspectorScroll.scrollerStyle = .overlay
        inspectorScroll.documentView = inspectorDocument
        addSubview(inspectorScroll)

        headerIconBox.cornerRadius = 7
        headerIconBox.fillColor = Self.selection
        inspectorDocument.addSubview(headerIconBox)
        headerIcon.contentTintColor = .controlAccentColor
        headerIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        inspectorDocument.addSubview(headerIcon)
        label(headerName, size: 13, weight: .semibold, color: .labelColor)
        label(headerSelection, size: 11, weight: .medium, color: .tertiaryLabelColor)

        label(colorTitle, size: 11, weight: .semibold, color: .tertiaryLabelColor)
        label(colorHex, size: 11, weight: .medium)
        for (index, color) in ColorPickerView.presetColors.enumerated() {
            let tile = TileView()
            tile.fillColor = color
            tile.isCircle = true
            tile.tag = index
            tile.onClick = { [weak self] in self?.overlayView?.applyInspectorColor(color) }
            tile.setAccessibilityLabel(L("Color"))
            colorSwatches.append(tile)
            inspectorDocument.addSubview(tile)
        }
        label(opacityLabel)
        toolHint.font = .systemFont(ofSize: 11.5)
        toolHint.textColor = .tertiaryLabelColor
        inspectorDocument.addSubview(toolHint)
        opacitySlider.controlSize = .small
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        inspectorDocument.addSubview(opacitySlider)
        label(opacityValue, color: .labelColor)
        opacityValue.alignment = .right
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        configurePlain(moreColorsButton, title: L("More Colors…"), symbol: "paintpalette", action: #selector(moreColorsClicked))
        inspectorDocument.addSubview(moreColorsButton)

        for divider in [divider1, divider2] {
            divider.wantsLayer = false
            inspectorDocument.addSubview(divider)
        }

        label(beautifyTitle, size: 11, weight: .semibold, color: .tertiaryLabelColor)
        beautifySwitch.controlSize = .mini
        beautifySwitch.target = self
        beautifySwitch.action = #selector(beautifyToggled)
        inspectorDocument.addSubview(beautifySwitch)
        beautifyMode.segmentCount = 2
        beautifyMode.trackingMode = .selectOne
        beautifyMode.setLabel(L("Window"), forSegment: 0)
        beautifyMode.setLabel(L("Rounded"), forSegment: 1)
        beautifyMode.setImage(NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil), forSegment: 0)
        beautifyMode.setImage(NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil), forSegment: 1)
        beautifyMode.font = .systemFont(ofSize: 12)
        beautifyMode.selectedSegmentBezelColor = .controlColor
        beautifyMode.target = self
        beautifyMode.action = #selector(beautifyModeChanged)
        inspectorDocument.addSubview(beautifyMode)
        for slot in 0..<4 {
            let tile = TileView()
            tile.cornerRadius = 7
            tile.tag = slot
            tile.onClick = { [weak self, weak tile] in
                guard let tile else { return }
                self?.overlayView?.selectBeautifyStyle(tile.styleIndex)
            }
            gradientTiles.append(tile)
            inspectorDocument.addSubview(tile)
        }
        gradientMoreTile.cornerRadius = 7
        gradientMoreTile.fillColor = Self.fill
        gradientMoreTile.symbol = "photo"
        gradientMoreTile.toolTip = L("Gradient Style")
        gradientMoreTile.onClick = { [weak self] in
            guard let self, let ov = self.overlayView else { return }
            if PopoverHelper.toggleClosedIfOpen() { return }
            ov.showBeautifyGradientPopover(anchorView: self.gradientMoreTile)
        }
        inspectorDocument.addSubview(gradientMoreTile)
        for (title, minValue, maxValue, action) in [
            (L("Padding"), 16.0, 96.0, #selector(beautifyPaddingChanged(_:))),
            (L("Radius"), 0.0, 30.0, #selector(beautifyRadiusChanged(_:))),
            (L("Shadow"), 0.0, 100.0, #selector(beautifyShadowChanged(_:))),
            (L("Blur"), 0.0, 50.0, #selector(beautifyBlurChanged(_:))),
        ] {
            beautifyRows.append(makeSliderRow(title, minValue, maxValue, action))
        }

        label(effectsTitle, size: 11, weight: .semibold, color: .tertiaryLabelColor)
        configurePlain(effectsReset, title: L("Reset"), symbol: nil, action: #selector(effectsResetClicked))
        inspectorDocument.addSubview(effectsReset)
        for preset in ImageEffectPreset.allCases {
            let tile = TileView()
            tile.cornerRadius = 6
            tile.image = ImageEffects.presetSwatch(preset, size: 52)
            tile.caption = preset.displayName
            tile.onClick = { [weak self] in self?.selectPreset(preset) }
            presetTiles.append(tile)
            inspectorDocument.addSubview(tile)
        }
        for (title, minValue, maxValue, action) in [
            (L("Brightness"), -0.5, 0.5, #selector(effectChanged(_:))),
            (L("Contrast"), 0.5, 2.0, #selector(effectChanged(_:))),
            (L("Saturation"), 0.0, 2.0, #selector(effectChanged(_:))),
            (L("Sharpness"), 0.0, 2.0, #selector(effectChanged(_:))),
        ] {
            effectRows.append(makeSliderRow(title, minValue, maxValue, action))
        }
        for (index, row) in effectRows.enumerated() { row.1.tag = index }
        configureSmall(invertButton, title: L("Invert Colors"), symbol: "circle.lefthalf.filled", action: #selector(invertClicked))
        configureSmall(removeBackgroundButton, title: L("Remove Background"), symbol: "person.crop.circle.dashed", action: #selector(removeBackgroundClicked))
        inspectorDocument.addSubview(invertButton)
        if #available(macOS 14.0, *) { inspectorDocument.addSubview(removeBackgroundButton) }
    }

    private func makeSliderRow(_ title: String, _ minValue: Double, _ maxValue: Double, _ action: Selector) -> (NSTextField, NSSlider, NSTextField) {
        let name = NSTextField(labelWithString: title)
        label(name)
        let slider = NSSlider(value: minValue, minValue: minValue, maxValue: maxValue, target: self, action: action)
        slider.controlSize = .small
        slider.isContinuous = true
        inspectorDocument.addSubview(slider)
        let value = NSTextField(labelWithString: "")
        label(value, color: .labelColor)
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return (name, slider, value)
    }

    private func configurePlain(_ button: NSButton, title: String, symbol: String?, action: Selector) {
        button.title = title
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            button.imagePosition = .imageLeading
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        button.target = self
        button.action = action
        button.sizeToFit()
    }

    private func configureSmall(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = action
        button.sizeToFit()
    }

    private func setUpFooter() {
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        pinButton.configure(title: L("Pin"), symbol: "pin")
        shareButton.configure(title: L("Share"), symbol: "square.and.arrow.up")
        ocrButton.configure(title: L("OCR & QR"), symbol: "text.viewfinder")
        translateButton.configure(title: L("Translate"), symbol: "translate")
        #if !OFFLINE
        uploadButton.configure(title: L("Upload"), symbol: "icloud.and.arrow.up")
        #endif
        copyButton.configure(title: L("Copy"), symbol: "doc.on.doc")
        doneButton.configure(title: L("Done"), symbol: "checkmark", primary: true)
        translateButton.onRightClick = { [weak self] view in
            self?.overlayView?.handleToolbarButtonRightClick(.translate, anchorView: view)
        }
        #if !OFFLINE
        uploadButton.onRightClick = { [weak self] view in
            self?.overlayView?.handleToolbarButtonRightClick(.upload, anchorView: view)
        }
        #endif
        var all: [EditorFooterButton] = [pinButton, shareButton, ocrButton, translateButton, copyButton, doneButton]
        #if !OFFLINE
        all.append(uploadButton)
        #endif
        for button in all {
            button.target = self
            button.action = #selector(footerClicked(_:))
            addSubview(button)
        }
        saveButton.bezelStyle = .rounded
        saveButton.font = .systemFont(ofSize: 13)
        (saveButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        let titleItem = NSMenuItem(title: L("Save"), action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        saveButton.menu?.addItem(titleItem)
        let toFolder = NSMenuItem(title: "", action: #selector(saveToFolderClicked), keyEquivalent: "")
        toFolder.target = self
        saveButton.menu?.addItem(toFolder)
        let ask = NSMenuItem(title: L("Ask where to save"), action: #selector(saveAsClicked), keyEquivalent: "")
        ask.target = self
        saveButton.menu?.addItem(ask)
        saveButton.toolTip = L("Save")
        addSubview(saveButton)
        isDoneVisible = false
        doneButton.isHidden = true
    }

    // MARK: - Public API used by the controller / OverlayView

    func installOptions(_ view: ToolOptionsRowView) {
        optionsView?.removeFromSuperview()
        optionsView = view
        view.onInspectorResize = { [weak self] in self?.layoutInspector() }
        inspectorDocument.addSubview(view)
        layoutInspector()
    }

    func setWindowTitle(_ title: String) {
        titleLabel.stringValue = title
        needsLayout = true
    }

    func updateSizeLabel(width: Int, height: Int) {
        pixelSize = (width, height)
        updateStatus()
    }

    func updateZoom(_ magnification: CGFloat) {
        zoomButton.title = "\(Int((magnification * 100).rounded()))%"
        needsLayout = true
    }

    func showDoneButton() {
        guard !isDoneVisible else { return }
        isDoneVisible = true
        doneButton.isHidden = false
        needsLayout = true
    }

    func hideDoneButton() {
        guard isDoneVisible else { return }
        isDoneVisible = false
        doneButton.isHidden = true
        needsLayout = true
    }

    private var refreshScheduled = false
    /// Coalesced refresh; safe to request from draw/layout paths.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshFromOverlay()
        }
    }

    /// Sync every chrome control with the overlay state. Cheap: no views are rebuilt.
    func refreshFromOverlay() {
        guard let ov = overlayView else { return }
        let tool = ov.currentTool
        let info = Self.toolInfo(tool)
        headerIcon.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.name)
        headerName.stringValue = info.name
        let selected = ov.inspectorSelectedAnnotationCount
        headerSelection.stringValue = selected > 0 ? String(format: L("%d annotation(s) selected"), selected) : ""
        cropButton.isActive = tool == .crop
        undoButton.isEnabled = ov.inspectorCanUndo
        redoButton.isEnabled = ov.inspectorCanRedo

        let color = (ov.currentColor.usingColorSpace(.sRGB) ?? ov.currentColor)
        colorHex.stringValue = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
        for tile in colorSwatches {
            let preset = ColorPickerView.presetColors[tile.tag].usingColorSpace(.sRGB)
            tile.isSelected = preset.map { Self.colorsMatch($0, color) } ?? false
        }
        opacitySlider.doubleValue = Double(ov.inspectorColorOpacity)
        opacityValue.stringValue = "\(Int((ov.inspectorColorOpacity * 100).rounded()))%"

        beautifySwitch.state = ov.beautifyEnabled ? .on : .off
        beautifyMode.selectedSegment = ov.beautifyMode == .window ? 0 : 1
        let selectedStyle = ov.beautifyStyleIndex
        var slots = Array(0..<min(4, BeautifyRenderer.styles.count))
        if selectedStyle >= 4, selectedStyle < BeautifyRenderer.styles.count, !slots.isEmpty { slots[slots.count - 1] = selectedStyle }
        for (index, tile) in gradientTiles.enumerated() {
            tile.isHidden = index >= slots.count
            guard index < slots.count else { continue }
            if tile.styleIndex != slots[index] || tile.image == nil {
                tile.styleIndex = slots[index]
                tile.image = ToolOptionsRowView.gradientSwatchImage(styleIndex: slots[index], size: 44)
            }
            tile.isSelected = slots[index] == selectedStyle
        }
        gradientMoreTile.isSelected = selectedStyle == -1
        gradientMoreTile.image = selectedStyle == -1 ? ToolOptionsRowView.gradientSwatchImage(styleIndex: -1, size: 44) : nil
        let beautifyValues: [CGFloat] = [ov.beautifyPadding, ov.beautifyCornerRadius, ov.beautifyShadowRadius, ov.beautifyBackgroundBlur]
        for (index, row) in beautifyRows.enumerated() {
            row.1.doubleValue = Double(beautifyValues[index])
            row.2.stringValue = "\(Int(beautifyValues[index].rounded()))"
        }
        let beautifyAlpha: CGFloat = ov.beautifyEnabled ? 1 : 0.4
        for view in beautifyOptionViews { view.alphaValue = beautifyAlpha }
        for control in beautifyOptionViews.compactMap({ $0 as? NSControl }) { control.isEnabled = ov.beautifyEnabled }
        for tile in gradientTiles + [gradientMoreTile] { tile.isEnabled = ov.beautifyEnabled }

        let config = ov.effectsConfig
        for (index, tile) in presetTiles.enumerated() { tile.isSelected = ImageEffectPreset.allCases[index] == config.preset }
        let effectValues = [config.brightness, config.contrast, config.saturation, config.sharpness]
        for (index, row) in effectRows.enumerated() {
            row.1.doubleValue = Double(effectValues[index])
            row.2.stringValue = index == 0 ? String(format: "%.2f", effectValues[index]) : String(format: "%.1f", effectValues[index])
        }
        effectsReset.isEnabled = ov.effectsActive

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        pinButton.isHidden = !ToolbarActionPreferences.isEnabled(.pin, in: enabledActions)
        shareButton.isHidden = !ToolbarActionPreferences.isEnabled(.share, in: enabledActions)
        ocrButton.isHidden = !ToolbarActionPreferences.isEnabled(.ocr, in: enabledActions)
        translateButton.isHidden = !ToolbarActionPreferences.isEnabled(.translate, in: enabledActions)
        #if !OFFLINE
        uploadButton.isHidden = !ToolbarActionPreferences.isEnabled(.upload, in: enabledActions)
        #endif
        invertButton.isHidden = !ToolbarActionPreferences.isEnabled(.invertColors, in: enabledActions)
        removeBackgroundButton.isHidden = !ToolbarActionPreferences.isEnabled(.removeBackground, in: enabledActions)
        translateButton.isOn = ov.translateEnabled
        let folder = URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent
        saveButton.item(at: 1)?.title = "\(L("Save to")) \(folder)"
        updateStatus()
        layoutInspector()
        needsLayout = true
    }

    private var beautifyOptionViews: [NSView] {
        [beautifyMode] + beautifyRows.flatMap { [$0.0, $0.1, $0.2] as [NSView] }
    }

    private func updateStatus() {
        let count = overlayView?.annotations.filter { $0.isMovable }.count ?? 0
        statusLabel.stringValue = String(format: L("%d × %d · %d annotations · ⌘Z Undo"), pixelSize.0, pixelSize.1, count)
    }

    private static func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    static func toolInfo(_ tool: AnnotationTool) -> (symbol: String, name: String) {
        let table: [AnnotationTool: (String, String)] = [
            .pencil: ("pencil", "Pencil (Draw)"), .line: ("line.diagonal", "Line"), .arrow: ("arrow.up.right", "Arrow"),
            .rectangle: ("square", "Rectangle"), .ellipse: ("circle", "Ellipse"), .marker: ("highlighter", "Marker"),
            .text: ("textformat", "Text"), .number: ("list.number", "Number"),
            .pixelate: ("square.grid.2x2", "Censor (Pixelate / Blur / Solid)"), .blur: ("square.grid.2x2", "Censor (Pixelate / Blur / Solid)"),
            .highlight: ("sun.max", "Highlight (Spotlight)"), .loupe: ("plus.magnifyingglass", "Magnify (Loupe)"),
            .stamp: ("face.smiling", "Stamp / Emoji"), .colorSampler: ("eyedropper", "Color Picker"),
            .measure: ("ruler", "Measure (px)"), .crop: ("crop", "Crop"), .select: ("cursorarrow", "Select"),
        ]
        let entry = table[tool] ?? ("cursorarrow", "Select")
        var name = L(entry.1)
        for open in [" (", "（", "("] {
            if let range = name.range(of: open) { name = String(name[..<range.lowerBound]) }
        }
        return (entry.0, name.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let top = Self.toolbarHeight, foot = Self.footerHeight, insp = Self.inspectorWidth
        let midY = top / 2

        // Title-bar row
        var x: CGFloat = 84
        if let zoom = window?.standardWindowButton(.zoomButton), let frameView = zoom.superview {
            x = max(x, convert(zoom.convert(zoom.bounds, to: nil), from: nil).maxX + 12)
            _ = frameView
        }
        let right = w - 12
        zoomButton.sizeToFit()
        zoomButton.frame = fl(NSRect(x: right - zoomButton.frame.width, y: midY - 13, width: zoomButton.frame.width, height: 26))
        undoSeparatorX = zoomButton.frame.minX - 6.5
        redoButton.frame = fl(NSRect(x: undoSeparatorX - 6 - 30, y: midY - 15, width: 30, height: 30))
        undoButton.frame = fl(NSRect(x: redoButton.frame.minX - 2 - 30, y: midY - 15, width: 30, height: 30))
        let stripWidth = toolStrip?.frame.width ?? 0
        let actionsWidth: CGFloat = 13 + 4 * 30 + 3 * 2
        titleLabel.sizeToFit()
        let titleAvailable = undoButton.frame.minX - 12 - x - stripWidth - actionsWidth - 14
        titleLabel.isHidden = titleAvailable < 80
        if !titleLabel.isHidden {
            let titleW = min(titleLabel.frame.width, titleAvailable)
            titleLabel.frame = fl(NSRect(x: x, y: midY - titleLabel.frame.height / 2, width: titleW, height: titleLabel.frame.height))
            x += titleW + 14
        }
        if let strip = toolStrip {
            strip.frame = fl(NSRect(x: x - 4, y: midY - strip.frame.height / 2, width: strip.frame.width, height: strip.frame.height))
            x = strip.frame.maxX - 4
        }
        toolSeparatorX = x + 6
        x += 13
        for button in [cropButton, flipHButton, flipVButton, addCaptureButton] {
            button.frame = fl(NSRect(x: x, y: midY - 15, width: 30, height: 30))
            x += 32
        }

        // Body
        let bodyH = max(0, h - top - foot)
        for case let scroll as NSScrollView in subviews where scroll !== inspectorScroll {
            scroll.frame = fl(NSRect(x: 0, y: top, width: max(0, w - insp), height: bodyH))
        }
        inspectorScroll.frame = fl(NSRect(x: w - insp + 0.5, y: top, width: insp - 0.5, height: bodyH))
        layoutInspector()

        // Footer
        let footY = h - foot
        statusLabel.sizeToFit()
        var fx = w - 14
        func placeRight(_ view: NSView, width: CGFloat? = nil) {
            guard !view.isHidden else { return }
            let bw = width ?? view.frame.width
            fx -= bw
            view.frame = fl(NSRect(x: fx, y: footY + (foot - 28) / 2, width: bw, height: 28))
            fx -= 8
        }
        placeRight(doneButton)
        saveButton.sizeToFit()
        placeRight(saveButton, width: saveButton.frame.width)
        placeRight(copyButton)
        footerSeparatorX = fx - 1
        fx -= 4
        #if !OFFLINE
        placeRight(uploadButton)
        #endif
        placeRight(translateButton)
        placeRight(ocrButton)
        placeRight(shareButton)
        placeRight(pinButton)
        statusLabel.frame = fl(NSRect(x: 14, y: footY + (foot - statusLabel.frame.height) / 2,
                                   width: max(0, fx - 14 - 8), height: statusLabel.frame.height))
        needsDisplay = true
    }

    private func layoutInspector() {
        let width = Self.inspectorWidth
        let inset: CGFloat = 16
        let contentW = width - inset * 2
        var y: CGFloat = 14
        // Header
        headerIconBox.frame = NSRect(x: inset, y: y, width: 24, height: 24)
        headerIcon.frame = headerIconBox.frame.insetBy(dx: 4, dy: 4)
        headerSelection.sizeToFit()
        headerSelection.frame.origin = NSPoint(x: width - inset - headerSelection.frame.width, y: y + (24 - headerSelection.frame.height) / 2)
        headerName.sizeToFit()
        headerName.frame = NSRect(x: inset + 32, y: y + (24 - headerName.frame.height) / 2,
                                  width: min(headerName.frame.width, headerSelection.frame.minX - inset - 40), height: headerName.frame.height)
        y += 24 + 14

        // Color
        let tool = overlayView?.currentTool ?? .rectangle
        let showsColor: Bool = {
            switch tool {
            case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .text, .number, .measure: return true
            default: return (overlayView?.inspectorSelectedAnnotationCount ?? 0) > 0 && tool == .select
            }
        }()
        let colorViews: [NSView] = [colorTitle, colorHex, opacityLabel, opacitySlider, opacityValue, moreColorsButton] + colorSwatches
        for view in colorViews { view.isHidden = !showsColor }
        if showsColor {
            colorTitle.sizeToFit(); colorHex.sizeToFit()
            colorTitle.frame.origin = NSPoint(x: inset, y: y)
            colorHex.frame.origin = NSPoint(x: width - inset - colorHex.frame.width, y: y)
            y += colorTitle.frame.height + 8
            let cell = contentW / 6
            for (index, tile) in colorSwatches.enumerated() {
                let col = CGFloat(index % 6), row = CGFloat(index / 6)
                tile.frame = NSRect(x: inset + col * cell + (cell - 26) / 2, y: y + row * 29 - 2, width: 26, height: 26)
            }
            y += 22 * 2 + 7 + 12
            layoutSliderRow(opacityLabel, opacitySlider, opacityValue, y: y, inset: inset, width: width)
            y += 24 + 6
            moreColorsButton.frame.origin = NSPoint(x: inset - 2, y: y)
            y += moreColorsButton.frame.height + 14
        }

        toolHint.isHidden = tool != .colorSampler
        if !toolHint.isHidden {
            toolHint.preferredMaxLayoutWidth = contentW
            let size = toolHint.sizeThatFits(NSSize(width: contentW, height: 200))
            toolHint.frame = NSRect(x: inset, y: y, width: contentW, height: size.height)
            y += size.height + 14
        }

        // Tool options
        if let options = optionsView, !options.isHidden, !options.subviews.isEmpty {
            options.frame.origin = NSPoint(x: 0, y: y)
            y += options.frame.height + 14
        }

        // Beautify
        divider1.frame = NSRect(x: inset, y: y, width: contentW, height: 0.5)
        y += 0.5 + 14
        beautifyTitle.sizeToFit()
        beautifySwitch.sizeToFit()
        beautifyTitle.frame.origin = NSPoint(x: inset, y: y + (20 - beautifyTitle.frame.height) / 2)
        beautifySwitch.frame.origin = NSPoint(x: width - inset - beautifySwitch.frame.width, y: y + (20 - beautifySwitch.frame.height) / 2)
        y += 20 + 12
        let isSnap = overlayView?.selectionIsWindowSnap == true
        beautifyMode.isHidden = isSnap
        if !isSnap {
            beautifyMode.frame = NSRect(x: inset, y: y, width: contentW, height: 26)
            beautifyMode.setWidth(contentW / 2 - 2, forSegment: 0)
            beautifyMode.setWidth(contentW / 2 - 2, forSegment: 1)
            y += 26 + 12
        }
        let visibleTiles = gradientTiles.filter { !$0.isHidden } + [gradientMoreTile]
        let tileW = (contentW - CGFloat(visibleTiles.count - 1) * 6) / CGFloat(visibleTiles.count)
        for (index, tile) in visibleTiles.enumerated() {
            tile.frame = NSRect(x: inset + CGFloat(index) * (tileW + 6), y: y, width: tileW, height: 26)
        }
        y += 26 + 12
        let showsBlur = overlayView?.beautifyStyleIndex == -1
        for (index, row) in beautifyRows.enumerated() {
            let hidden = (index == 1 && isSnap) || (index == 3 && !showsBlur)
            for view in [row.0, row.1, row.2] as [NSView] { view.isHidden = hidden }
            guard !hidden else { continue }
            layoutSliderRow(row.0, row.1, row.2, y: y, inset: inset, width: width)
            y += 24 + 6
        }
        y += 8

        // Image effects
        divider2.frame = NSRect(x: inset, y: y, width: contentW, height: 0.5)
        y += 0.5 + 14
        effectsTitle.sizeToFit()
        effectsTitle.frame.origin = NSPoint(x: inset, y: y + (20 - effectsTitle.frame.height) / 2)
        effectsReset.sizeToFit()
        effectsReset.frame.origin = NSPoint(x: width - inset - effectsReset.frame.width + 4, y: y + (20 - effectsReset.frame.height) / 2)
        y += 20 + 10
        let presetW = (contentW - 3 * 6) / 4
        for (index, tile) in presetTiles.enumerated() {
            let col = CGFloat(index % 4), row = CGFloat(index / 4)
            tile.frame = NSRect(x: inset + col * (presetW + 6), y: y + row * 52, width: presetW, height: 46)
        }
        y += 52 * 2 + 4
        for row in effectRows {
            layoutSliderRow(row.0, row.1, row.2, y: y, inset: inset, width: width)
            y += 24 + 6
        }
        y += 4
        invertButton.frame.origin = NSPoint(x: inset, y: y)
        removeBackgroundButton.frame.origin = NSPoint(x: invertButton.isHidden ? inset : invertButton.frame.maxX + 8, y: y)
        y += max(invertButton.frame.height, 24) + 18

        inspectorDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(y, inspectorScroll.contentSize.height))
        inspectorDocument.needsDisplay = true
    }

    private func layoutSliderRow(_ name: NSTextField, _ slider: NSSlider, _ value: NSTextField, y: CGFloat, inset: CGFloat, width: CGFloat) {
        name.sizeToFit()
        name.frame = NSRect(x: inset, y: y + (24 - name.frame.height) / 2, width: 56, height: name.frame.height)
        value.frame = NSRect(x: width - inset - 38, y: y + 4, width: 38, height: 16)
        slider.frame = NSRect(x: inset + 62, y: y + 2, width: width - inset * 2 - 62 - 46, height: 20)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let top = Self.toolbarHeight, foot = Self.footerHeight, insp = Self.inspectorWidth
        Self.toolBackground.setFill()
        fl(NSRect(x: 0, y: 0, width: w, height: top)).fill()
        fl(NSRect(x: 0, y: h - foot, width: w, height: foot)).fill()
        Self.inspectorBackground.setFill()
        fl(NSRect(x: w - insp, y: top, width: insp, height: h - top - foot)).fill()
        Self.line.setFill()
        fl(NSRect(x: 0, y: top - 0.5, width: w, height: 0.5)).fill()
        fl(NSRect(x: 0, y: h - foot, width: w, height: 0.5)).fill()
        fl(NSRect(x: w - insp, y: top, width: 0.5, height: h - top - foot)).fill()
        for sepX in [toolSeparatorX, undoSeparatorX] where sepX > 0 {
            fl(NSRect(x: sepX, y: top / 2 - 10, width: 0.5, height: 20)).fill()
        }
        if footerSeparatorX > 0 {
            fl(NSRect(x: footerSeparatorX, y: h - foot / 2 - 10, width: 0.5, height: 20)).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        inspectorDocument.needsDisplay = true
    }

    // MARK: - Title-bar actions

    @objc private func cropClicked() {
        guard let ov = overlayView else { return }
        ov.currentTool = ov.currentTool == .crop ? .arrow : .crop
        ov.rebuildToolbarLayout()
        ov.needsDisplay = true
    }
    @objc private func flipHClicked() { overlayView?.flipImageHorizontally() }
    @objc private func flipVClicked() { overlayView?.flipImageVertically() }
    @objc private func addCaptureClicked() { overlayView?.overlayDelegate?.overlayViewDidRequestAddCapture() }
    @objc private func undoClicked() { overlayView?.handleToolbarAction(.undo) }
    @objc private func redoClicked() { overlayView?.handleToolbarAction(.redo) }

    @objc private func zoomButtonClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let zoomIn = NSMenuItem(title: L("Zoom In"), action: #selector(zoomInAction), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = .command
        let zoomOut = NSMenuItem(title: L("Zoom Out"), action: #selector(zoomOutAction), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = .command
        let fit = NSMenuItem(title: L("Fit Canvas"), action: #selector(fitCanvasAction), keyEquivalent: "1")
        fit.keyEquivalentModifierMask = .command
        for item in [zoomIn, zoomOut] { item.target = self; menu.addItem(item) }
        menu.addItem(.separator())
        fit.target = self
        menu.addItem(fit)
        menu.addItem(.separator())
        let currentMag = overlayView?.enclosingScrollView?.magnification ?? 1.0
        for (title, mag, key) in [("50%", 0.5, ""), ("100%", 1.0, "0"), ("200%", 2.0, "")] as [(String, CGFloat, String)] {
            let item = NSMenuItem(title: title, action: #selector(zoomPresetAction(_:)), keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = .command }
            item.target = self
            item.tag = Int(mag * 100)
            if abs(currentMag - mag) < 0.01 { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: zoomButton.bounds.height + 4), in: zoomButton)
    }

    @objc private func zoomInAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let newMag = min(sv.maxMagnification, sv.magnification * 1.25)
        sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
        updateZoom(newMag)
    }

    @objc private func zoomOutAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let newMag = max(sv.minMagnification, sv.magnification / 1.25)
        sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
        updateZoom(newMag)
    }

    @objc private func fitCanvasAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let docW = doc.frame.width / sv.magnification, docH = doc.frame.height / sv.magnification
        guard docW > 0, docH > 0 else { return }
        let clip = sv.contentView.bounds.size
        let clamped = max(sv.minMagnification, min(sv.maxMagnification, min(clip.width / docW, clip.height / docH)))
        sv.magnification = clamped
        updateZoom(clamped)
    }

    @objc private func zoomPresetAction(_ sender: NSMenuItem) {
        guard let sv = overlayView?.enclosingScrollView else { return }
        let mag = CGFloat(sender.tag) / 100.0
        sv.magnification = mag
        updateZoom(mag)
    }

    // MARK: - Inspector actions

    @objc private func opacityChanged() {
        overlayView?.applyInspectorOpacity(CGFloat(opacitySlider.doubleValue))
        opacityValue.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
    }

    @objc private func moreColorsClicked() {
        if PopoverHelper.toggleClosedIfOpen() { return }
        overlayView?.showColorPickerPopover(target: .drawColor, anchorView: moreColorsButton)
    }

    @objc private func beautifyToggled() {
        guard let ov = overlayView else { return }
        ov.beautifyEnabled = beautifySwitch.state == .on
        UserDefaults.standard.set(ov.beautifyEnabled, forKey: "beautifyEnabled")
        if ov.beautifyEnabled { ov.ensureCustomBeautifyBackgroundLoaded() }
        ov.needsDisplay = true
        ov.onContentChanged?()
        ov.rebuildToolbarLayout()
    }

    @objc private func beautifyModeChanged() {
        guard let ov = overlayView else { return }
        ov.beautifyMode = beautifyMode.selectedSegment == 0 ? .window : .rounded
        UserDefaults.standard.set(ov.beautifyMode.rawValue, forKey: "beautifyMode")
        ov.needsDisplay = true
        ov.onContentChanged?()
    }

    @objc private func beautifyPaddingChanged(_ sender: NSSlider) {
        overlayView?.beautifyPadding = CGFloat(sender.floatValue)
        beautifySliderChanged(sender, key: "beautifyPadding")
    }
    @objc private func beautifyRadiusChanged(_ sender: NSSlider) {
        overlayView?.beautifyCornerRadius = CGFloat(sender.floatValue)
        beautifySliderChanged(sender, key: "beautifyCornerRadius")
    }
    @objc private func beautifyShadowChanged(_ sender: NSSlider) {
        overlayView?.beautifyShadowRadius = CGFloat(sender.floatValue)
        beautifySliderChanged(sender, key: "beautifyShadowRadius")
    }
    @objc private func beautifyBlurChanged(_ sender: NSSlider) {
        overlayView?.beautifyBackgroundBlur = CGFloat(sender.floatValue)
        overlayView?.cachedCompositedImage = nil
        beautifySliderChanged(sender, key: "beautifyBgBlur")
    }
    private func beautifySliderChanged(_ sender: NSSlider, key: String) {
        UserDefaults.standard.set(sender.doubleValue, forKey: key)
        beautifyRows.first { $0.1 === sender }?.2.stringValue = "\(Int(sender.doubleValue.rounded()))"
        overlayView?.needsDisplay = true
        overlayView?.onContentChanged?()
    }

    private func selectPreset(_ preset: ImageEffectPreset) {
        guard let ov = overlayView else { return }
        var config = ov.effectsConfig
        config.preset = preset
        if preset == .vivid || preset == .none {
            config.brightness = 0; config.contrast = 1; config.saturation = 1; config.sharpness = 0
        }
        ov.applyEffectsConfig(config)
    }

    @objc private func effectChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        var config = ov.effectsConfig
        let value = Float(sender.doubleValue)
        switch sender.tag {
        case 0: config.brightness = value
        case 1: config.contrast = value
        case 2: config.saturation = value
        default: config.sharpness = value
        }
        config.preset = .none
        ov.applyEffectsConfig(config)
    }

    @objc private func effectsResetClicked() { overlayView?.applyEffectsConfig(ImageEffectsConfig()) }
    @objc private func invertClicked() { overlayView?.handleToolbarAction(.invertColors) }
    @objc private func removeBackgroundClicked() { overlayView?.handleToolbarAction(.removeBackground) }

    // MARK: - Footer actions

    @objc private func footerClicked(_ sender: EditorFooterButton) {
        guard let ov = overlayView else { return }
        switch sender {
        case pinButton: ov.handleToolbarAction(.pin)
        case shareButton: ov.overlayDelegate?.overlayViewDidRequestShare(anchorView: shareButton)
        case ocrButton: ov.handleToolbarAction(.ocr)
        case translateButton: ov.handleToolbarAction(.translate)
        case copyButton: ov.handleToolbarAction(.copy)
        case doneButton: onDone?()
        default:
            #if !OFFLINE
            if sender === uploadButton { ov.handleToolbarAction(.upload) }
            #endif
        }
    }

    @objc private func saveToFolderClicked() { overlayView?.overlayDelegate?.overlayViewDidRequestFileSave() }
    @objc private func saveAsClicked() { overlayView?.overlayDelegate?.overlayViewDidRequestSaveAs() }

    override func resetCursorRects() {
        addCursorRect(fl(NSRect(x: 0, y: 0, width: bounds.width, height: Self.toolbarHeight)), cursor: .arrow)
        addCursorRect(fl(NSRect(x: bounds.width - Self.inspectorWidth, y: Self.toolbarHeight,
                                width: Self.inspectorWidth, height: bounds.height - Self.toolbarHeight)), cursor: .arrow)
        addCursorRect(fl(NSRect(x: 0, y: bounds.height - Self.footerHeight, width: bounds.width, height: Self.footerHeight)), cursor: .arrow)
    }
}

// MARK: - Small chrome controls

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if bounds.height <= 1 {
            EditorChromeView.line.setFill()
            bounds.fill()
        }
    }
}

/// 30pt title-bar icon button (mac-annotation.html `.tool`).
final class EditorIconButton: NSButton {
    var isActive = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    convenience init(symbol: String, tip: String) {
        self.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        title = ""
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        imagePosition = .imageOnly
        toolTip = tip
        setAccessibilityLabel(tip)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if isActive {
            EditorChromeView.selection.setFill(); path.fill()
        } else if hovering && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.05).setFill(); path.fill()
        }
        guard let image else { return }
        let tint: NSColor = isActive ? .controlAccentColor : .secondaryLabelColor
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        let rect = NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35)
    }
}

/// "100% ⌄" zoom popup (mac-annotation.html `.zoom`).
final class EditorZoomButton: NSButton {
    convenience init() {
        self.init(frame: .zero)
        isBordered = false
        title = "100%"
        toolTip = L("Zoom")
    }
    override var title: String { didSet { invalidateIntrinsicContentSize() } }
    override func sizeToFit() {
        let text = (title as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        frame.size = NSSize(width: ceil(text.width) + 9 + 4 + 10 + 9, height: 26)
    }
    override func draw(_ dirtyRect: NSRect) {
        EditorChromeView.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 9, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                chevron.draw(in: rect); NSColor.secondaryLabelColor.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: bounds.width - 9 - chevron.size.width, y: (bounds.height - chevron.size.height) / 2,
                                   width: chevron.size.width, height: chevron.size.height))
        }
    }
}

/// Footer push button with icon + label (mac.css `.btn`, `.btn.primary`).
final class EditorFooterButton: NSButton {
    var onRightClick: ((NSView) -> Void)?
    var isOn = false { didSet { contentTintColor = isOn ? .controlAccentColor : nil; updateTitleColor() } }
    private var primary = false

    func configure(title: String, symbol: String, primary: Bool = false) {
        self.primary = primary
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        font = .systemFont(ofSize: 13, weight: primary ? .semibold : .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: primary ? .semibold : .regular))
        imagePosition = .imageLeading
        imageHugsTitle = true
        if primary {
            // Drawn by hand so the brand fill stays in inactive / dark windows (mac.css .btn.primary).
            isBordered = false
            contentTintColor = .white
        }
        updateTitleColor()
        sizeToFit()
        frame.size.width += 10
    }

    private func updateTitleColor() {
        let color: NSColor = primary ? .white : (isOn ? .controlAccentColor : .labelColor)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color])
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(self) } else { super.rightMouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard primary else { super.draw(dirtyRect); return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.8 : 1).setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let iconSize = image?.size ?? .zero
        let total = iconSize.width + (iconSize.width > 0 ? 6 : 0) + textSize.width
        var x = (bounds.width - total) / 2
        if let image {
            let tinted = NSImage(size: iconSize, flipped: false) { rect in
                image.draw(in: rect); NSColor.white.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSize.width + 6
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: attrs)
    }
}

/// Clickable swatch / gradient / preset tile drawn with dynamic colors.
final class TileView: NSView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var symbol: String? { didSet { needsDisplay = true } }
    var caption: String? { didSet { needsDisplay = true } }
    var isCircle = false
    var cornerRadius: CGFloat = 6
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    var isEnabled = true
    var styleIndex = 0
    var onClick: (() -> Void)?
    private var storedTag = 0
    override var tag: Int { get { storedTag } set { storedTag = newValue } }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let captionH: CGFloat = caption == nil ? 0 : 15
        var body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - captionH)
        if isCircle { body = NSRect(x: (bounds.width - 22) / 2, y: (bounds.height - 22) / 2, width: 22, height: 22) }
        else if isSelected { body = body.insetBy(dx: 2, dy: 2) }
        let radius = isCircle ? body.width / 2 : cornerRadius
        if isSelected {
            let ringRect = isCircle ? body.insetBy(dx: -4, dy: -4) : body.insetBy(dx: -2, dy: -2)
            let ring = NSBezierPath(roundedRect: ringRect, xRadius: isCircle ? ringRect.width / 2 : radius + 2, yRadius: isCircle ? ringRect.height / 2 : radius + 2)
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let fillColor { fillColor.setFill(); body.fill() }
        if let image {
            // Aspect-fill.
            let scale = max(body.width / max(1, image.size.width), body.height / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect); NSColor.secondaryLabelColor.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: body.midX - icon.size.width / 2, y: body.midY - icon.size.height / 2,
                                   width: icon.size.width, height: icon.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        if isCircle || symbol != nil {
            let border = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            border.lineWidth = 1
            (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.12)).setStroke()
            border.stroke()
        }
        if let caption {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (caption as NSString).size(withAttributes: attrs)
            (caption as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - captionH + 2), withAttributes: attrs)
        }
    }
}
