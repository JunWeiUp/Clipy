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
        context?.scaleBy(x: imageScale, y: imageScale)
        context?.setAlpha(imageOpacity)

        let drawSize = image.size
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
    private let panelID: UUID
    private let onClose: (UUID) -> Void

    private var imageScale: CGFloat = 1
    private var imageOpacity: CGFloat = 1
    private var rotationDegrees: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    init(image: NSImage, screenRect: NSRect? = nil, id: UUID, onClose: @escaping (UUID) -> Void) {
        self.panelID = id
        self.onClose = onClose

        let panelFrame: NSRect
        if let screenRect, screenRect.width > 1, screenRect.height > 1 {
            panelFrame = screenRect
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
            let size = NSSize(width: max(120, width), height: max(80, height))
            panelFrame = NSRect(origin: Self.defaultOrigin(for: size), size: size)
        }

        super.init(
            contentRect: NSRect(origin: .zero, size: panelFrame.size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        delegate = self
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

        container.addSubview(pinView)
        container.addSubview(closeButton)
        contentView = container

        NSLayoutConstraint.activate([
            pinView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pinView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pinView.topAnchor.constraint(equalTo: container.topAnchor),
            pinView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])

        setFrame(panelFrame, display: false)
        updatePinViewTransform()
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
        if event.modifierFlags.contains(.command) {
            let delta = event.deltaY > 0 ? 0.05 : -0.05
            imageOpacity = min(1, max(0.2, imageOpacity + delta))
        } else {
            let factor = event.deltaY > 0 ? 1.1 : 0.9
            imageScale = min(4, max(0.25, imageScale * factor))
        }
        updatePinViewTransform()
    }

    override func keyDown(with event: NSEvent) {
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
        pinView.imageScale = imageScale
        pinView.imageOpacity = imageOpacity
        pinView.rotationDegrees = rotationDegrees
    }

    @objc private func closePanel() {
        orderOut(nil)
        onClose(panelID)
    }

    private func hidePanel() {
        orderOut(nil)
    }

    func showPanel() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose(panelID)
    }
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
