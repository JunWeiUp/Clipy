import AppKit

class PinFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PinImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var imageScale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    var imageOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    var rotationDegrees: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.translateBy(x: bounds.midX, y: bounds.midY)
        context?.rotate(by: rotationDegrees * .pi / 180)
        context?.setAlpha(imageOpacity)

        // Draw the image filling the view's bounds. The window is resized to carry the zoom
        // (see PinPanel.applyZoom), so the image scales together with the window — the whole
        // image stays visible and never gets clipped or leaves empty margins.
        let drawSize = bounds.size
        let drawRect = NSRect(
            x: -drawSize.width / 2,
            y: -drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
        context?.restoreGState()
    }
}

final class PinPanel: PinFloatingPanel, NSWindowDelegate {
    private let pinView = PinImageView()
    private let closeButton = NSButton()
    private let editButton = NSButton()
    private let panelID: UUID
    private let onClose: (UUID) -> Void

    private var imageScale: CGFloat = 1
    private var imageOpacity: CGFloat = 1
    private var rotationDegrees: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    /// The unscaled window size (image size fitted into the screen). Zooming grows/shrinks
    /// the actual window around its center, so the content is never clipped and the zoom
    /// feels continuous instead of jump-stepping the draw transform.
    private let baseSize: NSSize

    /// Current image shown in the pin. Updated after each edit so subsequent edits stack on
    /// the already-annotated result.
    private var currentImage: NSImage

    // MARK: Edit mode state

    private var isEditing = false
    private var savedRotationDegrees: CGFloat = 0
    private var annotationModel = AnnotationCanvasModel()
    private var canvasView: AnnotationCanvasView?
    private var editToolbar: PinEditToolbar?
    private var editConstraints: [NSLayoutConstraint] = []

    init(image: NSImage, screenRect: NSRect? = nil, id: UUID, onClose: @escaping (UUID) -> Void) {
        self.panelID = id
        self.onClose = onClose
        self.currentImage = image

        let fittedSize: NSSize
        let fittedOrigin: NSPoint
        if let screenRect, screenRect.width > 1, screenRect.height > 1 {
            // Pin exactly where the capture was taken on screen — do not jump to the mouse.
            fittedSize = screenRect.size
            fittedOrigin = screenRect.origin
        } else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            let maxWidth = visible.width * 0.8
            let maxHeight = visible.height * 0.8
            let aspect = image.size.width / max(image.size.height, 1)
            var width = min(image.size.width, maxWidth)
            var height = width / aspect
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }
            fittedSize = NSSize(width: max(120, width), height: max(80, height))
            fittedOrigin = Self.defaultOrigin(for: fittedSize)
        }
        self.baseSize = fittedSize

        let panelFrame = NSRect(origin: fittedOrigin, size: fittedSize)

        super.init(
            contentRect: NSRect(origin: .zero, size: panelFrame.size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        delegate = self
        // `.screenSaver` sits above `.floating`, so the pin stays on top of fullscreen
        // apps and other floating windows — matching the capture overlay/magnifier behavior.
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        // NSPanel hides on deactivate by default — that would make the pin vanish whenever
        // the user clicks away to another app. A pinned screenshot is a persistent overlay,
        // so it must stay visible regardless of activation state.
        hidesOnDeactivate = false
        hasShadow = true
        // `.stationary` keeps the pin anchored to its screen when switching Spaces,
        // instead of sliding around or disappearing.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true

        let container = PinContainerView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.onDoubleClick = { [weak self] in self?.hidePanel() }

        pinView.image = image
        pinView.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.t(.close))
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        editButton.bezelStyle = .inline
        editButton.isBordered = false
        editButton.image = NSImage(systemSymbolName: "pencil.circle.fill", accessibilityDescription: L10n.t(.screenshotEdit))
        editButton.target = self
        editButton.action = #selector(enterEditMode)
        editButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(pinView)
        container.addSubview(closeButton)
        container.addSubview(editButton)
        contentView = container

        NSLayoutConstraint.activate([
            pinView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pinView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pinView.topAnchor.constraint(equalTo: container.topAnchor),
            pinView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            // Edit button sits just to the left of the close button.
            editButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            editButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            editButton.widthAnchor.constraint(equalToConstant: 20),
            editButton.heightAnchor.constraint(equalToConstant: 20)
        ])

        setFrame(panelFrame, display: false)
        updatePinViewTransform()
        updateTrackingArea()
    }

    private static func defaultOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
    }

    override func becomeKey() {
        super.becomeKey()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let trackingArea {
            contentView?.removeTrackingArea(trackingArea)
        }
        guard let contentView else { return }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    override func scrollWheel(with event: NSEvent) {
        // While editing, the canvas owns pointer interaction; do not zoom.
        if isEditing { return }

        if event.modifierFlags.contains(.command) {
            // Opacity: continuous on trackpad, stepped on mouse wheel.
            if event.hasPreciseScrollingDeltas {
                imageOpacity = min(1, max(0.2, imageOpacity + CGFloat(-event.scrollingDeltaY) * 0.002))
            } else {
                let delta = event.deltaY > 0 ? 0.05 : -0.05
                imageOpacity = min(1, max(0.2, imageOpacity + delta))
            }
            updatePinViewTransform()
            return
        }

        // Zoom: trackpads deliver continuous sub-pixel deltas, so multiply the scale by a
        // power of two driven by the delta — this makes the zoom follow the fingers
        // smoothly instead of jumping in fixed 10% steps. Mouse wheels keep the discrete
        // behavior. The window itself is resized around its center, so content is never
        // clipped (previously zoom only scaled the draw transform inside a fixed window).
        let factor: CGFloat
        if event.hasPreciseScrollingDeltas {
            factor = pow(2, CGFloat(-event.scrollingDeltaY) * 0.008)
        } else {
            factor = event.deltaY > 0 ? 1.1 : 0.9
        }
        applyZoom(imageScale * factor)
    }

    /// Resize the window to `baseSize * scale`, anchored on the window's center, clamped so
    /// the whole pin always fits on the current screen. The image fills the window, so the
    /// whole image scales with the window — never clipped, never leaves empty margins.
    private func applyZoom(_ scale: CGFloat) {
        let clamped = min(8, max(0.25, scale))

        // Keep the whole pin within the current screen (the whole image must stay visible).
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? baseSize
        let widthLimit = visible.width / max(baseSize.width, 1)
        let heightLimit = visible.height / max(baseSize.height, 1)
        let screenClamped = min(clamped, min(widthLimit, heightLimit))

        if abs(screenClamped - imageScale) < 0.0005 { return }
        imageScale = screenClamped

        let newSize = NSSize(
            width: (baseSize.width * imageScale).rounded(),
            height: (baseSize.height * imageScale).rounded()
        )
        let current = frame
        // Keep the visual center fixed so the zoom doesn't make the window drift.
        var newOrigin = NSPoint(
            x: current.midX - newSize.width / 2,
            y: current.midY - newSize.height / 2
        )

        // Clamp the origin so the (now screen-sized or smaller) window stays on screen.
        if let visibleRect = (screen ?? NSScreen.main)?.visibleFrame {
            newOrigin.x = max(visibleRect.minX, min(newOrigin.x, visibleRect.maxX - newSize.width))
            newOrigin.y = max(visibleRect.minY, min(newOrigin.y, visibleRect.maxY - newSize.height))
        }

        setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
        updateTrackingArea()
    }

    override func keyDown(with event: NSEvent) {
        // While editing, let the canvas/toolbar handle keys; rotation/opacity shortcuts are disabled.
        if isEditing {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                if event.modifierFlags.contains(.shift) {
                    annotationModel.redo()
                } else {
                    annotationModel.undo()
                }
                canvasView?.needsDisplay = true
                editToolbar?.refreshUndoRedo()
            case "escape":
                exitEditMode(save: false)
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            rotationDegrees += event.modifierFlags.contains(.shift) ? -90 : 90
            updatePinViewTransform()
        case "+", "=":
            if event.modifierFlags.contains(.command) {
                imageOpacity = min(1, imageOpacity + 0.05)
                updatePinViewTransform()
            }
        case "-":
            if event.modifierFlags.contains(.command) {
                imageOpacity = max(0.2, imageOpacity - 0.05)
                updatePinViewTransform()
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func updatePinViewTransform() {
        // Zoom is applied by resizing the window (see applyZoom), so the image view itself
        // stays at scale 1 — only opacity and rotation use the draw transform now.
        pinView.imageScale = 1
        pinView.imageOpacity = imageOpacity
        pinView.rotationDegrees = rotationDegrees
    }

    // MARK: Edit mode

    @objc private func enterEditMode() {
        guard !isEditing else { return }
        isEditing = true

        // Rotation breaks annotation coordinate mapping; park it at 0 while editing and
        // restore afterwards.
        savedRotationDegrees = rotationDegrees
        rotationDegrees = 0
        updatePinViewTransform()

        // Disable dragging so the canvas owns mouse interaction.
        isMovableByWindowBackground = false

        guard let container = contentView else { return }

        let canvas = AnnotationCanvasView(baseImage: currentImage, model: annotationModel, contentMode: .fill)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        self.canvasView = canvas

        let toolbar = PinEditToolbar(model: annotationModel) { [weak self] in
            self?.canvasView?.needsDisplay = true
        } onFinish: { [weak self] save in
            self?.exitEditMode(save: save)
        }
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        self.editToolbar = toolbar

        let constraints = [
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32)
        ]
        NSLayoutConstraint.activate(constraints)
        editConstraints = constraints

        // Hide the floating buttons while editing; the toolbar has Done/Cancel.
        closeButton.isHidden = true
        editButton.isHidden = true

        makeKey()
        canvas.needsDisplay = true
    }

    private func exitEditMode(save: Bool) {
        guard isEditing else { return }
        isEditing = false

        if save {
            // Bake annotations into the image at native resolution, then update the pin so
            // subsequent edits stack on the annotated result.
            if let flattened = AnnotationCanvasView.flatten(baseImage: currentImage, model: annotationModel) {
                currentImage = flattened
                pinView.image = currentImage
            }
        }

        canvasView?.removeFromSuperview()
        canvasView = nil
        editToolbar?.removeFromSuperview()
        editToolbar = nil
        NSLayoutConstraint.deactivate(editConstraints)
        editConstraints = []

        annotationModel.resetSession()

        // Restore interaction + rotation.
        isMovableByWindowBackground = true
        rotationDegrees = savedRotationDegrees
        updatePinViewTransform()

        closeButton.isHidden = false
        editButton.isHidden = false
    }

    @objc private func closePanel() {
        if isEditing { exitEditMode(save: false) }
        orderOut(nil)
        onClose(panelID)
    }

    private func hidePanel() {
        orderOut(nil)
    }

    func showPanel() {
        // orderFrontRegardless places the panel above other apps' windows even when our app
        // is not active, so the pin stays on top after the user clicks away. Combined with
        // level = .screenSaver + hidesOnDeactivate = false, the pin remains visible on top.
        orderFrontRegardless()
        makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        onClose(panelID)
    }
}

// MARK: - Edit toolbar

private final class PinEditToolbar: NSView {
    private let model: AnnotationCanvasModel
    private let onChange: () -> Void
    private let onFinish: (Bool) -> Void
    private var toolButtons: [ScreenshotAnnotationTool: NSButton] = [:]

    private let paletteColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]

    init(model: AnnotationCanvasModel, onChange: @escaping () -> Void, onFinish: @escaping (Bool) -> Void) {
        self.model = model
        self.onChange = onChange
        self.onFinish = onFinish
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])

        // Tool buttons.
        for tool in ScreenshotAnnotationTool.allCases {
            let button = makeToolButton(tool)
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        selectTool(.rectangle)

        stack.addArrangedSubview(separator())

        // Color swatches.
        for color in paletteColors {
            stack.addArrangedSubview(makeColorButton(color))
        }

        stack.addArrangedSubview(separator())

        // Line width stepper.
        let widthLabel = NSTextField(labelWithString: "3")
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        widthLabel.alignment = .center
        widthLabel.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let minus = makeImageButton(symbol: "minus") { [weak self, weak widthLabel] in
            guard let self else { return }
            self.model.lineWidth = max(1, (self.model.lineWidth - 1).rounded())
            widthLabel?.stringValue = "\(Int(self.model.lineWidth))"
            self.onChange()
        }
        let plus = makeImageButton(symbol: "plus") { [weak self, weak widthLabel] in
            guard let self else { return }
            self.model.lineWidth = min(40, (self.model.lineWidth + 1).rounded())
            widthLabel?.stringValue = "\(Int(self.model.lineWidth))"
            self.onChange()
        }
        stack.addArrangedSubview(minus)
        stack.addArrangedSubview(widthLabel)
        stack.addArrangedSubview(plus)

        stack.addArrangedSubview(separator())

        // Undo / redo / clear.
        stack.addArrangedSubview(makeImageButton(symbol: "arrow.uturn.backward") { [weak self] in
            self?.model.undo(); self?.onChange(); self?.refreshUndoRedo()
        })
        stack.addArrangedSubview(makeImageButton(symbol: "arrow.uturn.forward") { [weak self] in
            self?.model.redo(); self?.onChange(); self?.refreshUndoRedo()
        })
        stack.addArrangedSubview(makeImageButton(symbol: "trash") { [weak self] in
            self?.model.clearAnnotations(); self?.onChange(); self?.refreshUndoRedo()
        })

        stack.addArrangedSubview(separator())

        // Done.
        let done = NSButton(title: L10n.t(.screenshotEditDone), target: nil, action: nil)
        done.bezelStyle = .inline
        done.controlSize = .small
        done.target = self
        done.action = #selector(doneTapped)
        stack.addArrangedSubview(done)
    }

    private func makeToolButton(_ tool: ScreenshotAnnotationTool) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: tool.id)
        button.contentTintColor = .labelColor
        button.target = self
        button.action = #selector(toolTapped(_:))
        button.tag = ScreenshotAnnotationTool.allCases.firstIndex(of: tool) ?? 0
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func makeColorButton(_ color: NSColor) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        button.contentTintColor = color
        button.target = self
        button.action = #selector(colorTapped(_:))
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    private func makeImageButton(symbol: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = .labelColor
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        // Use an associated object closure to keep the call site simple.
        objc_setAssociatedObject(button, &Self.actionKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        button.target = self
        button.action = #selector(imageButtonTapped(_:))
        return button
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func selectTool(_ tool: ScreenshotAnnotationTool) {
        model.selectedTool = tool
        model.lineWidth = tool.defaultLineWidth
        for (t, button) in toolButtons {
            button.contentTintColor = (t == tool) ? .controlAccentColor : .labelColor
        }
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let all = ScreenshotAnnotationTool.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        selectTool(all[sender.tag])
        onChange()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        model.strokeColor = sender.contentTintColor ?? .systemRed
        onChange()
    }

    @objc private func imageButtonTapped(_ sender: NSButton) {
        if let action = objc_getAssociatedObject(sender, &Self.actionKey) as? () -> Void {
            action()
        }
    }

    @objc private func doneTapped() {
        onFinish(true)
    }

    fileprivate func refreshUndoRedo() {
        // Buttons are stateless images; enabled-state could be toggled here if desired.
    }

    private static var actionKey: UInt8 = 0
}

private final class PinContainerView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class PinPanelController {
    static let shared = PinPanelController()

    private var panels: [UUID: PinPanel] = [:]

    private init() {}

    func pin(image: NSImage, at screenRect: NSRect? = nil, skipIngest: Bool = false) {
        if !skipIngest,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: true)
        }

        let id = UUID()
        let panel = PinPanel(image: image, screenRect: screenRect, id: id) { [weak self] panelID in
            self?.panels.removeValue(forKey: panelID)
        }
        panels[id] = panel
        panel.showPanel()
    }
}
