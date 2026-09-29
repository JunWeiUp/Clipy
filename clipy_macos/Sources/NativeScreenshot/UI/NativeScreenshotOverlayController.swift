import AppKit
import CoreGraphics
import ScreenCaptureKit

enum NativeScreenshotSelectionMode {
    case region
    case window
    case fullscreen
}

struct NativeScreenshotOverlayCallbacks {
    var onConfirm: (NativeScreenshotCapturedImage) -> Void
    var onCancel: () -> Void
    var onRecordingRequested: (CGRect) -> Void
    var onScrollingRequested: (CGRect) -> Void
    var onOCRRequested: (NativeScreenshotCapturedImage) -> Void
    var onQRCodeRequested: (NativeScreenshotCapturedImage) -> Void
    var onAutoRedactRequested: (NativeScreenshotCapturedImage) -> Void
    var onPinRequested: (NativeScreenshotCapturedImage) -> Void
    var onSaveRequested: (NativeScreenshotCapturedImage) -> Void
    var onQuickCapture: (NativeScreenshotCapturedImage, Int) -> Void
    var onError: (Error) -> Void
}

enum NativeScreenshotDeliveryAction {
    case confirm, ocr, qrCode, autoRedact, pin, save
}

/// Owns temporary selection windows and one editor. Create it for one user
/// gesture, then release it after a terminal callback.
@MainActor
@available(macOS 13.0, *)
final class NativeScreenshotOverlayController {
    fileprivate static var quickCaptureTitle: String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
        let chinese = raw == "zh" || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        return chinese ? "快速捕获" : "Quick Capture"
    }
    private struct DisplaySnapshot {
        let screen: NSScreen
        let display: SCDisplay
        let capture: NativeScreenshotCapturedImage
    }

    private enum RegionDrag {
        case create(start: CGPoint)
        case move(original: CGRect, start: CGPoint)
        case resize(original: CGRect, start: CGPoint, edges: NativeScreenshotResizeEdges)
    }

    private let mode: NativeScreenshotSelectionMode
    private let callbacks: NativeScreenshotOverlayCallbacks
    private let capture = NativeScreenshotStaticCapture()
    private let originalFrontmostApp: NSRunningApplication?
    private var snapshots: [DisplaySnapshot] = []
    private var panels: [NativeScreenshotSelectionPanel] = []
    private var actionPanel: NativeScreenshotActionPanel?
    private var editor: NativeScreenshotEditorController?
    private var orderedWindows: [SCWindow] = []
    private var selectedRect: CGRect?
    private var selectedWindowID: CGWindowID?
    private var regionDrag: RegionDrag?
    private var dragMoved = false
    private var hoveredElement: CGRect?
    private var guideX: CGFloat?
    private var guideY: CGFloat?
    private var hoveredPoint: CGPoint?
    private let preferences = PreferencesManager.shared
    private var delivering = false
    private var finished = false

    init(
        mode: NativeScreenshotSelectionMode,
        restoreApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        callbacks: NativeScreenshotOverlayCallbacks
    ) {
        self.mode = mode
        self.callbacks = callbacks
        originalFrontmostApp = restoreApplication
    }

    func start() async {
        guard !finished else { return }
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw NativeScreenshotCaptureError.screenRecordingPermissionRequired
            }
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            orderedWindows = Self.windowsInFrontToBackOrder(content.windows)
            let screens = NSScreen.screens
            for display in content.displays {
                try Task.checkCancellation()
                guard let screen = screens.first(where: { Self.displayID(for: $0) == display.displayID }) else {
                    continue
                }
                let captured = try await capture.captureDisplay(displayID: display.displayID)
                snapshots.append(DisplaySnapshot(screen: screen, display: display, capture: captured))
            }
            guard !snapshots.isEmpty else { throw NativeScreenshotCaptureError.displayNotFound }
            guard !finished else { return }
            showSelectionPanels()
        } catch {
            guard !finished else { return }
            finish(restoreFocus: true)
            callbacks.onError(error)
        }
    }

    func cancel() {
        guard !finished else { return }
        capture.cancel()
        finish(restoreFocus: true)
        callbacks.onCancel()
    }

    private func showSelectionPanels() {
        for snapshot in snapshots {
            let panel = NativeScreenshotSelectionPanel(
                contentRect: snapshot.screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.onEscape = { [weak self] in self?.cancel() }
            panel.onReturn = { [weak self] in self?.confirmSelection() }

            let view = NativeScreenshotSelectionView(
                image: snapshot.capture.image,
                displayFrame: snapshot.display.frame
            )
            view.onMouseDown = { [weak self] point in self?.pointerDown(at: point, display: snapshot.display) }
            view.onMouseDrag = { [weak self] point in self?.pointerDragged(to: point) }
            view.onMouseUp = { [weak self] point in self?.pointerUp(at: point, display: snapshot.display) }
            view.onMouseMove = { [weak self] point in self?.pointerMoved(to: point, display: snapshot.display) }
            view.onConfirm = { [weak self] in self?.confirmSelection() }
            view.showsMagnifier = preferences.isScreenshotMagnifierEnabled
            view.elementSnapHint = preferences.isScreenshotElementSnapEnabled && !AXIsProcessTrusted()
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first?.makeKeyAndOrderFront(nil)
        updateSelectionViews()
    }

    private func pointerDown(at point: CGPoint, display: SCDisplay) {
        actionPanel?.orderOut(nil)
        actionPanel = nil
        hoveredPoint = point
        hoveredElement = elementRect(at: point)
        switch mode {
        case .region:
            dragMoved = false
            if let selectedRect {
                let edges = NativeScreenshotResizeEdges.near(point, rect: selectedRect)
                if !edges.isEmpty {
                    regionDrag = .resize(original: selectedRect, start: point, edges: edges)
                } else if selectedRect.contains(point) {
                    regionDrag = .move(original: selectedRect, start: point)
                } else {
                    regionDrag = .create(start: point)
                }
            } else {
                regionDrag = .create(start: point)
            }
        case .window:
            let window = window(at: point)
            selectedRect = window?.frame
            selectedWindowID = window?.windowID
        case .fullscreen:
            selectedRect = display.frame
        }
        updateSelectionViews()
    }

    private func pointerDragged(to point: CGPoint) {
        guard mode == .region, let regionDrag else { return }
        hoveredPoint = point
        hoveredElement = elementRect(at: point)
        if case let .create(start) = regionDrag,
           hypot(point.x - start.x, point.y - start.y) >= 4 { dragMoved = true }
        switch regionDrag {
        case let .create(start):
            let horizontal: NativeScreenshotResizeEdges = point.x < start.x ? .left : .right
            let vertical: NativeScreenshotResizeEdges = point.y < start.y ? .top : .bottom
            selectedRect = snapped(Self.rect(between: start, and: point), moving: [horizontal, vertical])
        case let .move(original, start):
            selectedRect = snapped(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), moving: [.left, .right, .top, .bottom])
        case let .resize(original, start, edges):
            selectedRect = snapped(edges.resized(original, from: start, to: point), moving: edges)
        }
        updateSelectionViews()
    }

    private func pointerUp(at point: CGPoint, display: SCDisplay) {
        switch mode {
        case .region:
            pointerDragged(to: point)
            regionDrag = nil
            if !dragMoved, preferences.isScreenshotElementSnapEnabled,
               let candidate = hoveredElement, candidate.contains(point) {
                selectedRect = candidate
            }
            guard let selectedRect, selectedRect.width >= 4, selectedRect.height >= 4 else {
                self.selectedRect = nil
                updateSelectionViews()
                return
            }
        case .window:
            guard selectedWindowID != nil else { return }
        case .fullscreen:
            selectedRect = display.frame
        }
        guideX = nil
        guideY = nil
        updateSelectionViews()
        showActionPanel()
    }

    private func pointerMoved(to point: CGPoint, display: SCDisplay) {
        hoveredPoint = point
        hoveredElement = elementRect(at: point)
        if actionPanel != nil { updateSelectionViews(); return }
        switch mode {
        case .region: break
        case .window: selectedRect = window(at: point)?.frame
        case .fullscreen: selectedRect = display.frame
        }
        updateSelectionViews()
    }

    private func window(at point: CGPoint) -> SCWindow? {
        orderedWindows.first { $0.frame.contains(point) && $0.frame.width > 8 && $0.frame.height > 8 }
    }

    /// Hit-test the application that was frontmost before the overlay appeared.
    /// Looking up the system-wide element here would select the overlay itself.
    private func elementRect(at point: CGPoint) -> CGRect? {
        guard mode == .region, preferences.isScreenshotElementSnapEnabled,
              AXIsProcessTrusted(), let app = originalFrontmostApp, !app.isTerminated else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current else { break }
            var originValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &originValue) == .success,
               AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeValue) == .success,
               let originValue, let sizeValue,
               CFGetTypeID(originValue) == AXValueGetTypeID(),
               CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                var origin = CGPoint.zero
                var size = CGSize.zero
                if AXValueGetValue(originValue as! AXValue, .cgPoint, &origin),
                   AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                    let rect = CGRect(origin: origin, size: size).standardized
                    if rect.width >= 8, rect.height >= 8, rect.contains(point),
                       snapshots.contains(where: { $0.display.frame.intersects(rect) }) {
                        return rect
                    }
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private func snapped(_ rect: CGRect, moving: NativeScreenshotResizeEdges) -> CGRect {
        guard preferences.isScreenshotElementSnapEnabled || preferences.snapGuidesEnabled else {
            guideX = nil; guideY = nil
            return rect
        }
        var targets = orderedWindows.map(\.frame).filter { $0.width > 8 && $0.height > 8 }
        if let hoveredElement { targets.append(hoveredElement) }
        targets.append(contentsOf: snapshots.map { $0.display.frame })
        let result = NativeScreenshotSelectionSnap.snap(rect, moving: moving, targets: targets, tolerance: 7)
        guideX = preferences.snapGuidesEnabled ? result.guideX : nil
        guideY = preferences.snapGuidesEnabled ? result.guideY : nil
        return preferences.isScreenshotElementSnapEnabled ? result.rect : rect
    }

    private func updateSelectionViews() {
        for panel in panels {
            guard let view = panel.contentView as? NativeScreenshotSelectionView else { continue }
            view.selection = selectedRect
            view.hoveredElement = mode == .region ? hoveredElement : nil
            view.guideX = guideX
            view.guideY = guideY
            view.pointer = hoveredPoint
        }
    }

    private func showActionPanel() {
        guard selectedRect != nil else { return }
        let panel = NativeScreenshotActionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 528, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.installButtons(target: self)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        if let screen {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: max(area.minX, min(pointer.x - 264, area.maxX - 528)),
                y: max(area.minY, min(pointer.y - 102, area.maxY - 88))
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        actionPanel = panel
    }

    @objc fileprivate func annotateSelection() {
        Task { await prepareEditor() }
    }

    @objc fileprivate func confirmSelection() {
        guard selectedRect != nil else { return }
        Task { await deliverSelection(.confirm) }
    }

    @objc fileprivate func quickCaptureSelection() {
        guard selectedRect != nil, !delivering else { return }
        delivering = true
        Task {
            do {
                let image = try await selectedImage()
                guard !finished else { return }
                finish(restoreFocus: true)
                callbacks.onQuickCapture(image, preferences.quickCaptureMode)
            } catch {
                guard !finished else { return }
                finish(restoreFocus: true)
                callbacks.onError(error)
            }
        }
    }

    @objc fileprivate func requestOCR() { Task { await deliverSelection(.ocr) } }
    @objc fileprivate func requestQRCode() { Task { await deliverSelection(.qrCode) } }
    @objc fileprivate func requestAutoRedact() { Task { await deliverSelection(.autoRedact) } }
    @objc fileprivate func requestPin() { Task { await deliverSelection(.pin) } }
    @objc fileprivate func requestSave() { Task { await deliverSelection(.save) } }

    @objc fileprivate func requestRecording() {
        guard let selectedRect else { return }
        finish(restoreFocus: true)
        callbacks.onRecordingRequested(selectedRect)
    }

    @objc fileprivate func requestScrolling() {
        guard let selectedRect else { return }
        finish(restoreFocus: true)
        callbacks.onScrollingRequested(selectedRect)
    }

    @objc fileprivate func cancelFromButton() { cancel() }

    private func prepareEditor() async {
        guard !delivering else { return }
        delivering = true
        do {
            let base = try await selectedImage()
            guard !finished else { return }
            hideSelectionPanels()
            let editor = NativeScreenshotEditorController(
                base: base,
                onAction: { [weak self] action, result in
                    self?.deliver(result, action: action)
                },
                onCancel: { [weak self] in self?.cancel() }
            )
            self.editor = editor
            editor.show()
        } catch {
            guard !finished else { return }
            finish(restoreFocus: true)
            callbacks.onError(error)
        }
    }

    private func deliverSelection(_ action: NativeScreenshotDeliveryAction) async {
        guard !delivering else { return }
        delivering = true
        do {
            let image = try await selectedImage()
            deliver(image, action: action)
        } catch {
            guard !finished else { return }
            finish(restoreFocus: true)
            callbacks.onError(error)
        }
    }

    private func deliver(_ image: NativeScreenshotCapturedImage, action: NativeScreenshotDeliveryAction) {
        guard !finished else { return }
        finish(restoreFocus: true)
        switch action {
        case .confirm: callbacks.onConfirm(image)
        case .ocr: callbacks.onOCRRequested(image)
        case .qrCode: callbacks.onQRCodeRequested(image)
        case .autoRedact: callbacks.onAutoRedactRequested(image)
        case .pin: callbacks.onPinRequested(image)
        case .save: callbacks.onSaveRequested(image)
        }
    }

    private func selectedImage() async throws -> NativeScreenshotCapturedImage {
        guard let selectedRect else { throw NativeScreenshotCaptureError.invalidRegion }
        if mode == .window {
            guard let selectedWindowID else { throw NativeScreenshotCaptureError.windowNotFound }
            hideSelectionPanels()
            try await Task.sleep(nanoseconds: 80_000_000)
            return try await capture.captureWindow(windowID: selectedWindowID, showsCursor: preferences.captureCursor)
        }
        if preferences.captureCursor {
            hideSelectionPanels()
            try await Task.sleep(nanoseconds: 80_000_000)
            return try await capture.captureRegion(selectedRect, showsCursor: true)
        }
        let pieces = snapshots.map {
            NativeScreenshotCapturePiece(displayFrame: $0.display.frame, image: $0.capture.image)
        }
        let (image, scale) = try NativeScreenshotCaptureComposer.compose(
            region: selectedRect, pieces: pieces, maxOutputPixels: capture.maxOutputPixels
        )
        return NativeScreenshotCapturedImage(
            image: image, sourceRect: selectedRect, pixelsPerPoint: scale
        )
    }

    private func hideSelectionPanels() {
        actionPanel?.orderOut(nil)
        actionPanel = nil
        for panel in panels { panel.orderOut(nil) }
    }

    private func finish(restoreFocus: Bool) {
        guard !finished else { return }
        finished = true
        hideSelectionPanels()
        panels.removeAll()
        editor?.close()
        editor = nil
        snapshots.removeAll()
        orderedWindows.removeAll()
        if restoreFocus, let app = originalFrontmostApp, !app.isTerminated {
            app.activate(options: [])
        }
    }

    private static func rect(between a: CGPoint, and b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    private static func windowsInFrontToBackOrder(_ windows: [SCWindow]) -> [SCWindow] {
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let cgWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let ordered = cgWindows.compactMap { item -> SCWindow? in
            guard let number = item[kCGWindowNumber as String] as? NSNumber else { return nil }
            return byID[CGWindowID(number.uint32Value)]
        }
        return ordered.isEmpty ? windows : ordered
    }
}

private struct NativeScreenshotResizeEdges: OptionSet {
    let rawValue: UInt8
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let top = Self(rawValue: 4)
    static let bottom = Self(rawValue: 8)

    static func near(_ point: CGPoint, rect: CGRect) -> Self {
        let tolerance: CGFloat = 8
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return [] }
        var edges: Self = []
        if abs(point.x - rect.minX) <= tolerance { edges.insert(.left) }
        if abs(point.x - rect.maxX) <= tolerance { edges.insert(.right) }
        if abs(point.y - rect.minY) <= tolerance { edges.insert(.top) }
        if abs(point.y - rect.maxY) <= tolerance { edges.insert(.bottom) }
        return edges
    }

    func resized(_ original: CGRect, from start: CGPoint, to end: CGPoint) -> CGRect {
        let dx = end.x - start.x
        let dy = end.y - start.y
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if contains(.left) { minX = min(maxX - 4, minX + dx) }
        if contains(.right) { maxX = max(minX + 4, maxX + dx) }
        if contains(.top) { minY = min(maxY - 4, minY + dy) }
        if contains(.bottom) { maxY = max(minY + 4, maxY + dy) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private enum NativeScreenshotSelectionSnap {
    static func snap(
        _ source: CGRect,
        moving: NativeScreenshotResizeEdges,
        targets: [CGRect],
        tolerance: CGFloat
    ) -> (rect: CGRect, guideX: CGFloat?, guideY: CGFloat?) {
        var rect = source.standardized
        let xCandidates = targets.flatMap { [$0.minX, $0.maxX] }
        let yCandidates = targets.flatMap { [$0.minY, $0.maxY] }
        func nearest(_ value: CGFloat, in candidates: [CGFloat]) -> CGFloat? {
            candidates.filter { abs($0 - value) <= tolerance }
                .min { abs($0 - value) < abs($1 - value) }
        }
        var guideX: CGFloat?
        var guideY: CGFloat?
        if moving.contains(.left), moving.contains(.right) {
            let matches = [(rect.minX, nearest(rect.minX, in: xCandidates)),
                           (rect.maxX, nearest(rect.maxX, in: xCandidates))]
                .compactMap { value, match -> (CGFloat, CGFloat)? in
                    match.map { (value, $0) }
                }
            if let match = matches.min(by: { abs($0.0 - $0.1) < abs($1.0 - $1.1) }) {
                rect.origin.x += match.1 - match.0
                guideX = match.1
            }
        } else if moving.contains(.left), let match = nearest(rect.minX, in: xCandidates),
                  match <= rect.maxX - 4 {
            rect.size.width += rect.minX - match
            rect.origin.x = match
            guideX = match
        } else if moving.contains(.right), let match = nearest(rect.maxX, in: xCandidates),
                  match >= rect.minX + 4 {
            rect.size.width = match - rect.minX
            guideX = match
        }
        if moving.contains(.top), moving.contains(.bottom) {
            let matches = [(rect.minY, nearest(rect.minY, in: yCandidates)),
                           (rect.maxY, nearest(rect.maxY, in: yCandidates))]
                .compactMap { value, match -> (CGFloat, CGFloat)? in
                    match.map { (value, $0) }
                }
            if let match = matches.min(by: { abs($0.0 - $0.1) < abs($1.0 - $1.1) }) {
                rect.origin.y += match.1 - match.0
                guideY = match.1
            }
        } else if moving.contains(.top), let match = nearest(rect.minY, in: yCandidates),
                  match <= rect.maxY - 4 {
            rect.size.height += rect.minY - match
            rect.origin.y = match
            guideY = match
        } else if moving.contains(.bottom), let match = nearest(rect.maxY, in: yCandidates),
                  match >= rect.minY + 4 {
            rect.size.height = match - rect.minY
            guideY = match
        }
        return (rect, guideX, guideY)
    }
}

@available(macOS 13.0, *)
private class NativeScreenshotSelectionPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotActionPanel: NativeScreenshotSelectionPanel {
    func installButtons(target: NativeScreenshotOverlayController) {
        let background = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 528, height: 88))
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let primary: [(String, Selector)] = [
            (NativeScreenshotText.get(.annotate), #selector(NativeScreenshotOverlayController.annotateSelection)),
            (NativeScreenshotText.get(.record), #selector(NativeScreenshotOverlayController.requestRecording)),
            (NativeScreenshotText.get(.scroll), #selector(NativeScreenshotOverlayController.requestScrolling)),
            (NativeScreenshotText.get(.done), #selector(NativeScreenshotOverlayController.confirmSelection)),
            (NativeScreenshotOverlayController.quickCaptureTitle, #selector(NativeScreenshotOverlayController.quickCaptureSelection)),
            (NativeScreenshotText.get(.cancel), #selector(NativeScreenshotOverlayController.cancelFromButton))
        ]
        let secondary: [(String, Selector)] = [
            (NativeScreenshotText.get(.ocr), #selector(NativeScreenshotOverlayController.requestOCR)),
            (NativeScreenshotText.get(.qrCode), #selector(NativeScreenshotOverlayController.requestQRCode)),
            (NativeScreenshotText.get(.autoRedact), #selector(NativeScreenshotOverlayController.requestAutoRedact)),
            (NativeScreenshotText.get(.pin), #selector(NativeScreenshotOverlayController.requestPin)),
            (NativeScreenshotText.get(.save), #selector(NativeScreenshotOverlayController.requestSave))
        ]
        for (rowIndex, row) in [primary, secondary].enumerated() {
            let stack = NSStackView(frame: CGRect(x: 8, y: rowIndex == 0 ? 47 : 7,
                                                   width: 512, height: 34))
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fillEqually
            stack.spacing = 5
            for (title, action) in row {
                let button = NSButton(title: title, target: target, action: action)
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.toolTip = title
                stack.addArrangedSubview(button)
            }
            background.addSubview(stack)
        }
        contentView = background
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotSelectionView: NSView {
    let image: CGImage
    let displayFrame: CGRect
    var selection: CGRect? { didSet { needsDisplay = true } }
    var hoveredElement: CGRect? { didSet { needsDisplay = true } }
    var guideX: CGFloat? { didSet { needsDisplay = true } }
    var guideY: CGFloat? { didSet { needsDisplay = true } }
    var pointer: CGPoint? { didSet { needsDisplay = true } }
    var showsMagnifier = false
    var elementSnapHint = false
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDrag: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onMouseMove: ((CGPoint) -> Void)?
    var onConfirm: (() -> Void)?

    init(image: CGImage, displayFrame: CGRect) {
        self.image = image
        self.displayFrame = displayFrame
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        guard let selection,
              let visible = NativeScreenshotCaptureGeometry.intersection(selection, displayFrame: displayFrame) else {
            NSColor.black.withAlphaComponent(0.42).setFill()
            bounds.fill()
            drawAids()
            return
        }

        let cut = visible.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        NSColor.black.withAlphaComponent(0.48).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: max(0, cut.minY)).fill()
        CGRect(x: 0, y: cut.maxY, width: bounds.width, height: max(0, bounds.maxY - cut.maxY)).fill()
        CGRect(x: 0, y: cut.minY, width: max(0, cut.minX), height: cut.height).fill()
        CGRect(x: cut.maxX, y: cut.minY, width: max(0, bounds.maxX - cut.maxX), height: cut.height).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: cut)
        border.lineWidth = 2
        border.stroke()
        drawAids()
    }

    private func drawAids() {
        if let hoveredElement,
           let visible = NativeScreenshotCaptureGeometry.intersection(hoveredElement, displayFrame: displayFrame) {
            let rect = visible.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
        let guideColor = NSColor.systemYellow.withAlphaComponent(0.75)
        guideColor.setStroke()
        if let guideX, displayFrame.minX <= guideX, guideX <= displayFrame.maxX {
            let x = guideX - displayFrame.minX
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: 0))
            line.line(to: CGPoint(x: x, y: bounds.height))
            line.lineWidth = 1
            line.stroke()
        }
        if let guideY, displayFrame.minY <= guideY, guideY <= displayFrame.maxY {
            let y = guideY - displayFrame.minY
            let line = NSBezierPath()
            line.move(to: CGPoint(x: 0, y: y))
            line.line(to: CGPoint(x: bounds.width, y: y))
            line.lineWidth = 1
            line.stroke()
        }
        if elementSnapHint {
            let hint = NativeScreenshotSelectionView.isChinese
                ? "元素吸附需要辅助功能权限；仍可手动框选"
                : "Element snap needs Accessibility access; drag to select manually"
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: 12)
            ]
            (hint as NSString).draw(at: CGPoint(x: 14, y: 14), withAttributes: attributes)
        }
        guard showsMagnifier, let pointer, displayFrame.contains(pointer) else { return }
        drawMagnifier(at: CGPoint(x: pointer.x - displayFrame.minX,
                                  y: pointer.y - displayFrame.minY))
    }

    private static var isChinese: Bool {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
        return raw == "zh" || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    private func drawMagnifier(at point: CGPoint) {
        let scale = CGFloat(image.width) / max(1, displayFrame.width)
        let samplePixels = max(8, Int(30 * scale))
        let x = min(max(0, Int(point.x * scale) - samplePixels / 2), max(0, image.width - samplePixels))
        let y = min(max(0, Int(point.y * scale) - samplePixels / 2), max(0, image.height - samplePixels))
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: samplePixels, height: samplePixels)) else { return }
        let size: CGFloat = 120
        let origin = CGPoint(
            x: min(max(8, point.x + 18), max(8, bounds.width - size - 8)),
            y: min(max(8, point.y + 18), max(8, bounds.height - size - 8))
        )
        let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        NSImage(cgImage: crop, size: rect.size).draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: rect.midX - 6, y: rect.midY))
        cross.line(to: CGPoint(x: rect.midX + 6, y: rect.midY))
        cross.move(to: CGPoint(x: rect.midX, y: rect.midY - 6))
        cross.line(to: CGPoint(x: rect.midX, y: rect.midY + 6))
        cross.lineWidth = 1
        cross.stroke()
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(globalPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDrag?(globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(globalPoint(event)) }
    override func mouseMoved(with event: NSEvent) { onMouseMove?(globalPoint(event)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onConfirm?() }
        else { super.keyDown(with: event) }
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: displayFrame.minX + local.x, y: displayFrame.minY + local.y)
    }
}
