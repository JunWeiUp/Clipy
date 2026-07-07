import AppKit

enum CaptureOverlayRequest {
    case cancel
    case region(NSRect)
    case window(CGWindowID, NSRect)
}

private enum CapturePostAction {
    case none
    case pin
    case ocr
}

enum CaptureOverlayPhase {
    case selecting
    case adjusting
}

final class CaptureOverlayController: NSObject {
    private let mode: ScreenshotCaptureMode
    private let onComplete: (NSRect?) -> Void
    private var pendingCaptureRect: NSRect = .zero
    private var pendingPostAction: CapturePostAction = .none
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var toolbarPanel: CaptureSelectionToolbarPanel?
    private var annotationPanel: CaptureAnnotationPanel?
    private let annotationModel = AnnotationCanvasModel()
    private var magnifier = CaptureMagnifierController()
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var keyCommandMonitor: Any?
    private var isFinished = false
    private var hasStartedCapture = false
    private var currentSelectionRect: NSRect = .zero
    private var allowsSelectionAdjustment = true
    private var isOverlayPointerActive = false
    private var isAnnotationTextEditing = false
    private let annotationPanelEdgeInset: CGFloat = 10
    private var annotationComposeSize: NSSize = .zero

    init(mode: ScreenshotCaptureMode, onComplete: @escaping (NSRect?) -> Void) {
        self.mode = mode
        self.onComplete = onComplete
        super.init()
    }

    func present() {
        for screen in NSScreen.screens {
            let window = CaptureOverlayWindow(screen: screen, mode: mode) { [weak self] request in
                self?.handleCaptureRequest(request)
            }
            window.bindSelectionHandlers(
                ready: { [weak self] rect in self?.handleSelectionReady(rect) },
                changed: { [weak self] rect in self?.handleSelectionChanged(rect) },
                confirm: { [weak self] rect in self?.confirmCapture(rect: rect) },
                reset: { [weak self] in self?.hideToolbar() },
                pointerActiveChanged: { [weak self] active in self?.isOverlayPointerActive = active }
            )
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

        keyCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isFinished, self.toolbarPanel != nil else { return event }
            if self.isAnnotationTextEditing {
                return event
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                if event.modifierFlags.contains(.shift) {
                    self.annotationModel.redo()
                } else {
                    self.annotationModel.undo()
                }
                self.annotationPanel?.canvasView.needsDisplay = true
                return nil
            }
            return event
        }
    }

    private func forwardEvent(_ event: NSEvent) {
        guard !isFinished else { return }

        let mouseLocation = NSEvent.mouseLocation
        let mouseOnToolbar = toolbarPanel?.frame.contains(mouseLocation) == true
        let shouldForwardToOverlayDespiteToolbar = shouldForwardOverlayEvent(event)

        if let annotationPanel,
           !annotationPanel.ignoresMouseEvents,
           annotationPanel.frame.contains(mouseLocation),
           !shouldForwardToOverlayDespiteToolbar {
            annotationPanel.handle(event: event)
            return
        }

        if isAnnotationTextEditing, event.type == .keyDown {
            annotationPanel?.handle(event: event)
            return
        }

        if mouseOnToolbar && !shouldForwardToOverlayDespiteToolbar {
            if event.type == .keyDown {
                toolbarPanel?.keyDown(with: event)
            }
            return
        }

        if event.type == .mouseMoved, mode != .fullscreen, toolbarPanel == nil {
            magnifier.update(at: NSEvent.mouseLocation)
        }

        guard let window = overlayWindows.first(where: { $0.screenFrame.contains(NSEvent.mouseLocation) }) ?? overlayWindows.first else {
            return
        }
        window.handle(event: event)
    }

    private func shouldForwardOverlayEvent(_ event: NSEvent) -> Bool {
        guard toolbarPanel != nil else { return false }

        switch event.type {
        case .leftMouseDragged, .leftMouseUp:
            return isOverlayPointerActive
        case .mouseMoved:
            if allowsSelectionAdjustment {
                return currentSelectionRect.width > 0 && currentSelectionRect.height > 0
            }
            return isNearSelectionResizeEdge(NSEvent.mouseLocation)
        default:
            return false
        }
    }

    private func isNearSelectionResizeEdge(_ point: NSPoint) -> Bool {
        guard currentSelectionRect.width > 0, currentSelectionRect.height > 0 else { return false }
        let hitSize = annotationPanelEdgeInset
        let rect = currentSelectionRect
        guard rect.insetBy(dx: -hitSize, dy: -hitSize).contains(point) else { return false }
        return abs(point.x - rect.minX) <= hitSize
            || abs(point.x - rect.maxX) <= hitSize
            || abs(point.y - rect.minY) <= hitSize
            || abs(point.y - rect.maxY) <= hitSize
    }

    private func handleSelectionReady(_ rect: NSRect) {
        currentSelectionRect = rect
        magnifier.dismiss()
        annotationModel.selectedTool = .selection
        annotationModel.lineWidth = ScreenshotAnnotationTool.selection.defaultLineWidth
        setOverlayPhase(.adjusting)
        setAllowsSelectionAdjustment(true)
        showToolbar(for: rect)
        showAnnotationLayer(for: rect)
    }

    private func handleSelectionChanged(_ rect: NSRect) {
        currentSelectionRect = rect
        repositionToolbar(for: rect)
        repositionAnnotationLayer(for: rect)
    }

    private func setOverlayPhase(_ phase: CaptureOverlayPhase) {
        overlayWindows.forEach { $0.setPhase(phase) }
    }

    private func setAllowsSelectionAdjustment(_ allowed: Bool) {
        allowsSelectionAdjustment = allowed
        overlayWindows.forEach { $0.setAllowsSelectionAdjustment(allowed) }
        overlayWindows.forEach { $0.refreshSelectionCursor() }
    }

    private func showToolbar(for selectionRect: NSRect) {
        let panel = toolbarPanel ?? CaptureSelectionToolbarPanel()
        panel.toolbarDelegate = self
        toolbarPanel = panel
        panel.bind(model: annotationModel, canvasView: annotationPanel?.canvasView)
        panel.setSelectionToolActive(true)
        panel.updateLineWidthLabel()
        repositionToolbar(for: selectionRect)
        panel.orderFrontRegardless()
    }

    private func annotationPanelFrame(for selectionRect: NSRect) -> NSRect {
        let maxInset = min(
            annotationPanelEdgeInset,
            max(0, selectionRect.width / 2 - 4),
            max(0, selectionRect.height / 2 - 4)
        )
        return selectionRect.insetBy(dx: maxInset, dy: maxInset)
    }

    private func showAnnotationLayer(for selectionRect: NSRect) {
        let frame = annotationLayerFrame(for: selectionRect)
        annotationComposeSize = frame.size
        let panel = annotationPanel ?? CaptureAnnotationPanel(model: annotationModel, size: frame.size)
        annotationPanel = panel
        panel.reposition(to: frame)
        panel.setInteractionEnabled(false)
        panel.canvasView.onTextEditingChanged = { [weak self] editing in
            self?.isAnnotationTextEditing = editing
        }
        toolbarPanel?.bind(model: annotationModel, canvasView: panel.canvasView)
        panel.orderFrontRegardless()
    }

    private func repositionAnnotationLayer(for selectionRect: NSRect) {
        let frame = annotationLayerFrame(for: selectionRect)
        annotationComposeSize = frame.size
        annotationPanel?.reposition(to: frame)
    }

    private func annotationLayerFrame(for selectionRect: NSRect) -> NSRect {
        if allowsSelectionAdjustment {
            return annotationPanelFrame(for: selectionRect)
        }
        return selectionRect
    }

    private func hideAnnotationLayer() {
        isAnnotationTextEditing = false
        annotationPanel?.orderOut(nil)
        annotationPanel = nil
    }

    private func repositionToolbar(for selectionRect: NSRect) {
        guard let toolbarPanel else { return }
        let placement = ScreenshotToolbarPlacement.compute(
            screenRect: selectionRect,
            barHeight: ScreenshotChrome.barHeight,
            minPanelWidth: 720
        )
        toolbarPanel.setFrame(placement.toolbarFrame, display: true)
    }

    private func hideToolbar() {
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        hideAnnotationLayer()
        isOverlayPointerActive = false
        setOverlayPhase(.selecting)
        setAllowsSelectionAdjustment(true)
    }

    private func confirmCapture(rect: NSRect) {
        guard !hasStartedCapture else { return }
        hasStartedCapture = true
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        hideAnnotationLayer()
        submit(.region(rect))
    }

    private func handleCaptureRequest(_ request: CaptureOverlayRequest) {
        guard !isFinished else { return }

        switch request {
        case .cancel:
            finish(screenRect: nil)
        case .region, .window:
            magnifier.dismiss()
            toolbarPanel?.orderOut(nil)
            hideAnnotationLayer()
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
        switch request {
        case .cancel:
            finish(screenRect: nil)
        case .region(let rect):
            pendingCaptureRect = rect
            ScreenshotCaptureService.capture(rect: rect) { [weak self] image in
                guard let self else { return }
                autoreleasepool {
                    guard let image else {
                        self.finish(screenRect: nil)
                        return
                    }
                    let composeSize = self.annotationComposeSize.width > 0
                        ? self.annotationComposeSize
                        : image.size
                    let flattened = AnnotationCanvasView.flatten(
                        baseImage: image,
                        model: self.annotationModel,
                        composeSize: composeSize
                    ) ?? image
                    guard let pngData = ScreenshotImageProcessor.pngData(from: flattened, logicalSize: image.size) else {
                        self.finish(screenRect: self.pendingCaptureRect)
                        return
                    }
                    self.exportAndPostAction(pngData: pngData, image: flattened, logicalSize: image.size)
                    self.finish(screenRect: self.pendingCaptureRect)
                }
            }
        case .window(let windowID, let rect):
            pendingCaptureRect = rect
            ScreenshotCaptureService.capture(windowID: windowID) { [weak self] image in
                guard let self else { return }
                autoreleasepool {
                    guard let image else {
                        self.finish(screenRect: nil)
                        return
                    }
                    guard let pngData = ScreenshotImageProcessor.pngData(from: image, logicalSize: image.size) else {
                        self.finish(screenRect: self.pendingCaptureRect)
                        return
                    }
                    ScreenshotExport.exportPNG(pngData, image: image, logicalSize: image.size)
                    self.finish(screenRect: self.pendingCaptureRect)
                }
            }
        }
    }

    private func exportAndPostAction(pngData: Data, image: NSImage, logicalSize: NSSize) {
        switch pendingPostAction {
        case .none:
            ScreenshotExport.exportPNG(pngData, image: image, logicalSize: logicalSize)
        case .pin:
            ScreenshotExport.exportPNG(pngData, image: image, logicalSize: logicalSize)
            ScreenshotExport.pin(image: image, at: pendingCaptureRect, skipIngest: true)
        case .ocr:
            ScreenshotExport.exportPNG(pngData, image: image, logicalSize: logicalSize)
            ScreenshotExport.runOCR(on: image) { text in
                if let text, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        pendingPostAction = .none
    }

    private func finish(screenRect: NSRect?) {
        guard !isFinished else { return }
        isFinished = true
        annotationModel.resetSession()
        magnifier.dismiss()
        toolbarPanel?.close()
        toolbarPanel = nil
        annotationPanel?.close()
        annotationPanel = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let keyCommandMonitor {
            NSEvent.removeMonitor(keyCommandMonitor)
            self.keyCommandMonitor = nil
        }
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
        onComplete(screenRect)
    }

    func cancel() {
        finish(screenRect: nil)
    }
}

extension CaptureOverlayController: CaptureSelectionToolbarDelegate {
    func captureToolbarDidSelectSelectionTool() {
        annotationModel.selectedTool = .selection
        setAllowsSelectionAdjustment(true)
        toolbarPanel?.setSelectionToolActive(true)
        annotationPanel?.setInteractionEnabled(false)
        repositionAnnotationLayer(for: currentSelectionRect)
    }

    func captureToolbarDidSelectAnnotationTool(_ tool: ScreenshotAnnotationTool) {
        annotationModel.selectedTool = tool
        annotationModel.lineWidth = tool.defaultLineWidth
        setAllowsSelectionAdjustment(false)
        toolbarPanel?.setAnnotationToolActive(tool)
        toolbarPanel?.updateLineWidthLabel()
        annotationPanel?.setInteractionEnabled(true)
        repositionAnnotationLayer(for: currentSelectionRect)
    }

    func captureToolbarDidConfirm() {
        pendingPostAction = .none
        confirmCapture(rect: currentSelectionRect)
    }

    func captureToolbarDidCancel() {
        submit(.cancel)
    }

    func captureToolbarDidPin() {
        pendingPostAction = .pin
        confirmCapture(rect: currentSelectionRect)
    }

    func captureToolbarDidOCR() {
        pendingPostAction = .ocr
        confirmCapture(rect: currentSelectionRect)
    }

    func captureToolbarDidUndo() {
        annotationModel.undo()
        annotationPanel?.canvasView.needsDisplay = true
    }

    func captureToolbarDidRedo() {
        annotationModel.redo()
        annotationPanel?.canvasView.needsDisplay = true
    }

    private func submit(_ request: CaptureOverlayRequest) {
        handleCaptureRequest(request)
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

    func bindSelectionHandlers(
        ready: @escaping (NSRect) -> Void,
        changed: @escaping (NSRect) -> Void,
        confirm: @escaping (NSRect) -> Void,
        reset: @escaping () -> Void,
        pointerActiveChanged: @escaping (Bool) -> Void
    ) {
        overlayView.onSelectionReady = ready
        overlayView.onSelectionChanged = changed
        overlayView.onConfirmSelection = confirm
        overlayView.onBeginNewSelection = reset
        overlayView.onPointerActiveChanged = pointerActiveChanged
    }

    func setPhase(_ phase: CaptureOverlayPhase) {
        overlayView.phase = phase
        overlayView.window?.invalidateCursorRects(for: overlayView)
    }

    func setAllowsSelectionAdjustment(_ allowed: Bool) {
        overlayView.allowsSelectionAdjustment = allowed
        overlayView.window?.invalidateCursorRects(for: overlayView)
    }

    func refreshSelectionCursor() {
        overlayView.refreshSelectionCursor()
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
    private var pendingSnapRect: NSRect = .zero
    private var pendingWindowID: CGWindowID?
    private var pendingHighlightSource: UIElementDetectSource?
    private var dragInteraction: DragInteraction?
    private var isPointerActive = false
    private var activeCursor: NSCursor?

    var phase: CaptureOverlayPhase = .selecting
    var allowsSelectionAdjustment = true
    var onSelectionReady: ((NSRect) -> Void)?
    var onSelectionChanged: ((NSRect) -> Void)?
    var onConfirmSelection: ((NSRect) -> Void)?
    var onBeginNewSelection: (() -> Void)?
    var onPointerActiveChanged: ((Bool) -> Void)?

    private let clickDragThreshold: CGFloat = 4
    private let resizeHitSize: CGFloat = 8
    private let minimumSelectionSize: CGFloat = 8

    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let top = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }

    private enum DragInteraction {
        case drawing(start: NSPoint, snapTarget: NSRect?)
        case moving(start: NSPoint, original: NSRect)
        case resizing(start: NSPoint, original: NSRect, edges: ResizeEdges)
    }

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
            if isSmartCapture {
                if dragInteraction == nil, selectionRect.isEmpty, phase == .selecting {
                    updateElementHighlight(at: screenPoint(for: point))
                    needsDisplay = true
                }
                updateSelectionCursor(at: point)
            }
        case .leftMouseDown:
            handleLeftMouseDown(event, at: point)
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
        case 36:
            if phase == .adjusting {
                onConfirmSelection?(globalRect(from: selectionRect))
            } else {
                enterAdjustingPhaseIfNeeded()
            }
        default: break
        }
        notifySelectionChangedIfNeeded()
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
            selectionRect.size.width = max(minimumSelectionSize, selectionRect.size.width)
            selectionRect.size.height = max(minimumSelectionSize, selectionRect.size.height)
        } else {
            selectionRect.origin.x += dx
            selectionRect.origin.y += dy
        }
        isAdjustingSelection = true
        showHint = false
        enterAdjustingPhaseIfNeeded()
        notifySelectionChangedIfNeeded()
        needsDisplay = true
    }

    private func handleLeftMouseDown(_ event: NSEvent, at point: NSPoint) {
        guard isSmartCapture else { return }

        if event.clickCount >= 2, phase == .adjusting, selectionRect.contains(point) {
            onConfirmSelection?(globalRect(from: selectionRect))
            return
        }

        if phase == .adjusting,
           selectionRect.width > 0,
           selectionRect.height > 0 {
            let edges = resizeEdges(at: point, in: selectionRect)
            if !edges.isEmpty {
                dragInteraction = .resizing(start: point, original: selectionRect, edges: edges)
                setPointerActive(true)
                showHint = false
                applyCursor(resizeCursor(for: edges))
                needsDisplay = true
                return
            }
            if allowsSelectionAdjustment,
               selectionRect.insetBy(dx: -1, dy: -1).contains(point) {
                dragInteraction = .moving(start: point, original: selectionRect)
                setPointerActive(true)
                showHint = false
                applyCursor(.closedHand)
                needsDisplay = true
                return
            }
        }

        if phase == .adjusting, allowsSelectionAdjustment {
            if !isPointInSelectionInteractionArea(point) {
                beginNewSelection(at: point)
            }
            return
        }

        if phase == .adjusting {
            return
        }

        dragStart = point
        pendingSnapRect = highlightedBounds
        pendingWindowID = highlightedWindowID
        pendingHighlightSource = highlightSource
        dragInteraction = .drawing(
            start: point,
            snapTarget: highlightedBounds.width > 0 ? globalRect(from: highlightedBounds) : nil
        )
        setPointerActive(true)
        selectionRect = .zero
        showHint = false
        needsDisplay = true
    }

    private func isPointInSelectionInteractionArea(_ point: NSPoint) -> Bool {
        guard selectionRect.width > minimumSelectionSize,
              selectionRect.height > minimumSelectionSize else {
            return false
        }
        if !resizeEdges(at: point, in: selectionRect).isEmpty {
            return true
        }
        return selectionRect.insetBy(dx: -1, dy: -1).contains(point)
    }

    private func handleLeftMouseDragged(at point: NSPoint) {
        guard isSmartCapture, let dragInteraction else { return }

        switch dragInteraction {
        case .drawing(let start, let snapTarget):
            if !hasStartedDragging,
               hypot(point.x - start.x, point.y - start.y) > clickDragThreshold {
                hasStartedDragging = true
                highlightedBounds = .zero
                highlightSource = nil
                highlightedWindowID = nil
            }

            guard hasStartedDragging else { return }

            var rect = normalizedRect(from: start, to: point)
            if let snapTarget {
                rect = UIElementDetector.snapRect(rect, to: localRect(from: snapTarget))
            }
            selectionRect = clampedSelection(rect)
        case .moving(let start, let original):
            applyCursor(.closedHand)
            let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
            selectionRect = clampedSelection(
                NSRect(
                    x: original.origin.x + delta.x,
                    y: original.origin.y + delta.y,
                    width: original.width,
                    height: original.height
                )
            )
        case .resizing(_, let original, let edges):
            applyCursor(resizeCursor(for: edges))
            selectionRect = resizedSelection(original, to: point, edges: edges)
        }

        isAdjustingSelection = true
        notifySelectionChangedIfNeeded()
        needsDisplay = true
    }

    private func handleLeftMouseUp(at point: NSPoint) {
        guard isSmartCapture, let dragInteraction else { return }
        dragStart = nil

        switch dragInteraction {
        case .drawing(let start, let snapTarget):
            if !hasStartedDragging,
               hypot(point.x - start.x, point.y - start.y) <= clickDragThreshold {
                if pendingSnapRect.width > 0 {
                    if mode == .window,
                       let windowID = pendingWindowID,
                       pendingHighlightSource == .window {
                        clearPendingSnap()
                        submit(.window(windowID, globalRect(from: pendingSnapRect)))
                        return
                    }
                    selectionRect = clampedSelection(pendingSnapRect)
                    highlightedBounds = .zero
                    highlightSource = nil
                    highlightedWindowID = nil
                } else {
                    selectionRect = .zero
                }
            } else {
                var rect = normalizedRect(from: start, to: point)
                if let snapTarget {
                    rect = UIElementDetector.snapRect(rect, to: localRect(from: snapTarget))
                }
                selectionRect = clampedSelection(rect)
            }
        case .moving, .resizing:
            break
        }

        clearPendingSnap()
        isAdjustingSelection = selectionRect.width > 0 && selectionRect.height > 0
        enterAdjustingPhaseIfNeeded()
        notifySelectionChangedIfNeeded()
        updateSelectionCursor(at: point)
        needsDisplay = true
    }

    private func beginNewSelection(at point: NSPoint) {
        phase = .selecting
        onBeginNewSelection?()
        dragStart = point
        pendingSnapRect = .zero
        pendingWindowID = nil
        pendingHighlightSource = nil
        dragInteraction = .drawing(start: point, snapTarget: nil)
        setPointerActive(true)
        selectionRect = .zero
        hasStartedDragging = false
        showHint = false
        needsDisplay = true
    }

    private func enterAdjustingPhaseIfNeeded() {
        guard selectionRect.width > minimumSelectionSize,
              selectionRect.height > minimumSelectionSize else {
            return
        }

        let wasSelecting = phase == .selecting
        phase = .adjusting
        showHint = false
        let global = globalRect(from: selectionRect)
        if wasSelecting {
            onSelectionReady?(global)
        } else {
            onSelectionChanged?(global)
        }
    }

    private func notifySelectionChangedIfNeeded() {
        guard phase == .adjusting,
              selectionRect.width > minimumSelectionSize,
              selectionRect.height > minimumSelectionSize else {
            return
        }
        onSelectionChanged?(globalRect(from: selectionRect))
    }

    private func clearPendingSnap() {
        pendingSnapRect = .zero
        pendingWindowID = nil
        pendingHighlightSource = nil
        dragInteraction = nil
        hasStartedDragging = false
        setPointerActive(false)
    }

    private func setPointerActive(_ active: Bool) {
        guard isPointerActive != active else { return }
        isPointerActive = active
        onPointerActiveChanged?(active)
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
            elementSnapEnabled: true,
            preferWindow: mode == .region
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

    private func resizeEdges(at point: NSPoint, in rect: NSRect) -> ResizeEdges {
        guard rect.insetBy(dx: -resizeHitSize, dy: -resizeHitSize).contains(point) else {
            return []
        }

        var edges: ResizeEdges = []
        if abs(point.x - rect.minX) <= resizeHitSize {
            edges.insert(.left)
        }
        if abs(point.x - rect.maxX) <= resizeHitSize {
            edges.insert(.right)
        }
        if abs(point.y - rect.minY) <= resizeHitSize {
            edges.insert(.bottom)
        }
        if abs(point.y - rect.maxY) <= resizeHitSize {
            edges.insert(.top)
        }
        return edges
    }

    private func resizedSelection(_ original: NSRect, to point: NSPoint, edges: ResizeEdges) -> NSRect {
        var rect = original

        if edges.contains(.left) {
            let minX = min(original.maxX - minimumSelectionSize, max(bounds.minX, point.x))
            rect.origin.x = minX
            rect.size.width = original.maxX - minX
        }
        if edges.contains(.right) {
            let maxX = max(original.minX + minimumSelectionSize, min(bounds.maxX, point.x))
            rect.size.width = maxX - original.minX
        }
        if edges.contains(.bottom) {
            let minY = min(original.maxY - minimumSelectionSize, max(bounds.minY, point.y))
            rect.origin.y = minY
            rect.size.height = original.maxY - minY
        }
        if edges.contains(.top) {
            let maxY = max(original.minY + minimumSelectionSize, min(bounds.maxY, point.y))
            rect.size.height = maxY - original.minY
        }

        return clampedSelection(rect)
    }

    private func clampedSelection(_ rect: NSRect) -> NSRect {
        var result = rect.standardized
        result.size.width = min(max(result.width, minimumSelectionSize), bounds.width)
        result.size.height = min(max(result.height, minimumSelectionSize), bounds.height)
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private func completeRegionCapture() {
        guard selectionRect.width > minimumSelectionSize,
              selectionRect.height > minimumSelectionSize else {
            selectionRect = .zero
            isAdjustingSelection = false
            hasStartedDragging = false
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
        } else if !hasStartedDragging {
            let previewRect = dragStart == nil ? highlightedBounds : pendingSnapRect
            if previewRect.width > 0 {
                drawElementHighlight(in: previewRect)
            }
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
        if phase == .adjusting {
            drawSelectionHint(for: rect)
        }
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

    private func drawSelectionHint(for rect: NSRect) {
        let text = L10n.t(.screenshotSelectionHint)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 12, height: 5)
        let labelSize = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let y = rect.minY - labelSize.height - 8 > bounds.minY + 8
            ? rect.minY - labelSize.height - 8
            : min(rect.maxY + 32, bounds.maxY - labelSize.height - 8)
        let labelRect = NSRect(
            x: min(max(rect.midX - labelSize.width / 2, bounds.minX + 8), bounds.maxX - labelSize.width - 8),
            y: y,
            width: labelSize.width,
            height: labelSize.height
        )

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
        guard isSmartCapture else {
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        if phase == .adjusting,
           selectionRect.width > minimumSelectionSize,
           selectionRect.height > minimumSelectionSize {
            return
        }
        addCursorRect(bounds, cursor: .crosshair)
    }

    func refreshSelectionCursor() {
        let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        updateSelectionCursor(at: point)
    }

    private func updateSelectionCursor(at point: NSPoint) {
        guard isSmartCapture else {
            applyCursor(.arrow)
            return
        }

        if let dragInteraction {
            switch dragInteraction {
            case .drawing:
                applyCursor(.crosshair)
            case .moving:
                applyCursor(.closedHand)
            case .resizing(_, _, let edges):
                applyCursor(resizeCursor(for: edges))
            }
            return
        }

        if phase == .adjusting,
           selectionRect.width > minimumSelectionSize,
           selectionRect.height > minimumSelectionSize {
            let edges = resizeEdges(at: point, in: selectionRect)
            if !edges.isEmpty {
                applyCursor(resizeCursor(for: edges))
                return
            }
            if allowsSelectionAdjustment,
               selectionRect.insetBy(dx: -1, dy: -1).contains(point) {
                applyCursor(.openHand)
                return
            }
        }

        applyCursor(.crosshair)
    }

    private func applyCursor(_ cursor: NSCursor) {
        guard activeCursor !== cursor else { return }
        activeCursor = cursor
        cursor.set()
    }

    private func resizeCursor(for edges: ResizeEdges) -> NSCursor {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)

        if horizontal && vertical {
            let northwestSoutheast =
                (edges.contains(.left) && edges.contains(.top))
                || (edges.contains(.right) && edges.contains(.bottom))
            return northwestSoutheast ? Self.resizeNorthwestSoutheastCursor : Self.resizeNortheastSouthwestCursor
        }
        if horizontal {
            return .resizeLeftRight
        }
        if vertical {
            return .resizeUpDown
        }
        return .crosshair
    }

    private static let resizeNorthwestSoutheastCursor = diagonalResizeCursor(slope: .northwestSoutheast)
    private static let resizeNortheastSouthwestCursor = diagonalResizeCursor(slope: .northeastSouthwest)

    private enum DiagonalResizeSlope {
        case northwestSoutheast
        case northeastSouthwest
    }

    private static func diagonalResizeCursor(slope: DiagonalResizeSlope) -> NSCursor {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            let path = NSBezierPath()
            path.lineWidth = 1.5
            NSColor.black.setStroke()
            NSColor.white.setFill()

            switch slope {
            case .northwestSoutheast:
                path.move(to: NSPoint(x: 3, y: rect.maxY - 3))
                path.line(to: NSPoint(x: rect.maxX - 3, y: 3))
                path.move(to: NSPoint(x: 3, y: rect.maxY - 7))
                path.line(to: NSPoint(x: 7, y: rect.maxY - 3))
                path.move(to: NSPoint(x: rect.maxX - 7, y: 7))
                path.line(to: NSPoint(x: rect.maxX - 3, y: 11))
            case .northeastSouthwest:
                path.move(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
                path.line(to: NSPoint(x: 3, y: 3))
                path.move(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 7))
                path.line(to: NSPoint(x: rect.maxX - 7, y: rect.maxY - 3))
                path.move(to: NSPoint(x: 7, y: 7))
                path.line(to: NSPoint(x: 3, y: 11))
            }

            path.stroke()
            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }

    override var acceptsFirstResponder: Bool { true }
}
