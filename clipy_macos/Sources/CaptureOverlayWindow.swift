import AppKit

enum CaptureOverlayRequest {
    case cancel
    case region(NSRect)
    case window(CGWindowID, NSRect)
}

final class CaptureOverlayController {
    private let mode: ScreenshotCaptureMode
    private let onComplete: (NSImage?, NSRect?) -> Void
    private var pendingCaptureRect: NSRect = .zero
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var magnifier = CaptureMagnifierController()
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var isFinished = false

    init(mode: ScreenshotCaptureMode, onComplete: @escaping (NSImage?, NSRect?) -> Void) {
        self.mode = mode
        self.onComplete = onComplete
    }

    func present() {
        for screen in NSScreen.screens {
            let window = CaptureOverlayWindow(screen: screen, mode: mode) { [weak self] request in
                self?.handleCaptureRequest(request)
            }
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }

        if mode != .fullscreen {
            magnifier.show()
        }

        NSApp.activate(ignoringOtherApps: true)

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.forwardEvent(event)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.forwardEvent(event)
            return event
        }
    }

    private func forwardEvent(_ event: NSEvent) {
        guard !isFinished else { return }

        if event.type == .mouseMoved, mode != .fullscreen {
            magnifier.update(at: NSEvent.mouseLocation)
        }

        guard let window = overlayWindows.first(where: { $0.screenFrame.contains(NSEvent.mouseLocation) }) ?? overlayWindows.first else {
            return
        }
        window.handle(event: event)
    }

    private func handleCaptureRequest(_ request: CaptureOverlayRequest) {
        guard !isFinished else { return }

        switch request {
        case .cancel:
            finish(with: nil, screenRect: nil)
        case .region, .window:
            magnifier.dismiss()
            hideOverlays()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.performCapture(request)
            }
        }
    }

    private func hideOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
    }

    private func performCapture(_ request: CaptureOverlayRequest) {
        let complete: (NSImage?) -> Void = { [weak self] image in
            guard let self else { return }
            self.finish(with: image, screenRect: self.pendingCaptureRect)
        }

        switch request {
        case .cancel:
            complete(nil)
        case .region(let rect):
            pendingCaptureRect = rect
            ScreenshotCaptureService.capture(rect: rect, completion: complete)
        case .window(let windowID, let rect):
            pendingCaptureRect = rect
            ScreenshotCaptureService.capture(windowID: windowID, completion: complete)
        }
    }

    private func finish(with image: NSImage?, screenRect: NSRect?) {
        guard !isFinished else { return }
        isFinished = true
        magnifier.dismiss()

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
        onComplete(image, screenRect)
    }

    func cancel() {
        finish(with: nil, screenRect: nil)
    }
}

final class CaptureOverlayWindow: NSPanel {
    let screenFrame: NSRect
    private let overlayView: CaptureOverlayView

    init(screen: NSScreen, mode: ScreenshotCaptureMode, onRequest: @escaping (CaptureOverlayRequest) -> Void) {
        self.screenFrame = screen.frame
        self.overlayView = CaptureOverlayView(mode: mode, screenFrame: screen.frame)

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false

        overlayView.onRequest = onRequest
        contentView = overlayView
    }

    func handle(event: NSEvent) {
        let localPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
        overlayView.handle(event: event, at: localPoint)
    }
}

final class CaptureOverlayView: NSView {
    private let mode: ScreenshotCaptureMode
    private let screenFrame: NSRect
    private var selectionRect: NSRect = .zero
    private var dragStart: NSPoint?
    private var highlightedBounds: NSRect = .zero
    private var highlightedWindowID: CGWindowID?
    private var highlightSource: UIElementDetectSource?
    private var hasSubmittedRequest = false
    private var hasStartedDragging = false
    private var showHint = true
    private var isAdjustingSelection = false

    var onRequest: ((CaptureOverlayRequest) -> Void)?

    private var isSmartCapture: Bool { mode == .region || mode == .window }

    init(mode: ScreenshotCaptureMode, screenFrame: NSRect) {
        self.mode = mode
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func handle(event: NSEvent, at point: NSPoint) {
        guard !hasSubmittedRequest else { return }

        switch event.type {
        case .keyDown:
            handleKeyDown(event)
        case .mouseMoved:
            if isSmartCapture, dragStart == nil {
                updateElementHighlight(at: screenPoint(for: point))
                needsDisplay = true
            }
        case .leftMouseDown:
            handleLeftMouseDown(at: point)
        case .leftMouseDragged:
            handleLeftMouseDragged(at: point)
        case .leftMouseUp:
            handleLeftMouseUp(at: point)
        case .rightMouseDown:
            submit(.cancel)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            submit(.cancel)
            return
        }

        guard isSmartCapture, selectionRect.width > 0, selectionRect.height > 0, dragStart == nil else { return }

        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let option = event.modifierFlags.contains(.option)

        switch event.keyCode {
        case 123: nudgeSelection(dx: -step, dy: 0, resize: option, edge: .left)
        case 124: nudgeSelection(dx: step, dy: 0, resize: option, edge: .right)
        case 125: nudgeSelection(dx: 0, dy: -step, resize: option, edge: .bottom)
        case 126: nudgeSelection(dx: 0, dy: step, resize: option, edge: .top)
        case 36: completeRegionCapture()
        default: break
        }
    }

    private enum SelectionEdge {
        case left, right, top, bottom
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat, resize: Bool, edge: SelectionEdge) {
        if resize {
            switch edge {
            case .left: selectionRect.origin.x += dx; selectionRect.size.width -= dx
            case .right: selectionRect.size.width += dx
            case .top: selectionRect.origin.y += dy; selectionRect.size.height -= dy
            case .bottom: selectionRect.size.height += dy
            }
            selectionRect.size.width = max(4, selectionRect.size.width)
            selectionRect.size.height = max(4, selectionRect.size.height)
        } else {
            selectionRect.origin.x += dx
            selectionRect.origin.y += dy
        }
        isAdjustingSelection = true
        showHint = false
        needsDisplay = true
    }

    private func handleLeftMouseDown(at point: NSPoint) {
        guard isSmartCapture else { return }

        if highlightedBounds.width > 0, dragStart == nil, !hasStartedDragging {
            let globalRect = globalRect(from: highlightedBounds)
            if let windowID = highlightedWindowID, highlightSource == .window {
                submit(.window(windowID, globalRect))
            } else {
                submit(.region(globalRect))
            }
            return
        }

        dragStart = point
        selectionRect = NSRect(origin: point, size: .zero)
        hasStartedDragging = true
        showHint = false
        highlightedBounds = .zero
        highlightSource = nil
        highlightedWindowID = nil
        needsDisplay = true
    }

    private func handleLeftMouseDragged(at point: NSPoint) {
        guard isSmartCapture, let start = dragStart else { return }
        var rect = normalizedRect(from: start, to: point)
        if let snap = currentSnapTarget() {
            rect = UIElementDetector.snapRect(rect, to: localRect(from: snap))
        }
        selectionRect = rect
        needsDisplay = true
    }

    private func handleLeftMouseUp(at point: NSPoint) {
        guard isSmartCapture, dragStart != nil else { return }
        var rect = normalizedRect(from: dragStart!, to: point)
        if let snap = currentSnapTarget() {
            rect = UIElementDetector.snapRect(rect, to: localRect(from: snap))
        }
        selectionRect = rect
        dragStart = nil
        completeRegionCapture()
    }

    private func currentSnapTarget() -> NSRect? {
        guard highlightedBounds.width > 0 else { return nil }
        return globalRect(from: highlightedBounds)
    }

    private func updateElementHighlight(at screenPoint: NSPoint) {
        guard PreferencesManager.shared.isScreenshotElementSnapEnabled else {
            highlightedBounds = .zero
            highlightSource = nil
            highlightedWindowID = nil
            return
        }

        if let result = UIElementDetector.detect(
            at: screenPoint,
            elementSnapEnabled: true
        ) {
            highlightedBounds = localRect(from: result.rect)
            highlightSource = result.source
            highlightedWindowID = result.windowID
        } else {
            highlightedBounds = .zero
            highlightSource = nil
            highlightedWindowID = nil
        }
    }

    private func submit(_ request: CaptureOverlayRequest) {
        guard !hasSubmittedRequest else { return }
        hasSubmittedRequest = true
        onRequest?(request)
    }

    private func screenPoint(for localPoint: NSPoint) -> NSPoint {
        NSPoint(x: screenFrame.origin.x + localPoint.x, y: screenFrame.origin.y + localPoint.y)
    }

    private func globalRect(from localRect: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.origin.x + localRect.origin.x,
            y: screenFrame.origin.y + localRect.origin.y,
            width: localRect.width,
            height: localRect.height
        )
    }

    private func localRect(from globalRect: NSRect) -> NSRect {
        NSRect(
            x: globalRect.origin.x - screenFrame.origin.x,
            y: globalRect.origin.y - screenFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func normalizedRect(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func completeRegionCapture() {
        guard selectionRect.width > 4, selectionRect.height > 4 else {
            selectionRect = .zero
            isAdjustingSelection = false
            needsDisplay = true
            return
        }
        submit(.region(globalRect(from: selectionRect)))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        dirtyRect.fill()

        guard isSmartCapture else { return }

        if selectionRect.width > 0, selectionRect.height > 0 {
            NSColor.clear.setFill()
            selectionRect.fill(using: .copy)
            drawSelectionChrome(in: selectionRect)
        } else if highlightedBounds.width > 0, dragStart == nil {
            drawElementHighlight(in: highlightedBounds)
        }

        if showHint && !hasStartedDragging {
            drawHintBar()
        }
    }

    private func drawElementHighlight(in rect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()

        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.stroke()

        let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        drawSizeLabel(sizeText, for: rect)
    }

    private func drawSelectionChrome(in rect: NSRect, glow: Bool = false) {
        if glow {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            let glowRect = rect.insetBy(dx: -4, dy: -4)
            NSBezierPath(roundedRect: glowRect, xRadius: 4, yRadius: 4).fill()
        }

        NSColor.controlAccentColor.setStroke()
        let outer = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        outer.stroke()

        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        inner.lineWidth = 2
        inner.stroke()

        drawCornerHandles(in: rect)
        drawSizeLabel("\(Int(rect.width)) × \(Int(rect.height))", for: rect)
    }

    private func drawCornerHandles(in rect: NSRect) {
        let handleLength: CGFloat = 8
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2

        path.move(to: NSPoint(x: rect.minX, y: rect.minY + handleLength))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + handleLength, y: rect.minY))

        path.move(to: NSPoint(x: rect.maxX - handleLength, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + handleLength))

        path.move(to: NSPoint(x: rect.minX, y: rect.maxY - handleLength))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + handleLength, y: rect.maxY))

        path.move(to: NSPoint(x: rect.maxX - handleLength, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - handleLength))

        path.stroke()
    }

    private func drawSizeLabel(_ text: String, for rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 10, height: 4)
        let labelSize = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let labelOrigin = NSPoint(
            x: rect.midX - labelSize.width / 2,
            y: min(rect.maxY + 8, bounds.height - labelSize.height - 8)
        )
        let labelRect = NSRect(origin: labelOrigin, size: labelSize)

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: labelSize.height / 2, yRadius: labelSize.height / 2).fill()

        let textOrigin = NSPoint(
            x: labelRect.midX - textSize.width / 2,
            y: labelRect.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func drawHintBar() {
        let hint = L10n.t(.screenshotHint)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (hint as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 16, height: 8)
        let barSize = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let barOrigin = NSPoint(
            x: bounds.midX - barSize.width / 2,
            y: bounds.maxY - barSize.height - 48
        )
        let barRect = NSRect(origin: barOrigin, size: barSize)

        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barSize.height / 2, yRadius: barSize.height / 2).fill()

        let textOrigin = NSPoint(
            x: barRect.midX - textSize.width / 2,
            y: barRect.midY - textSize.height / 2
        )
        (hint as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: isSmartCapture ? .crosshair : .arrow)
    }

    override var acceptsFirstResponder: Bool { true }
}
