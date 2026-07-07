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
}

final class CaptureSelectionToolbarPanel: NSPanel {
    weak var toolbarDelegate: CaptureSelectionToolbarDelegate?

    private weak var annotationModel: AnnotationCanvasModel?
    private weak var canvasView: AnnotationCanvasView?

    private var selectionButton: NSButton?
    private var annotationButtons: [NSButton] = []
    private var lineWidthLabel: NSTextField?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: ScreenshotChrome.barHeight),
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
    }

    func setAnnotationToolActive(_ tool: ScreenshotAnnotationTool) {
        selectionButton?.state = .off
        (selectionButton as? ToolbarToggleButton)?.updateSelectedAppearance()
        for button in annotationButtons {
            let isActive = toolFromTag(button.tag) == tool
            button.state = isActive ? .on : .off
            (button as? ToolbarToggleButton)?.updateSelectedAppearance()
        }
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
    }

    private func buildToolbar() -> NSView {
        let bar = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

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
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: AppSpacing.sm),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -AppSpacing.sm),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        return bar
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
        contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
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
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        guard let target, let action else { return }
        _ = target.perform(action, with: self)
    }
}
