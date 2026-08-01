import AppKit

protocol CaptureSelectionToolbarDelegate: AnyObject {
    func captureToolbarDidSelectSelectionTool()
    func captureToolbarDidSelectAnnotationTool(_ tool: ScreenshotAnnotationTool)
    func captureToolbarDidConfirm()
    func captureToolbarDidCancel()
    func captureToolbarDidPin()
    func captureToolbarDidOCR()
    func captureToolbarDidUndo()
    func captureToolbarDidRedo()
    func captureToolbarDidOptionsChange()
}

extension CaptureSelectionToolbarDelegate {
    func captureToolbarDidOptionsChange() {}
}

final class CaptureSelectionToolbarPanel: NSPanel {
    weak var toolbarDelegate: CaptureSelectionToolbarDelegate?

    private weak var annotationModel: AnnotationCanvasModel?
    private weak var canvasView: AnnotationCanvasView?

    private var rootStack: NSStackView?
    private var secondaryContainer: NSView?
    private var selectionButton: NSButton?
    private var annotationButtons: [NSButton] = []
    private var lineWidthLabel: NSTextField?
    private var fontSizeLabel: NSTextField?
    private var secondaryButtons: [NSButton] = []

    private var showsSecondary: Bool {
        guard let tool = annotationModel?.selectedTool else { return false }
        return tool == .arrow || tool == .text || tool == .mosaic
    }

    var currentHeight: CGFloat {
        showsSecondary
            ? ScreenshotChrome.barHeight + ScreenshotChrome.secondaryBarHeight
            : ScreenshotChrome.barHeight
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: ScreenshotChrome.barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        contentView = buildToolbar()
    }

    func bind(model: AnnotationCanvasModel, canvasView: AnnotationCanvasView?) {
        annotationModel = model
        self.canvasView = canvasView
        updateLineWidthLabel()
        syncSelectedTool(model.selectedTool)
        refreshSecondaryToolbar()
    }

    func setSelectionToolActive(_ active: Bool) {
        selectionButton?.state = active ? .on : .off
        (selectionButton as? ToolbarToggleButton)?.updateSelectedAppearance()
        if active {
            for button in annotationButtons {
                button.state = .off
                (button as? ToolbarToggleButton)?.updateSelectedAppearance()
            }
        }
        refreshSecondaryToolbar()
    }

    func setAnnotationToolActive(_ tool: ScreenshotAnnotationTool) {
        selectionButton?.state = .off
        (selectionButton as? ToolbarToggleButton)?.updateSelectedAppearance()
        for button in annotationButtons {
            let isActive = toolFromTag(button.tag) == tool
            button.state = isActive ? .on : .off
            (button as? ToolbarToggleButton)?.updateSelectedAppearance()
        }
        refreshSecondaryToolbar()
    }

    func syncSelectedTool(_ tool: ScreenshotAnnotationTool) {
        if tool == .selection {
            setSelectionToolActive(true)
        } else {
            setAnnotationToolActive(tool)
        }
    }

    func updateLineWidthLabel() {
        guard let model = annotationModel else { return }
        lineWidthLabel?.stringValue = "\(Int(model.lineWidth))"
        fontSizeLabel?.stringValue = "\(Int(model.fontSize))"
    }

    private func buildToolbar() -> NSView {
        let bar = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        bar.material = .underWindowBackground
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(root)
        rootStack = root

        let primary = buildPrimaryRow()
        root.addArrangedSubview(primary)

        let secondary = NSView()
        secondary.translatesAutoresizingMaskIntoConstraints = false
        secondary.heightAnchor.constraint(equalToConstant: ScreenshotChrome.secondaryBarHeight).isActive = true
        secondary.isHidden = true
        secondaryContainer = secondary
        root.addArrangedSubview(secondary)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            root.topAnchor.constraint(equalTo: bar.topAnchor),
            root.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            primary.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            primary.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            primary.heightAnchor.constraint(equalToConstant: ScreenshotChrome.barHeight),
            secondary.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        return bar
    }

    private func buildPrimaryRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)

        let selection = makeToggleButton(
            imageName: "arrow.up.left.and.arrow.down.right",
            action: #selector(selectionToolAction),
            tooltip: L10n.t(.screenshotToolSelection)
        )
        selection.state = .on
        selection.updateSelectedAppearance()
        selectionButton = selection
        stack.addArrangedSubview(selection)

        stack.addArrangedSubview(makeDivider())

        for tool in ScreenshotAnnotationTool.annotationTools {
            let button = makeToggleButton(
                imageName: tool.systemImage,
                action: #selector(annotationToolAction(_:)),
                tooltip: toolLabel(tool)
            )
            button.tag = toolTag(tool)
            annotationButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(makeDivider())

        for color in ScreenshotChrome.presetColors {
            let swatch = ToolbarColorSwatchView(color: color)
            swatch.target = self
            swatch.action = #selector(selectColorSwatch(_:))
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(swatch)
        }

        stack.addArrangedSubview(makeDivider())

        stack.addArrangedSubview(makeActionButton(imageName: "minus", action: #selector(decreaseLineWidth), tooltip: L10n.t(.screenshotLineWidth)))
        let widthLabel = NSTextField(labelWithString: "3")
        widthLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        widthLabel.textColor = .secondaryLabelColor
        widthLabel.alignment = .center
        widthLabel.translatesAutoresizingMaskIntoConstraints = false
        widthLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true
        widthLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        lineWidthLabel = widthLabel
        stack.addArrangedSubview(widthLabel)
        stack.addArrangedSubview(makeActionButton(imageName: "plus", action: #selector(increaseLineWidth), tooltip: L10n.t(.screenshotLineWidth)))

        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(makeActionButton(imageName: "arrow.uturn.backward", action: #selector(undoAction), tooltip: L10n.t(.screenshotUndo)))
        stack.addArrangedSubview(makeActionButton(imageName: "arrow.uturn.forward", action: #selector(redoAction), tooltip: L10n.t(.screenshotRedo)))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let done = NSButton(title: L10n.t(.screenshotDone), target: self, action: #selector(confirmAction))
        done.bezelStyle = .push
        done.controlSize = .small
        done.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        done.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(done)

        stack.addArrangedSubview(makeActionButton(imageName: "pin.fill", action: #selector(pinAction), tooltip: L10n.t(.screenshotPin)))
        stack.addArrangedSubview(makeActionButton(imageName: "text.viewfinder", action: #selector(ocrAction), tooltip: L10n.t(.screenshotOCR)))
        stack.addArrangedSubview(makeActionButton(imageName: "xmark", action: #selector(cancelAction), tooltip: L10n.t(.close)))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: AppSpacing.sm),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -AppSpacing.sm),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func refreshSecondaryToolbar() {
        guard let secondaryContainer else { return }
        secondaryContainer.subviews.forEach { $0.removeFromSuperview() }
        secondaryButtons.removeAll()
        fontSizeLabel = nil

        let visible = showsSecondary
        secondaryContainer.isHidden = !visible

        if visible, let model = annotationModel {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            secondaryContainer.addSubview(stack)

            switch model.selectedTool {
            case .arrow:
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotArrowSolid),
                    selected: !model.arrowDashed,
                    action: #selector(selectSolidArrow)
                ))
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotArrowDashed),
                    selected: model.arrowDashed,
                    action: #selector(selectDashedArrow)
                ))
            case .text:
                stack.addArrangedSubview(makeActionButton(imageName: "minus", action: #selector(decreaseFontSize), tooltip: L10n.t(.screenshotFontSize)))
                let sizeLabel = NSTextField(labelWithString: "\(Int(model.fontSize))")
                sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                sizeLabel.textColor = .secondaryLabelColor
                sizeLabel.alignment = .center
                sizeLabel.translatesAutoresizingMaskIntoConstraints = false
                sizeLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
                fontSizeLabel = sizeLabel
                stack.addArrangedSubview(sizeLabel)
                stack.addArrangedSubview(makeActionButton(imageName: "plus", action: #selector(increaseFontSize), tooltip: L10n.t(.screenshotFontSize)))
                stack.addArrangedSubview(makeDivider())
                stack.addArrangedSubview(makeSecondaryToggle(title: "B", selected: model.textBold, action: #selector(toggleBold), boldLabel: true))
                stack.addArrangedSubview(makeSecondaryToggle(title: "I", selected: model.textItalic, action: #selector(toggleItalic), italicLabel: true))
                stack.addArrangedSubview(makeSecondaryToggle(title: "U", selected: model.textUnderline, action: #selector(toggleUnderline), underlineLabel: true))
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotTextBackground),
                    selected: model.textBackgroundEnabled,
                    action: #selector(toggleTextBackground)
                ))
            case .mosaic:
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotMosaicRect),
                    selected: model.mosaicMode == .rect,
                    action: #selector(selectMosaicRect)
                ))
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotMosaicBrushSmall),
                    selected: model.mosaicMode == .brush && model.mosaicBrushSize == .small,
                    action: #selector(selectMosaicBrushSmall)
                ))
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotMosaicBrushMedium),
                    selected: model.mosaicMode == .brush && model.mosaicBrushSize == .medium,
                    action: #selector(selectMosaicBrushMedium)
                ))
                stack.addArrangedSubview(makeSecondaryToggle(
                    title: L10n.t(.screenshotMosaicBrushLarge),
                    selected: model.mosaicMode == .brush && model.mosaicBrushSize == .large,
                    action: #selector(selectMosaicBrushLarge)
                ))
            default:
                break
            }

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: secondaryContainer.leadingAnchor, constant: AppSpacing.sm),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: secondaryContainer.trailingAnchor, constant: -AppSpacing.sm),
                stack.centerYAnchor.constraint(equalTo: secondaryContainer.centerYAnchor)
            ])
        }

        let height = currentHeight
        var frame = self.frame
        let delta = height - frame.height
        if abs(delta) > 0.5 {
            if frame.origin.y > 100 {
                // Prefer growing upward when toolbar sits below selection.
                frame.origin.y -= max(0, delta)
            }
            frame.size.height = height
            setFrame(frame, display: true)
        }
        toolbarDelegate?.captureToolbarDidOptionsChange()
    }

    private func makeSecondaryToggle(
        title: String,
        selected: Bool,
        action: Selector,
        boldLabel: Bool = false,
        italicLabel: Bool = false,
        underlineLabel: Bool = false
    ) -> NSButton {
        let button = ToolbarToggleButton(title: title, target: self, action: action)
        button.setButtonType(.toggle)
        button.state = selected ? .on : .off
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        var font = NSFont.systemFont(ofSize: 11, weight: boldLabel ? .bold : .medium)
        if italicLabel {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        button.font = font
        if underlineLabel {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.labelColor
            ]
            button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        button.contentTintColor = .labelColor
        button.updateSelectedAppearance()
        secondaryButtons.append(button)
        return button
    }

    private func makeToggleButton(imageName: String, action: Selector, tooltip: String) -> ToolbarToggleButton {
        let symbol = NSImage(systemSymbolName: imageName, accessibilityDescription: tooltip) ?? NSImage()
        symbol.isTemplate = true
        let button = ToolbarToggleButton(image: symbol, target: self, action: action)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = tooltip
        button.setButtonType(.toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeActionButton(imageName: String, action: Selector, tooltip: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: imageName, accessibilityDescription: tooltip) ?? NSImage(),
            target: self,
            action: action
        )
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = tooltip
        button.setButtonType(.momentaryChange)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return divider
    }

    @objc private func selectionToolAction() {
        setSelectionToolActive(true)
        toolbarDelegate?.captureToolbarDidSelectSelectionTool()
    }

    @objc private func annotationToolAction(_ sender: NSButton) {
        guard let tool = toolFromTag(sender.tag) else { return }
        setAnnotationToolActive(tool)
        toolbarDelegate?.captureToolbarDidSelectAnnotationTool(tool)
    }

    @objc private func selectColorSwatch(_ sender: ToolbarColorSwatchView) {
        annotationModel?.strokeColor = sender.fillColor
        canvasView?.needsDisplay = true
        toolbarDelegate?.captureToolbarDidOptionsChange()
    }

    @objc private func decreaseLineWidth() {
        guard let model = annotationModel else { return }
        model.lineWidth = max(1, model.lineWidth - 1)
        updateLineWidthLabel()
    }

    @objc private func increaseLineWidth() {
        guard let model = annotationModel else { return }
        model.lineWidth = min(16, model.lineWidth + 1)
        updateLineWidthLabel()
    }

    @objc private func selectSolidArrow() {
        annotationModel?.arrowDashed = false
        refreshSecondaryToolbar()
    }

    @objc private func selectDashedArrow() {
        annotationModel?.arrowDashed = true
        refreshSecondaryToolbar()
    }

    @objc private func decreaseFontSize() {
        guard let model = annotationModel else { return }
        model.fontSize = max(12, model.fontSize - 2)
        model.persistTextStyle()
        updateLineWidthLabel()
        refreshSecondaryToolbar()
    }

    @objc private func increaseFontSize() {
        guard let model = annotationModel else { return }
        model.fontSize = min(96, model.fontSize + 2)
        model.persistTextStyle()
        updateLineWidthLabel()
        refreshSecondaryToolbar()
    }

    @objc private func toggleBold() {
        annotationModel?.textBold.toggle()
        annotationModel?.persistTextStyle()
        refreshSecondaryToolbar()
    }

    @objc private func toggleItalic() {
        annotationModel?.textItalic.toggle()
        annotationModel?.persistTextStyle()
        refreshSecondaryToolbar()
    }

    @objc private func toggleUnderline() {
        annotationModel?.textUnderline.toggle()
        annotationModel?.persistTextStyle()
        refreshSecondaryToolbar()
    }

    @objc private func toggleTextBackground() {
        annotationModel?.textBackgroundEnabled.toggle()
        annotationModel?.persistTextStyle()
        refreshSecondaryToolbar()
    }

    @objc private func selectMosaicRect() {
        annotationModel?.mosaicMode = .rect
        refreshSecondaryToolbar()
    }

    @objc private func selectMosaicBrushSmall() {
        annotationModel?.mosaicMode = .brush
        annotationModel?.mosaicBrushSize = .small
        refreshSecondaryToolbar()
    }

    @objc private func selectMosaicBrushMedium() {
        annotationModel?.mosaicMode = .brush
        annotationModel?.mosaicBrushSize = .medium
        refreshSecondaryToolbar()
    }

    @objc private func selectMosaicBrushLarge() {
        annotationModel?.mosaicMode = .brush
        annotationModel?.mosaicBrushSize = .large
        refreshSecondaryToolbar()
    }

    @objc private func undoAction() {
        toolbarDelegate?.captureToolbarDidUndo()
    }

    @objc private func redoAction() {
        toolbarDelegate?.captureToolbarDidRedo()
    }

    @objc private func confirmAction() {
        toolbarDelegate?.captureToolbarDidConfirm()
    }

    @objc private func pinAction() {
        toolbarDelegate?.captureToolbarDidPin()
    }

    @objc private func ocrAction() {
        toolbarDelegate?.captureToolbarDidOCR()
    }

    @objc private func cancelAction() {
        toolbarDelegate?.captureToolbarDidCancel()
    }

    private func toolTag(_ tool: ScreenshotAnnotationTool) -> Int {
        ScreenshotAnnotationTool.allCases.firstIndex(of: tool) ?? 0
    }

    private func toolFromTag(_ tag: Int) -> ScreenshotAnnotationTool? {
        guard ScreenshotAnnotationTool.allCases.indices.contains(tag) else { return nil }
        return ScreenshotAnnotationTool.allCases[tag]
    }

    private func toolLabel(_ tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .selection: return L10n.t(.screenshotToolSelection)
        case .rectangle: return L10n.t(.screenshotToolRectangle)
        case .arrow: return L10n.t(.screenshotToolArrow)
        case .ellipse: return L10n.t(.screenshotToolEllipse)
        case .text: return L10n.t(.screenshotToolText)
        case .pencil: return L10n.t(.screenshotToolPencil)
        case .highlighter: return L10n.t(.screenshotToolHighlighter)
        case .eraser: return L10n.t(.screenshotToolEraser)
        case .mosaic: return L10n.t(.screenshotToolMosaic)
        }
    }
}

private final class ToolbarToggleButton: NSButton {
    override var state: NSControl.StateValue {
        didSet { updateSelectedAppearance() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSelectedAppearance()
    }

    func updateSelectedAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        let isSelected = state == .on
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        contentTintColor = isSelected ? .controlAccentColor : .labelColor
    }
}

private final class ToolbarColorSwatchView: NSView {
    let fillColor: NSColor
    weak var target: AnyObject?
    var action: Selector?

    init(color: NSColor) {
        fillColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.cornerRadius = bounds.width / 2
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        guard let target, let action else { return }
        _ = target.perform(action, with: self)
    }
}
