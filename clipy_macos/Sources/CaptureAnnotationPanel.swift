import AppKit

final class CaptureAnnotationPanel: NSPanel {
    let canvasView: AnnotationCanvasView
    private var canvasSize: NSSize = .zero

    /// Cache of fully-transparent base images keyed by exact pixel size. While
    /// dragging the selection this panel used to `lockFocus` a brand-new
    /// same-size bitmap on every size change; reusing the cached one avoids
    /// a steady stream of throwaway allocations that inflate the malloc
    /// high-water mark. Cleared on deinit.
    private static var transparentImageCache: [String: NSImage] = [:]

    init(model: AnnotationCanvasModel, size: NSSize) {
        canvasSize = size
        let placeholder = Self.transparentImage(size: size)
        canvasView = AnnotationCanvasView(baseImage: placeholder, model: model, contentMode: .fill)
        canvasView.composingMode = true

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        canvasView.frame = NSRect(origin: .zero, size: size)
        canvasView.autoresizingMask = [.width, .height]
        contentView = canvasView
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    var isTextEditing: Bool { canvasView.isTextEditing }

    func reposition(to frame: NSRect) {
        setFrame(frame, display: true)
        guard frame.size != canvasSize else { return }
        canvasSize = frame.size
        canvasView.replaceBaseImage(Self.transparentImage(size: frame.size))
        canvasView.frame = NSRect(origin: .zero, size: frame.size)
        canvasView.needsDisplay = true
    }

    func setInteractionEnabled(_ enabled: Bool) {
        ignoresMouseEvents = !enabled
    }

    func activateForTextInput() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func handle(event: NSEvent) {
        let windowPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = canvasView.convert(windowPoint, from: nil)
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            canvasView.handlePointer(event: event, at: point)
        case .keyDown:
            keyDown(with: event)
        default:
            break
        }
    }

    deinit {
        Self.transparentImageCache.removeAll()
    }

    private static func transparentImage(size: NSSize) -> NSImage {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let cached = transparentImageCache[key] {
            return cached
        }
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        // Cap the cache so an erratic drag (many distinct sizes) cannot grow
        // it without bound; a handful of entries covers typical drag behavior.
        if transparentImageCache.count < 16 {
            transparentImageCache[key] = image
        }
        return image
    }
}
