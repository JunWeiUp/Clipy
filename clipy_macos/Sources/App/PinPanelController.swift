import AppKit

class PinFloatingPanel: EscapeClosingPanel {
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
    // Editing opens macshot's DetachedEditorWindowController (see enterEditMode);
    // the in-pin canvas/toolbar machinery has been removed.

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
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t(.close))
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.wantsLayer = true

        editButton.bezelStyle = .inline
        editButton.isBordered = false
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: L10n.t(.screenshotEdit))
        editButton.contentTintColor = .white
        editButton.target = self
        editButton.action = #selector(enterEditMode)
        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.wantsLayer = true

        container.addSubview(pinView)
        container.addSubview(closeButton)
        container.addSubview(editButton)
        contentView = container

        NSLayoutConstraint.activate([
            pinView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pinView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pinView.topAnchor.constraint(equalTo: container.topAnchor),
            pinView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            // Edit button sits just to the left of the close button.
            editButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            editButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            editButton.widthAnchor.constraint(equalToConstant: 24),
            editButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        // Semi-transparent dark disc behind each control glyph so the white icon
        // stays readable on any capture background — including pure-white pins,
        // where the raw SF Symbol would otherwise blend in and vanish. A faint
        // white hairline further separates the disc from light backgrounds.
        for button in [closeButton, editButton] {
            button.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
            button.layer?.cornerRadius = 12
            button.layer?.masksToBounds = true
            button.layer?.borderWidth = 0.5
            button.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }

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

    /// Open the pinned image in macshot's full detached editor (18 tools,
    /// secondary options row, beautify/effects, crop/flip, undo/redo). This
    /// matches macshot's pin → edit behavior: the floating pin closes and the
    /// image opens in a standalone editor window. Saving in the editor ingests
    /// the edited image back into clipy1's history (see AppDelegate's
    /// ScreenshotAppIntegration conformance), where it can be re-pinned.
    @objc private func enterEditMode() {
        // Capture the current (possibly rotated/zoomed) image as the editor input.
        // The detached editor works in image-relative coordinates, so we hand it
        // the composited frame the user currently sees.
        let editorImage = currentImage

        // Close this floating pin — the editor is now the owner of the image.
        closePanel()

        // Activate the app so the editor window can become key (.regular policy).
        NSApp.activate(ignoringOtherApps: true)
        DetachedEditorWindowController.open(image: editorImage, fromCapture: false)
    }


    override func cancelOperation(_ sender: Any?) {
        closePanel()
    }

    @objc private func closePanel() {
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

        // Pins are floating reference overlays. Downsample to a max edge of
        // 2560px (enough for a single pin on a mainstream 5K display) so each
        // pinned NSImage costs ~8MB instead of ~30MB+ for a 4K capture. The
        // full-res original is already in history/clipboard and is never
        // affected; this only changes the in-memory copy the panel holds.
        let displayImage = Self.downsampleForPin(image, maxEdge: 2560) ?? image

        let id = UUID()
        let panel = PinPanel(image: displayImage, screenRect: screenRect, id: id) { [weak self] panelID in
            self?.panels.removeValue(forKey: panelID)
        }
        panels[id] = panel
        panel.showPanel()
    }

    /// Downsample an NSImage so its longest edge is <= maxEdge, using an image
    /// source that does NOT cache the decoded full-res bitmap. Returns nil if
    /// the image is already small enough or the conversion fails (caller falls
    /// back to the original).
    private static func downsampleForPin(_ image: NSImage, maxEdge: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longestEdge = max(size.width, size.height)
        guard longestEdge > maxEdge else { return nil }

        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
