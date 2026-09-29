import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

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

    private var mode: NativeScreenshotSelectionMode
    private let callbacks: NativeScreenshotOverlayCallbacks
    private let capture = NativeScreenshotStaticCapture()
    private let originalFrontmostApp: NSRunningApplication?
    private var snapshots: [DisplaySnapshot] = []
    private var panels: [NativeScreenshotSelectionPanel] = []
    private var actionPanel: NativeScreenshotActionPanel?
    private var toolPanel: NativeScreenshotToolPanel?
    private var optionPanel: NativeScreenshotOptionPanel?
    private var sizePanel: NativeScreenshotSizePanel?
    private var presetPanel: NativeScreenshotPresetPanel?
    private var inlinePanel: NativeScreenshotSelectionPanel?
    private var inlineCanvas: NativeScreenshotAnnotationCanvasView?
    private var keyboardMonitor: Any?
    private var editor: NativeScreenshotEditorController?
    private var orderedWindows: [SCWindow] = []
    private var selectedRect: CGRect?
    private var selectedWindowID: CGWindowID?
    private var regionDrag: RegionDrag?
    private var dragMoved = false
    private var startedNewSelection = false
    private var lastDragPoint: CGPoint?
    private var spacePressed = false
    private var snapSuspended = false
    private var windowSnapEnabled = true
    private var anchoredCorner: CGPoint?
    private var ignoreNextMouseUp = false
    private var activeTool: NativeScreenshotAnnotationKind?
    private var annotationText = ""
    private var movingAnnotations: (original: CGRect, imageSize: CGSize,
                                    annotations: [NativeScreenshotAnnotation],
                                    tool: NativeScreenshotAnnotationKind?)?
    private let selectionStore = NativeScreenshotSelectionPreferenceStore()
    private var selectionPreset: NativeScreenshotSelectionPreset = .freeform
    private var selectionAspectRatio: CGFloat? { selectionPreset.aspectRatio }
    private var hoveredElement: CGRect?
    private var guideX: CGFloat?
    private var guideY: CGFloat?
    private var hoveredPoint: CGPoint?
    private let preferences = PreferencesManager.shared
    private var delivering = false
    private var recordingHandoffPending = false
    private var recordingMovePending = false
    private var inlineCanvasBuildInProgress = false
    private var inlineEffectProcessing = false
    private var inlineEffectPreviewTask: Task<Void, Never>?
    private var effects = NativeScreenshotImageProcessor.Effects()
    private var beautifyEnabled = false
    private var beautifyStyleIndex = 0
    private var beautifyOptions = NativeScreenshotBeautifyOptions()
    private struct TranslationContext {
        let id: UUID
        let region: CGRect
        let canvas: NativeScreenshotAnnotationCanvasView
        let generation: UInt64
        let image: CGImage
        let lines: [NativeScreenshotRecognizedText]
    }
    private var translationRequestID: UUID?
    private var translationContext: TranslationContext?
    private var translationHostingView: NSView?
    private var finished = false

    init(
        mode: NativeScreenshotSelectionMode,
        restoreApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        callbacks: NativeScreenshotOverlayCallbacks
    ) {
        self.mode = mode
        self.callbacks = callbacks
        originalFrontmostApp = restoreApplication
        selectionPreset = selectionStore.activePreselection
        let saved = PreferencesManager.shared
        effects.preset = NativeScreenshotImageProcessor.EffectPreset(
            rawValue: saved.effectsPreset) ?? .none
        effects.adjustments = .init(
            brightness: Float(saved.effectsBrightness),
            contrast: Float(saved.effectsContrast),
            saturation: Float(saved.effectsSaturation),
            sharpness: Float(saved.effectsSharpness))
        beautifyEnabled = saved.beautifyEnabled
        beautifyStyleIndex = saved.beautifyStyleIndex
        beautifyOptions = .init(
            mode: saved.beautifyMode == 0 ? .window : .rounded,
            margin: CGFloat(saved.beautifyPadding),
            cornerRadius: CGFloat(saved.beautifyCornerRadius),
            shadowRadius: CGFloat(saved.beautifyShadowRadius))
        applyBeautifyPalette()
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
                let captured = try await capture.captureDisplay(
                    displayID: display.displayID, showsCursor: preferences.captureCursor)
                snapshots.append(DisplaySnapshot(screen: screen, display: display, capture: captured))
            }
            guard !snapshots.isEmpty else { throw NativeScreenshotCaptureError.displayNotFound }
            guard !finished else { return }
            showSelectionPanels()
            installKeyboardMonitor()
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

    /// Release the selection after a recording settings handoff without
    /// interpreting that handoff as a user cancellation.
    func dismissForHandoff() {
        guard !finished else { return }
        finish(restoreFocus: true)
    }

    func beginRecordingSelectionMove() {
        guard recordingHandoffPending, selectedRect != nil else { return }
        recordingHandoffPending = false
        recordingMovePending = true
        // The selection panel cannot receive a drag while an annotated inline
        // canvas is on top. Preserve its edits before moving the outline.
        requestMove()
        for panel in panels { panel.ignoresMouseEvents = false }
        panels.first?.makeKeyAndOrderFront(nil)
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
            panel.onEscape = { [weak self] in self?.escapeOneLayer() }
            panel.onReturn = { [weak self] in self?.quickCaptureSelection() }

            let view = NativeScreenshotSelectionView(
                image: snapshot.capture.image,
                displayFrame: snapshot.display.frame
            )
            view.onMouseDown = { [weak self] point in self?.pointerDown(at: point, display: snapshot.display) }
            view.onMouseDrag = { [weak self] point, modifiers in
                self?.pointerDragged(to: point, modifiers: modifiers)
            }
            view.onMouseUp = { [weak self] point in self?.pointerUp(at: point, display: snapshot.display) }
            view.onMouseMove = { [weak self] point in self?.pointerMoved(to: point, display: snapshot.display) }
            view.onRightMouseDown = { [weak self] point in self?.anchorCorner(at: point) }
            view.onConfirm = { [weak self] in self?.quickCaptureSelection() }
            view.showsMagnifier = preferences.isScreenshotMagnifierEnabled
            view.elementSnapHint = preferences.isScreenshotElementSnapEnabled && !AXIsProcessTrusted()
            view.selectionAccent = preferences.nativeScreenshotToolbarConfiguration.accentColor
            view.onPresetRequested = { [weak self] anchor in
                self?.showPresetPanel(from: anchor, beforeSelection: true, snapshot: snapshot)
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first?.makeKeyAndOrderFront(nil)
        updateSelectionViews()
    }

    private func pointerDown(at point: CGPoint, display: SCDisplay) {
        guard !recordingHandoffPending else { return }
        guard inlineCanvas?.hasUnsavedEdits != true else { NSSound.beep(); return }
        if movingAnnotations != nil, selectedRect?.contains(point) != true {
            NSSound.beep()
            return
        }
        hideControls()
        inlinePanel?.orderOut(nil)
        inlinePanel = nil
        inlineCanvas = nil
        hoveredPoint = point
        snapSuspended = NSEvent.modifierFlags.contains(.option)
        hoveredElement = snapSuspended ? nil
            : elementRect(at: point) ?? (windowSnapEnabled ? window(at: point)?.frame : nil)
        switch mode {
        case .region:
            if let anchoredCorner {
                selectedRect = Self.rect(between: anchoredCorner, and: point)
                self.anchoredCorner = nil
                regionDrag = nil
                ignoreNextMouseUp = true
                updateSelectionViews()
                showActionPanel()
                if activeTool != nil || !effects.isIdentity || beautifyEnabled {
                    let tool = activeTool
                    Task { await makeInlineCanvasIfNeeded(tool: tool) }
                }
                return
            }
            dragMoved = false
            lastDragPoint = point
            if let selectedRect {
                let edges = movingAnnotations == nil
                    ? NativeScreenshotResizeEdges.near(point, rect: selectedRect) : []
                if !edges.isEmpty {
                    regionDrag = .resize(original: selectedRect, start: point, edges: edges)
                    startedNewSelection = false
                } else if selectedRect.contains(point) {
                    regionDrag = .move(original: selectedRect, start: point)
                    startedNewSelection = false
                } else {
                    regionDrag = .create(start: point)
                    startedNewSelection = true
                    selectedWindowID = nil
                }
            } else {
                regionDrag = .create(start: point)
                startedNewSelection = true
                selectedWindowID = nil
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

    private func pointerDragged(to point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        guard !recordingHandoffPending else { return }
        guard mode == .region, let regionDrag else { return }
        hoveredPoint = point
        snapSuspended = modifiers.contains(.option)
        hoveredElement = snapSuspended ? nil
            : elementRect(at: point) ?? (windowSnapEnabled ? window(at: point)?.frame : nil)
        defer { lastDragPoint = point }
        if case let .create(start) = regionDrag,
           hypot(point.x - start.x, point.y - start.y) >= 4 { dragMoved = true }
        switch regionDrag {
        case let .move(_, start), let .resize(_, start, _):
            if hypot(point.x - start.x, point.y - start.y) >= 4 { dragMoved = true }
        case .create: break
        }
        switch regionDrag {
        case let .create(start):
            if spacePressed, let lastDragPoint, let selectedRect {
                let dx = point.x - lastDragPoint.x
                let dy = point.y - lastDragPoint.y
                self.selectedRect = selectedRect.offsetBy(dx: dx, dy: dy)
                self.regionDrag = .create(start: CGPoint(x: start.x + dx, y: start.y + dy))
            } else if case let .resolution(width, height) = selectionPreset,
                      let snapshot = snapshots.first(where: { $0.display.frame.contains(start) }) {
                let scale = CGFloat(snapshot.capture.image.width)
                    / max(1, snapshot.display.frame.width)
                selectedRect = NativeScreenshotSelectionSizing.rect(
                    widthPixels: width, heightPixels: height, pixelsPerPoint: scale,
                    in: snapshot.display.frame,
                    around: CGRect(x: point.x, y: point.y, width: 0, height: 0))
            } else {
                var endpoint = point
                if let ratio = modifiers.contains(.shift) ? CGFloat(1) : selectionAspectRatio {
                    let width = abs(point.x - start.x)
                    let height = abs(point.y - start.y)
                    if width / max(1, ratio) > height {
                        endpoint.y = start.y + (point.y < start.y ? -width / ratio : width / ratio)
                    } else {
                        endpoint.x = start.x + (point.x < start.x ? -height * ratio : height * ratio)
                    }
                }
                let horizontal: NativeScreenshotResizeEdges = endpoint.x < start.x ? .left : .right
                let vertical: NativeScreenshotResizeEdges = endpoint.y < start.y ? .top : .bottom
                let rect = Self.rect(between: start, and: endpoint)
                selectedRect = selectionAspectRatio != nil || modifiers.contains(.shift)
                    ? rect : snapped(rect, moving: [horizontal, vertical])
            }
        case let .move(original, start):
            selectedRect = snapped(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), moving: [.left, .right, .top, .bottom])
        case let .resize(original, start, edges):
            var resized = edges.resized(original, from: start, to: point)
            if let ratio = selectionAspectRatio {
                if edges.contains(.left) || edges.contains(.right) {
                    resized.size.height = max(4, resized.width / ratio)
                } else {
                    resized.size.width = max(4, resized.height * ratio)
                }
            }
            selectedRect = selectionAspectRatio == nil
                ? snapped(resized, moving: edges) : resized
        }
        if dragMoved {
            selectedWindowID = nil
            if case .resolution = selectionPreset, case .resize = regionDrag {
                selectionPreset = .freeform
                selectionStore.chooseBeforeSelection(.freeform)
            }
        }
        updateSelectionViews()
    }

    private func pointerUp(at point: CGPoint, display: SCDisplay) {
        guard !recordingHandoffPending else { return }
        if ignoreNextMouseUp {
            ignoreNextMouseUp = false
            return
        }
        switch mode {
        case .region:
            if regionDrag != nil { pointerDragged(to: point, modifiers: NSEvent.modifierFlags) }
            regionDrag = nil
            lastDragPoint = nil
            if !dragMoved && startedNewSelection {
                if !snapSuspended, preferences.isScreenshotElementSnapEnabled,
                   let candidate = hoveredElement, candidate.contains(point) {
                    selectedRect = candidate
                } else if !snapSuspended, windowSnapEnabled, let window = window(at: point) {
                    selectedRect = window.frame
                    selectedWindowID = window.windowID
                } else {
                    selectedRect = display.frame
                    selectedWindowID = nil
                }
            }
            startedNewSelection = false
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
        if recordingMovePending, let selectedRect {
            recordingMovePending = false
            enterRecordingHandoff(for: selectedRect)
        } else {
            if let movingAnnotations { activeTool = movingAnnotations.tool }
            showActionPanel()
            if movingAnnotations != nil || activeTool != nil
                || !effects.isIdentity || beautifyEnabled {
                let tool = activeTool
                Task { await makeInlineCanvasIfNeeded(tool: tool) }
            }
        }
    }

    private func pointerMoved(to point: CGPoint, display: SCDisplay) {
        guard !recordingHandoffPending else { return }
        hoveredPoint = point
        hoveredElement = snapSuspended ? nil
            : elementRect(at: point) ?? (windowSnapEnabled ? window(at: point)?.frame : nil)
        if actionPanel != nil || toolPanel != nil { updateSelectionViews(); return }
        switch mode {
        case .region: break
        case .window:
            let hoveredWindow = window(at: point)
            selectedRect = hoveredWindow?.frame
            selectedWindowID = hoveredWindow?.windowID
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
        guard !snapSuspended,
              preferences.isScreenshotElementSnapEnabled || preferences.snapGuidesEnabled else {
            guideX = nil; guideY = nil
            return rect
        }
        var targets = windowSnapEnabled
            ? orderedWindows.map(\.frame).filter { $0.width > 8 && $0.height > 8 } : []
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
            view.showsPreselectionPreset = mode == .region && selectedRect == nil
            view.preselectionPresetActive = selectionStore.activePreselection != .freeform
            view.hoveredElement = mode == .region ? hoveredElement : nil
            view.guideX = guideX
            view.guideY = guideY
            view.pointer = hoveredPoint
        }
    }

    private func showActionPanel() {
        guard let selectedRect, selectedRect.width >= 4, selectedRect.height >= 4,
              let geometry = panelGeometry(for: selectedRect) else { return }
        hideControls()
        let configuration = preferences.nativeScreenshotToolbarConfiguration
        let toolWidth = min(geometry.screen.visibleFrame.width - 16,
                            NativeScreenshotToolPanel.preferredWidth(configuration: configuration))
        let tool = NativeScreenshotToolPanel(
            contentRect: CGRect(x: 0, y: 0, width: toolWidth, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configureChrome(tool)
        tool.installButtons(target: self, selectedTool: activeTool,
                            configuration: configuration,
                            currentColor: inlineCanvas.flatMap {
                                NSColor(cgColor: $0.style.strokeColor.cgColor)
                            } ?? .systemRed)
        let available = geometry.screen.visibleFrame
        let secondarySpace: CGFloat = activeTool == nil ? 0 : 60
        let above = geometry.rect.maxY + 8 + secondarySpace
        let toolY = above + 40 <= available.maxY ? above
            : max(available.minY + 8, geometry.rect.minY - 107 - secondarySpace)
        tool.setFrameOrigin(CGPoint(
            x: max(available.minX + 8, min(geometry.rect.midX - toolWidth / 2, available.maxX - toolWidth - 8)),
            y: max(available.minY + 8, toolY)
        ))
        tool.orderFrontRegardless()
        toolPanel = tool

        let actionHeight = NativeScreenshotActionPanel.preferredHeight(configuration: configuration)
        let actions = NativeScreenshotActionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 40,
                                height: min(actionHeight, geometry.screen.visibleFrame.height - 16)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configureChrome(actions)
        actions.installButtons(target: self, configuration: configuration)
        let right = geometry.rect.maxX + 8
        let actionX = right + 40 <= available.maxX ? right : geometry.rect.minX - 48
        actions.setFrameOrigin(CGPoint(
            x: max(available.minX + 8, min(actionX, available.maxX - 48)),
            y: max(available.minY + 8,
                   min(geometry.rect.midY - actions.frame.height / 2,
                       available.maxY - actions.frame.height - 8))
        ))
        actions.orderFrontRegardless()
        actionPanel = actions
        showSizePanel(for: selectedRect, above: false)
        tool.makeKeyAndOrderFront(nil)
        if activeTool != nil { showToolOptions() }
    }

    private func configureChrome(_ panel: NativeScreenshotSelectionPanel) {
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.escapeOneLayer() }
        panel.onReturn = { [weak self] in self?.quickCaptureSelection() }
    }

    private func panelGeometry(for rect: CGRect) -> (screen: NSScreen, rect: CGRect)? {
        let snapshot = snapshots.max { left, right in
            left.display.frame.intersection(rect).width * left.display.frame.intersection(rect).height
                < right.display.frame.intersection(rect).width * right.display.frame.intersection(rect).height
        }
        guard let snapshot else { return nil }
        let frame = snapshot.screen.frame
        let display = snapshot.display.frame
        let mapped = CGRect(x: frame.minX + rect.minX - display.minX,
                            y: frame.maxY - (rect.maxY - display.minY),
                            width: rect.width, height: rect.height)
        return (snapshot.screen, mapped)
    }

    private func hideControls() {
        cancelTranslation()
        clearInlineEffectPreview()
        presetPanel?.orderOut(nil)
        presetPanel = nil
        actionPanel?.orderOut(nil)
        toolPanel?.orderOut(nil)
        optionPanel?.orderOut(nil)
        sizePanel?.orderOut(nil)
        actionPanel = nil
        toolPanel = nil
        optionPanel = nil
        sizePanel = nil
    }

    private func showSizePanel(for selection: CGRect, above: Bool) {
        guard let geometry = panelGeometry(for: selection),
              let snapshot = snapshots.first(where: { $0.screen === geometry.screen }) else { return }
        let scale = CGFloat(snapshot.capture.image.width) / max(1, snapshot.display.frame.width)
        let panel = NativeScreenshotSizePanel(
            contentRect: CGRect(x: 0, y: 0, width: 270, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configureChrome(panel)
        panel.install(widthPixels: Int((selection.width * scale).rounded()),
                      heightPixels: Int((selection.height * scale).rounded()),
                      preset: selectionPreset,
                      pixelsPerPoint: scale,
                      unitIsPoints: selectionStore.unitIsPoints,
                      onPresetRequested: { [weak self] anchor in
            self?.showPresetPanel(from: anchor, beforeSelection: false, snapshot: snapshot)
        },
                      onResize: { [weak self] width, height in
            guard let self, let current = self.selectedRect else { return }
            guard self.inlineCanvas?.hasUnsavedEdits != true else {
                NSSound.beep()
                self.showActionPanel()
                return
            }
            let activeTool = self.activeTool
            self.inlinePanel?.orderOut(nil)
            self.inlinePanel = nil
            self.inlineCanvas = nil
            self.selectedRect = NativeScreenshotSelectionSizing.rect(
                widthPixels: width, heightPixels: height, pixelsPerPoint: scale,
                in: snapshot.display.frame, around: current)
            if case .resolution = self.selectionPreset {
                self.selectionPreset = .freeform
                self.selectionStore.chooseBeforeSelection(.freeform)
            }
            // Resizing a snapped window turns it into a visible screen region;
            // the independent window capture would otherwise ignore this size.
            if self.mode == .window { self.selectedWindowID = nil }
            self.updateSelectionViews()
            if self.recordingHandoffPending, let updated = self.selectedRect {
                self.sizePanel?.orderOut(nil)
                self.sizePanel = nil
                self.showSizePanel(for: updated, above: true)
                self.callbacks.onRecordingRequested(updated)
                return
            }
            self.showActionPanel()
            if activeTool != nil || !effects.isIdentity || beautifyEnabled {
                let tool = activeTool
                Task { await self.makeInlineCanvasIfNeeded(tool: tool) }
            }
        })
        let area = geometry.screen.visibleFrame
        let proposedY = above ? geometry.rect.maxY + 5 : geometry.rect.minY - 43
        let fallbackY = !above && geometry.rect.height >= 46
            ? geometry.rect.minY + 6 : geometry.rect.maxY + 5
        panel.setFrameOrigin(CGPoint(
            x: max(area.minX + 8, min(geometry.rect.minX, area.maxX - panel.frame.width - 8)),
            y: proposedY >= area.minY && proposedY + 38 <= area.maxY ? proposedY
                : max(area.minY + 8, min(fallbackY, area.maxY - 46))
        ))
        panel.orderFrontRegardless()
        sizePanel = panel
    }

    private func showPresetPanel(from anchor: NSView, beforeSelection: Bool,
                                 snapshot: DisplaySnapshot) {
        if let presetPanel {
            presetPanel.orderOut(nil)
            self.presetPanel = nil
            return
        }
        let scale = CGFloat(snapshot.capture.image.width) / max(1, snapshot.display.frame.width)
        let active = beforeSelection ? selectionStore.activePreselection : selectionPreset
        var ratioChoices = NativeScreenshotSelectionPresetCatalog.ratios.map { preset in
            NativeScreenshotPresetPanel.Choice(
                title: preset == .freeform ? nativeScreenshotLabel("自由", "Freeform") : preset.title,
                preset: preset, selected: active.matches(preset))
        }
        if !beforeSelection, let selectedRect,
           let custom = NativeScreenshotSelectionPresetCatalog.customRatio(
                widthPixels: Int((selectedRect.width * scale).rounded()),
                heightPixels: Int((selectedRect.height * scale).rounded())) {
            let customLocked = active.aspectRatio.map {
                NativeScreenshotSelectionPresetCatalog.matchingRatio($0) == nil
            } ?? false
            let title = nativeScreenshotLabel("自定义", "Custom") + " · " + custom.title
            let named = NativeScreenshotSelectionPreset.ratio(
                label: title, value: custom.aspectRatio ?? 1)
            ratioChoices.insert(.init(title: title, preset: named, selected: customLocked), at: 1)
        }
        let resolutionChoices = NativeScreenshotSelectionPresetCatalog.resolutions.map { preset in
            NativeScreenshotPresetPanel.Choice(
                title: preset.title, preset: preset, selected: active.matches(preset))
        }
        let panel = NativeScreenshotPresetPanel(
            contentRect: CGRect(origin: .zero, size: NativeScreenshotPresetPanel.preferredSize(
                ratioCount: ratioChoices.count, showsUnits: !beforeSelection)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        configureChrome(panel)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.onEscape = { [weak self] in self?.escapeOneLayer() }
        panel.install(ratios: ratioChoices, resolutions: resolutionChoices,
                      keepRatio: selectionStore.keepRatioForNextCaptures,
                      unitIsPoints: selectionStore.unitIsPoints,
                      showsUnits: !beforeSelection,
                      onChoice: { [weak self] preset in
            guard let self else { return }
            self.presetPanel?.orderOut(nil)
            self.presetPanel = nil
            if beforeSelection {
                self.selectionStore.chooseBeforeSelection(preset)
                self.selectionPreset = preset
                self.updateSelectionViews()
                self.panels.first?.makeKeyAndOrderFront(nil)
            } else {
                self.applySelectionPreset(preset, display: snapshot.display.frame, scale: scale)
            }
        }, onKeepRatio: { [weak self] enabled in
            guard let self else { return }
            self.selectionStore.setKeepRatio(enabled, currentPreset: self.selectionPreset,
                                             beforeSelection: beforeSelection)
            if beforeSelection { self.selectionPreset = self.selectionStore.activePreselection }
            self.updateSelectionViews()
        }, onUnit: { [weak self] points in
            guard let self else { return }
            self.selectionStore.unitIsPoints = points
            if let current = self.selectedRect {
                self.sizePanel?.updateUnitDisplay(
                    widthPixels: Int((current.width * scale).rounded()),
                    heightPixels: Int((current.height * scale).rounded()),
                    unitIsPoints: points)
            }
        })
        guard let window = anchor.window else { return }
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let available = window.screen?.visibleFrame ?? snapshot.screen.visibleFrame
        let x = max(available.minX + 8,
                    min(anchorFrame.midX - panel.frame.width / 2,
                        available.maxX - panel.frame.width - 8))
        let below = anchorFrame.minY - panel.frame.height - 5
        let above = anchorFrame.maxY + 5
        let y = below >= available.minY + 8 ? below
            : min(above, available.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(CGPoint(x: x, y: max(available.minY + 8, y)))
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        presetPanel = panel
    }

    private func applySelectionPreset(_ preset: NativeScreenshotSelectionPreset,
                                      display: CGRect, scale: CGFloat) {
        guard let current = selectedRect else { return }
        guard inlineCanvas?.hasUnsavedEdits != true else { NSSound.beep(); return }
        selectionStore.chooseForCurrentSelection(preset)
        selectionPreset = preset
        switch preset {
        case .freeform:
            break
        case let .ratio(_, value):
            let width = max(4, Int((current.width * scale).rounded()))
            let size = NativeScreenshotSelectionSizing.pixels(
                width: width, height: max(4, Int((current.height * scale).rounded())),
                aspectRatio: value, edited: .width)
            selectedRect = NativeScreenshotSelectionSizing.rect(
                widthPixels: size.width, heightPixels: size.height,
                pixelsPerPoint: scale, in: display, around: current)
            selectedWindowID = nil
        case let .resolution(width, height):
            selectedRect = NativeScreenshotSelectionSizing.rect(
                widthPixels: width, heightPixels: height,
                pixelsPerPoint: scale, in: display, around: current)
            selectedWindowID = nil
        }
        updateSelectionViews()
        showActionPanel()
    }

    private func anchorCorner(at point: CGPoint) {
        guard mode == .region else { return }
        guard inlineCanvas?.hasUnsavedEdits != true,
              movingAnnotations == nil, !inlineCanvasBuildInProgress else {
            NSSound.beep()
            return
        }
        if let first = anchoredCorner {
            anchoredCorner = nil
            selectedRect = Self.rect(between: first, and: point)
            if selectedRect?.width ?? 0 >= 4, selectedRect?.height ?? 0 >= 4 {
                updateSelectionViews()
                showActionPanel()
                if activeTool != nil || !effects.isIdentity || beautifyEnabled {
                    let tool = activeTool
                    Task { await makeInlineCanvasIfNeeded(tool: tool) }
                }
            }
        } else {
            anchoredCorner = point
            selectedRect = nil
            selectedWindowID = nil
            inlinePanel?.orderOut(nil)
            inlinePanel = nil
            inlineCanvas = nil
            hideControls()
            updateSelectionViews()
        }
    }

    @objc fileprivate func selectToolbarTool(_ sender: NSButton) {
        let index = sender.tag - 1
        let kind = NativeScreenshotAnnotationKind.allCases.indices.contains(index)
            ? NativeScreenshotAnnotationKind.allCases[index] : nil
        activateTool(kind)
    }

    private func activateTool(_ kind: NativeScreenshotAnnotationKind?) {
        activeTool = kind
        if preferences.rememberLastTool {
            UserDefaults.standard.set(kind?.rawValue, forKey: "nativeScreenshot.lastTool")
        }
        if selectedRect != nil { showActionPanel() }
        if let kind {
            Task { await makeInlineCanvasIfNeeded(tool: kind) }
        } else {
            inlineCanvas?.tool = .select
            inlinePanel?.makeKeyAndOrderFront(nil)
        }
        showToolOptions()
    }

    private func makeInlineCanvasIfNeeded(tool: NativeScreenshotAnnotationKind?) async {
        guard !finished, activeTool == tool, let selectedRect,
              let geometry = panelGeometry(for: selectedRect) else { return }
        if let inlineCanvas {
            inlineCanvas.tool = tool.map(NativeScreenshotCanvasTool.annotation) ?? .select
            inlinePanel?.makeKeyAndOrderFront(nil)
            toolPanel?.orderFrontRegardless()
            actionPanel?.orderFrontRegardless()
            return
        }
        guard !inlineCanvasBuildInProgress else { return }
        inlineCanvasBuildInProgress = true
        let requestedWindowID = selectedWindowID
        defer {
            inlineCanvasBuildInProgress = false
            // A newer tool or selection may have arrived while ScreenCaptureKit
            // was awaiting a window frame. Build the latest request once the
            // stale attempt releases the single-flight slot.
            if !finished, !recordingHandoffPending, inlineCanvas == nil,
               self.selectedRect != nil, let latestTool = activeTool,
               (latestTool != tool || self.selectedRect != selectedRect
                || self.selectedWindowID != requestedWindowID) {
                Task { @MainActor [weak self] in
                    await self?.makeInlineCanvasIfNeeded(tool: latestTool)
                }
            }
        }
        do {
            let image: CGImage
            if mode == .window, let selectedWindowID = requestedWindowID {
                // Use the selected window's independent frame. A display crop
                // would bake in other windows occluding it once annotated.
                image = try await capture.captureWindow(
                    windowID: selectedWindowID, showsCursor: preferences.captureCursor).image
            } else {
                let pieces = snapshots.map {
                    NativeScreenshotCapturePiece(displayFrame: $0.display.frame, image: $0.capture.image)
                }
                image = try NativeScreenshotCaptureComposer.compose(
                    region: selectedRect, pieces: pieces,
                    maxOutputPixels: capture.maxOutputPixels).0
            }
            guard !finished, self.selectedRect == selectedRect,
                  self.selectedWindowID == requestedWindowID,
                  activeTool == tool else { return }
            let panel = NativeScreenshotSelectionPanel(
                contentRect: geometry.rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            configureChrome(panel)
            panel.hasShadow = false
            let canvas = NativeScreenshotAnnotationCanvasView(image: image)
            canvas.frame = CGRect(origin: .zero, size: geometry.rect.size)
            canvas.autoresizingMask = [.width, .height]
            canvas.tool = activeTool.map(NativeScreenshotCanvasTool.annotation) ?? .select
            canvas.textFontSize = preferences.screenshotTextFontSize
            canvas.textBold = preferences.screenshotTextBold
            canvas.textItalic = preferences.screenshotTextItalic
            canvas.textUnderline = preferences.screenshotTextUnderline
            canvas.textBackgroundEnabled = preferences.screenshotTextBackgroundEnabled
            canvas.textProvider = { [weak self] in self?.annotationText ?? "" }
            canvas.pressureEnabled = preferences.pencilPressureEnabled
            canvas.pencilSmoothing = NativeScreenshotPencilSmoothing(rawValue: preferences.pencilSmoothMode) ?? .smooth
            canvas.smartMarkerEnabled = preferences.smartMarkerEnabled
            canvas.onEscape = { [weak self] in self?.escapeOneLayer() }
            canvas.onCopyImage = { [weak self] in self?.copySelection() }
            canvas.onSaveImage = { [weak self] in self?.requestSave() }
            canvas.onToolShortcut = { [weak self] kind in self?.activateTool(kind) }
            canvas.onContentChanged = { [weak self, weak canvas] in
                guard let self, let canvas, !self.finished else { return }
                self.refreshInlineEffectPreview(to: canvas)
            }
            canvas.onSampledColor = { [weak self] color in
                self?.inlineCanvas?.style.strokeColor = color
                self?.inlineCanvas?.style.fillColor = color
                self?.toolPanel?.updateColor(NSColor(cgColor: color.cgColor) ?? .systemRed)
                self?.showToolOptions()
            }
            panel.contentView = canvas
            panel.orderFrontRegardless()
            panel.makeFirstResponder(canvas)
            inlinePanel = panel
            inlineCanvas = canvas
            if let movingAnnotations {
                let scale = CGFloat(image.width) / max(1, movingAnnotations.imageSize.width)
                for annotation in movingAnnotations.annotations {
                    var copy = annotation
                    if case let .magnifier(source, destination) = annotation.content {
                        func scaled(_ rect: CGRect) -> CGRect {
                            CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                   width: rect.width * scale, height: rect.height * scale)
                        }
                        copy.content = .magnifier(source: scaled(source),
                                                  destination: scaled(destination))
                    } else {
                        copy.content = annotation.content.scaled(by: scale, around: .zero)
                    }
                    copy.style.lineWidth = max(0.5, annotation.style.lineWidth * scale)
                    _ = canvas.insertAnnotation(copy)
                }
                canvas.clearSelection()
                self.movingAnnotations = nil
            }
            toolPanel?.orderFrontRegardless()
            actionPanel?.orderFrontRegardless()
            optionPanel?.orderFrontRegardless()
            showToolOptions()
        } catch {
            guard !finished else { return }
            guard self.selectedRect == selectedRect,
                  self.selectedWindowID == requestedWindowID,
                  self.activeTool == tool else { return }
            finish(restoreFocus: true)
            callbacks.onError(error)
        }
    }

    @objc fileprivate func showToolOptionsFromButton() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.makeInlineCanvasIfNeeded(tool: self.activeTool)
            guard !self.finished, self.inlineCanvas != nil else { return }
            // The color chip opens the color controls without selecting Pencil.
            self.showToolOptions(for: self.activeTool ?? .pencil)
        }
    }

    @objc fileprivate func invertSelectionColors() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.makeInlineCanvasIfNeeded(tool: self.activeTool)
            guard !self.finished, let canvas = self.inlineCanvas else { return }
            self.applyInlineImageTransform(to: canvas) {
                try NativeScreenshotImageProcessor.invertColors($0)
            }
        }
    }

    @objc fileprivate func showInlineEffects() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.makeInlineCanvasIfNeeded(tool: self.activeTool)
            guard !self.finished, self.inlineCanvas != nil else { return }
            self.showInlineEffectPanel(beautify: false)
        }
    }

    @objc fileprivate func showInlineBeautify() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.makeInlineCanvasIfNeeded(tool: self.activeTool)
            guard !self.finished, self.inlineCanvas != nil else { return }
            self.beautifyEnabled = true
            self.preferences.beautifyEnabled = true
            self.showInlineEffectPanel(beautify: true)
        }
    }

    @objc fileprivate func removeSelectionBackground() {
        guard #available(macOS 14.0, *) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.makeInlineCanvasIfNeeded(tool: self.activeTool)
            guard !self.finished, let canvas = self.inlineCanvas else { return }
            self.applyInlineImageTransform(to: canvas) {
                try NativeScreenshotImageProcessor.removeBackground($0)
            }
        }
    }

    private func showInlineEffectPanel(beautify: Bool) {
        guard let toolPanel, let canvas = inlineCanvas else { return }
        clearInlineEffectPreview()
        optionPanel?.orderOut(nil)
        optionPanel = nil
        let preferred = beautify ? CGSize(width: 800, height: 54)
            : CGSize(width: 270, height: 360)
        let width = min(preferred.width,
                        max(300, (toolPanel.screen?.visibleFrame.width ?? 900) - 16))
        let panel = NativeScreenshotOptionPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: preferred.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configureChrome(panel)
        if beautify {
            panel.installBeautifyControls(
                initial: beautifyOptions, styleIndex: beautifyStyleIndex,
                enabled: beautifyEnabled, isWindowSnap: selectedWindowID != nil,
                onChange: { [weak self, weak canvas] options, index, enabled in
                    guard let self, let canvas else { return }
                    let customModeChanged = (self.beautifyStyleIndex == -1) != (index == -1)
                    self.beautifyOptions = options
                    self.beautifyStyleIndex = index
                    self.beautifyEnabled = enabled
                    self.preferences.beautifyMode = options.mode == .window ? 0 : 1
                    self.preferences.beautifyPadding = Double(options.margin)
                    self.preferences.beautifyCornerRadius = Double(options.cornerRadius)
                    self.preferences.beautifyShadowRadius = Double(options.shadowRadius)
                    self.preferences.beautifyStyleIndex = index
                    self.preferences.beautifyEnabled = enabled
                    UserDefaults.standard.set(Double(options.backgroundBlur),
                                              forKey: "beautifyBgBlur")
                    self.refreshInlineEffectPreview(to: canvas)
                    if customModeChanged {
                        Task { @MainActor [weak self] in
                            self?.showInlineEffectPanel(beautify: true)
                        }
                    }
                },
                onChooseCustomBackground: { [weak self] in
                    self?.chooseBeautifyBackground()
                })
        } else {
            panel.installAdjustmentControls(
                initial: effects,
                onChange: { [weak self, weak canvas] values in
                    guard let self, let canvas else { return }
                    self.effects = values
                    self.preferences.effectsPreset = values.preset.rawValue
                    self.preferences.effectsBrightness = Double(values.adjustments.brightness)
                    self.preferences.effectsContrast = Double(values.adjustments.contrast)
                    self.preferences.effectsSaturation = Double(values.adjustments.saturation)
                    self.preferences.effectsSharpness = Double(values.adjustments.sharpness)
                    self.refreshInlineEffectPreview(to: canvas)
                })
        }
        positionOptionPanel(panel, relativeTo: toolPanel)
        optionPanel = panel
        refreshInlineEffectPreview(to: canvas)
    }

    private func applyBeautifyPalette() {
        if beautifyStyleIndex >= 0 {
            let colors = NativeScreenshotBeautifyPalette.colors(at: beautifyStyleIndex)
            beautifyOptions.gradientTop = colors.0
            beautifyOptions.gradientBottom = colors.1
            beautifyOptions.backgroundImage = nil
        } else if let bytes = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData") {
            beautifyOptions.backgroundImage = Self.decodeBeautifyBackground(bytes)
            beautifyOptions.backgroundBlur = CGFloat(
                UserDefaults.standard.double(forKey: "beautifyBgBlur"))
        }
    }

    private static func decodeBeautifyBackground(_ data: Data) -> CGImage? {
        guard data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary)
    }

    private func chooseBeautifyBackground() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        picker.begin { [weak self] response in
            guard let self, response == .OK, let url = picker.url else { return }
            do {
                let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard let image = Self.decodeBeautifyBackground(bytes) else {
                    throw NativeScreenshotImageProcessor.ImageError.invalidImage
                }
                UserDefaults.standard.set(bytes, forKey: "beautifyCustomBgImageData")
                self.beautifyStyleIndex = -1
                self.beautifyEnabled = true
                self.beautifyOptions.backgroundImage = image
                self.beautifyOptions.backgroundBlur = 0
                UserDefaults.standard.set(0.0, forKey: "beautifyBgBlur")
                self.optionPanel?.selectCustomBeautifyImage(image)
                self.showInlineEffectPanel(beautify: true)
            } catch {
                self.reportInlineEffectError(error)
            }
        }
    }

    private func refreshInlineEffectPreview(to canvas: NativeScreenshotAnnotationCanvasView) {
        guard !effects.isIdentity || beautifyEnabled else {
            clearInlineEffectPreview()
            return
        }
        let currentEffects = effects
        let currentBeautify = beautifyOptions
        let currentBeautifyEnabled = beautifyEnabled
        previewInlineImage(to: canvas) { source in
            let adjusted = try NativeScreenshotImageProcessor.applyEffects(source, using: currentEffects)
            return currentBeautifyEnabled
                ? try NativeScreenshotImageEditor.wrap(adjusted, options: currentBeautify)
                : adjusted
        }
    }

    private func previewInlineImage(
        to canvas: NativeScreenshotAnnotationCanvasView,
        operation: @escaping (CGImage) throws -> CGImage
    ) {
        inlineEffectPreviewTask?.cancel()
        let snapshot = canvas.renderSnapshot()
        inlineEffectPreviewTask = Task { @MainActor [weak self, weak canvas] in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
                try Task.checkCancellation()
                let preview = try await Task.detached(priority: .userInitiated) {
                    let rendered = snapshot.document.annotations.isEmpty ? snapshot.image
                        : try NativeScreenshotAnnotationRenderer.render(
                            baseImage: snapshot.image, document: snapshot.document)
                    let longest = max(rendered.width, rendered.height)
                    let sample = longest > 1280
                        ? try NativeScreenshotImageEditor.scale(
                            rendered, by: 1280 / CGFloat(longest)) : rendered
                    return try operation(sample)
                }.value
                guard !Task.isCancelled, let self, !self.finished,
                      let canvas, self.inlineCanvas === canvas,
                      canvas.contentGeneration == snapshot.generation else { return }
                canvas.showTransientPreview(preview)
            } catch is CancellationError {
            } catch {
                // The Apply action reports errors; a failed transient preview
                // leaves the editable source unchanged.
            }
        }
    }

    private func clearInlineEffectPreview() {
        inlineEffectPreviewTask?.cancel()
        inlineEffectPreviewTask = nil
        inlineCanvas?.showTransientPreview(nil)
    }

    private func applyInlineImageTransform(
        to canvas: NativeScreenshotAnnotationCanvasView,
        operation: @escaping (CGImage) throws -> CGImage
    ) {
        guard !inlineEffectProcessing, let original = selectedRect else { return }
        inlineEffectPreviewTask?.cancel()
        inlineEffectPreviewTask = nil
        if !canvas.canPreserveImageUndo {
            let alert = NSAlert()
            alert.messageText = nativeScreenshotLabel("大图无法撤销", "Large image cannot be undone")
            alert.informativeText = nativeScreenshotLabel(
                "图像过大，应用后不能撤销此效果。", "This image is too large to undo after applying the effect.")
            alert.addButton(withTitle: nativeScreenshotLabel("继续", "Continue"))
            alert.addButton(withTitle: nativeScreenshotLabel("取消", "Cancel"))
            alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        inlineEffectProcessing = true
        let oldSize = CGSize(width: canvas.image.width, height: canvas.image.height)
        let snapshot = canvas.renderSnapshot()
        Task { @MainActor [weak self, weak canvas] in
            guard let self else { return }
            defer { self.inlineEffectProcessing = false }
            do {
                let transformed = try await Task.detached(priority: .userInitiated) {
                    let flattened = snapshot.document.annotations.isEmpty ? snapshot.image
                        : try NativeScreenshotAnnotationRenderer.render(
                            baseImage: snapshot.image, document: snapshot.document)
                    return try operation(flattened)
                }.value
                guard !self.finished, let canvas, self.inlineCanvas === canvas,
                      self.selectedRect == original,
                      canvas.contentGeneration == snapshot.generation else {
                    self.clearInlineEffectPreview()
                    return
                }
                canvas.commitImageTransform(transformed)
                self.synchronizeInlineCanvasGeometry(canvas, previousSize: oldSize,
                                                     previousRect: original)
                self.showActionPanel()
                self.inlinePanel?.makeKeyAndOrderFront(nil)
            } catch {
                self.clearInlineEffectPreview()
                self.reportInlineEffectError(error)
            }
        }
    }

    private func synchronizeInlineCanvasGeometry(
        _ canvas: NativeScreenshotAnnotationCanvasView,
        previousSize: CGSize,
        previousRect: CGRect? = nil
    ) {
        guard let original = previousRect ?? selectedRect else { return }
        let newSize = CGSize(width: canvas.image.width, height: canvas.image.height)
        guard newSize != previousSize else { return }
        let pixelsPerPoint = previousSize.width / max(1, original.width)
        let width = newSize.width / max(0.01, pixelsPerPoint)
        let height = newSize.height / max(0.01, pixelsPerPoint)
        selectedRect = CGRect(x: original.midX - width / 2,
                              y: original.midY - height / 2,
                              width: width, height: height)
        if let selectedRect, let geometry = panelGeometry(for: selectedRect) {
            inlinePanel?.setFrame(geometry.rect, display: true)
            canvas.frame = CGRect(origin: .zero, size: geometry.rect.size)
            updateSelectionViews()
        }
    }

    private func reportInlineEffectError(_ error: Error) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = nativeScreenshotLabel("图像处理失败", "Image processing failed")
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: nativeScreenshotLabel("确定", "OK"))
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        alert.runModal()
    }

    private func showToolOptions(for overrideTool: NativeScreenshotAnnotationKind? = nil) {
        clearInlineEffectPreview()
        optionPanel?.orderOut(nil)
        optionPanel = nil
        guard let toolPanel, let inlineCanvas,
              let activeTool = overrideTool ?? activeTool else {
            if let inlineCanvas { refreshInlineEffectPreview(to: inlineCanvas) }
            return
        }
        let maximumWidth = max(300, (toolPanel.screen?.visibleFrame.width ?? 900) - 16)
        let width = min(maximumWidth, NativeScreenshotOptionPanel.preferredWidth(for: activeTool))
        let panel = NativeScreenshotOptionPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configureChrome(panel)
        panel.onToolModeChanged = { [weak self] kind in self?.activateTool(kind) }
        panel.installControls(tool: activeTool, canvas: inlineCanvas,
                              text: annotationText, onText: { [weak self] in self?.annotationText = $0 })
        panel.onColorChanged = { [weak self] color in self?.toolPanel?.updateColor(color) }
        positionOptionPanel(panel, relativeTo: toolPanel)
        optionPanel = panel
        refreshInlineEffectPreview(to: inlineCanvas)
    }

    private func positionOptionPanel(_ panel: NativeScreenshotOptionPanel,
                                     relativeTo toolPanel: NativeScreenshotToolPanel) {
        let available = toolPanel.screen?.visibleFrame ?? toolPanel.frame
        let placement = selectedRect.flatMap(panelGeometry(for:))
        let toolbarAbove = placement.map { toolPanel.frame.midY > $0.rect.midY } ?? true
        let panelHeight = panel.frame.height
        let candidate = toolbarAbove ? toolPanel.frame.minY - panelHeight - 6
            : toolPanel.frame.maxY + 6
        let y = candidate >= available.minY && candidate + panelHeight <= available.maxY
            ? candidate : max(available.minY,
                              min(toolPanel.frame.maxY + 6, available.maxY - panelHeight))
        panel.setFrameOrigin(CGPoint(
            x: max(available.minX, min(toolPanel.frame.midX - panel.frame.width / 2,
                                       available.maxX - panel.frame.width)),
            y: max(available.minY, min(y, available.maxY - panelHeight))
        ))
        panel.orderFrontRegardless()
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, !self.finished, !self.recordingHandoffPending,
                  self.editor == nil else { return event }
            guard let keyWindow = NSApp.keyWindow,
                  (self.panels.contains { $0 === keyWindow }
                   || self.inlinePanel === keyWindow
                   || self.actionPanel === keyWindow
                   || self.toolPanel === keyWindow
                   || self.optionPanel === keyWindow
                   || self.sizePanel === keyWindow
                   || self.presetPanel === keyWindow) else { return event }
            if event.type == .keyUp {
                if event.keyCode == 49 { self.spacePressed = false }
                return event
            }
            guard event.type == .keyDown else { return event }
            // The inline canvas is rebuilt after moving an annotated region.
            // Do not deliver the unannotated snapshot during that handoff.
            if self.movingAnnotations != nil, self.inlineCanvas == nil {
                if event.keyCode == 53 { self.escapeOneLayer() }
                return nil
            }
            if NSApp.keyWindow?.firstResponder is NSTextView,
               event.keyCode != 53 { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if modifiers.contains(.command) {
                switch key {
                case "c":
                    if self.inlineCanvas?.copySelection() != true { self.copySelection() }
                    return nil
                case "v":
                    if self.inlineCanvas?.pasteSelection() == true { return nil }
                    if self.selectedRect != nil, self.inlineCanvas == nil {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.makeInlineCanvasIfNeeded(tool: self.activeTool)
                            _ = self.inlineCanvas?.pasteSelection()
                        }
                        return nil
                    }
                case "d":
                    if self.inlineCanvas?.duplicateSelection() == true { return nil }
                case "s": self.requestSave(); return nil
                case "z":
                    if modifiers.contains(.shift) { self.redoAnnotation() }
                    else { self.undoAnnotation() }
                    return nil
                default: break
                }
                return event
            }
            if modifiers.contains(.control) || modifiers.contains(.option) { return event }
            switch event.keyCode {
            case 53: self.escapeOneLayer(); return nil
            case 36, 76: self.quickCaptureSelection(); return nil
            case 48:
                self.windowSnapEnabled.toggle()
                self.updateSelectionViews()
                return nil
            case 49:
                if self.regionDrag != nil {
                    self.spacePressed = true
                } else if self.selectedRect != nil,
                          self.preferences.nativeScreenshotToolbarConfiguration
                            .actionID(forShortcut: " ") == "move" {
                    self.requestMove()
                } else {
                    self.spacePressed = true
                }
                return nil
            default: break
            }
            if key == "f", self.selectedRect == nil, self.windowSnapEnabled,
               let point = self.hoveredPoint,
               let snapshot = self.snapshots.first(where: { $0.display.frame.contains(point) }) {
                guard self.inlineCanvas?.hasUnsavedEdits != true,
                      self.movingAnnotations == nil,
                      !self.inlineCanvasBuildInProgress else {
                    NSSound.beep()
                    return nil
                }
                self.inlinePanel?.orderOut(nil)
                self.inlinePanel = nil
                self.inlineCanvas = nil
                self.selectedRect = snapshot.display.frame
                self.selectedWindowID = nil
                self.updateSelectionViews()
                self.showActionPanel()
                if let tool = self.activeTool {
                    Task { await self.makeInlineCanvasIfNeeded(tool: tool) }
                }
                return nil
            }
            if let id = self.preferences.nativeScreenshotToolbarConfiguration.toolID(forShortcut: key) {
                self.activateTool(NativeScreenshotAnnotationKind(rawValue: id))
                return nil
            }
            if self.selectedRect != nil,
               let actionID = self.preferences.nativeScreenshotToolbarConfiguration
                    .actionID(forShortcut: key) {
                switch actionID {
                case "cancel": self.cancelFromButton()
                case "move": self.requestMove()
                case "editor": self.requestEditor()
                case "pin": self.requestPin()
                case "copy": self.copySelection()
                case "save": self.requestSave()
                case "ocr": self.requestOCR()
                case "qrCode": self.requestQRCode()
                case "autoRedact": self.requestAutoRedact()
                case "scroll": self.requestScrolling()
                case "record": self.requestRecording()
                case "share": self.requestShare()
                case "beautify": self.showInlineBeautify()
                case "imageEffects": self.showInlineEffects()
                case "invertColors": self.invertSelectionColors()
                case "removeBackground": self.removeSelectionBackground()
                case "translate": self.requestTranslation()
                case "undo": self.undoAnnotation()
                case "redo": self.redoAnnotation()
                default: break
                }
                return nil
            }
            if self.inlineCanvas != nil, key.count == 1,
               key.utf8.first.map({ (48...57).contains($0) || (97...122).contains($0) }) == true {
                return nil
            }
            return event
        }
    }

    private func escapeOneLayer() {
        if let presetPanel {
            presetPanel.orderOut(nil)
            self.presetPanel = nil
            sizePanel?.makeKeyAndOrderFront(nil)
            return
        }
        if inlineCanvas?.hasSelectedAnnotation == true {
            inlineCanvas?.clearSelection()
            return
        }
        if let movingAnnotations {
            selectedRect = movingAnnotations.original
            activeTool = movingAnnotations.tool
            updateSelectionViews()
            showActionPanel()
            Task { await makeInlineCanvasIfNeeded(tool: movingAnnotations.tool) }
            return
        }
        if optionPanel != nil {
            clearInlineEffectPreview()
            optionPanel?.orderOut(nil)
            optionPanel = nil
        } else if activeTool != nil {
            activateTool(nil)
        } else if selectedRect != nil {
            selectedRect = nil
            selectedWindowID = nil
            hoveredElement = nil
            inlinePanel?.orderOut(nil)
            inlinePanel = nil
            inlineCanvas = nil
            hideControls()
            updateSelectionViews()
            panels.first?.makeKeyAndOrderFront(nil)
        } else {
            cancel()
        }
    }

    @objc fileprivate func annotateSelection() {
        activateTool(.pencil)
    }

    private var captureIsReady: Bool {
        guard !inlineCanvasBuildInProgress, movingAnnotations == nil else {
            NSSound.beep()
            return false
        }
        return true
    }

    @objc fileprivate func confirmSelection() {
        guard selectedRect != nil, captureIsReady else { return }
        Task { await deliverSelection(.confirm) }
    }

    @objc fileprivate func copySelection() {
        guard selectedRect != nil, !delivering, captureIsReady else { return }
        delivering = true
        Task {
            do {
                let image = try await selectedImage()
                guard !finished else { return }
                finish(restoreFocus: true)
                callbacks.onQuickCapture(image, 1)
            } catch {
                guard !finished else { return }
                finish(restoreFocus: true)
                callbacks.onError(error)
            }
        }
    }

    @objc fileprivate func quickCaptureSelection() {
        guard selectedRect != nil, !delivering, captureIsReady else { return }
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

    @objc fileprivate func requestShare() {
        guard !delivering, captureIsReady, let originalRect = selectedRect else { return }
        delivering = true
        let originalWindowID = selectedWindowID
        Task {
            defer { delivering = false }
            do {
                let image: NativeScreenshotCapturedImage
                if mode == .window, let windowID = originalWindowID,
                   inlineCanvas?.hasUnsavedEdits != true {
                    image = try await capture.captureWindow(
                        windowID: windowID, showsCursor: preferences.captureCursor)
                } else {
                    image = try previewSelectedImage()
                }
                guard !finished, selectedRect == originalRect,
                      selectedWindowID == originalWindowID,
                      let view = actionPanel?.contentView else { return }
                let nsImage = NSImage(cgImage: image.image,
                                      size: NSSize(width: image.image.width, height: image.image.height))
                NSSharingServicePicker(items: [nsImage]).show(
                    relativeTo: view.bounds, of: view, preferredEdge: .minX
                )
            } catch {
                guard !finished else { return }
                finish(restoreFocus: true)
                callbacks.onError(error)
            }
        }
    }

    @objc fileprivate func requestTranslation() {
        guard !delivering, captureIsReady, let region = selectedRect else { return }
        guard #available(macOS 15.0, *) else {
            reportTranslationError(NativeScreenshotOnDeviceTranslationError.requiresMacOS15)
            return
        }
        cancelTranslation()
        let requestID = UUID()
        translationRequestID = requestID
        delivering = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.delivering = false }
            do {
                await makeInlineCanvasIfNeeded(tool: activeTool)
                guard !finished, translationRequestID == requestID,
                      selectedRect == region, let canvas = inlineCanvas else { return }
                let snapshot = canvas.renderSnapshot()
                let image = try await Task.detached(priority: .userInitiated) {
                    try snapshot.document.annotations.isEmpty ? snapshot.image
                        : NativeScreenshotAnnotationRenderer.render(
                            baseImage: snapshot.image, document: snapshot.document)
                }.value
                let language: NativeScreenshotOCRLanguage
                switch preferences.screenshotOCRLanguage {
                case .english: language = .english
                case .chineseEnglish: language = .chineseAndEnglish
                case .auto: language = .automatic
                }
                let lines = try await NativeScreenshotRecognitionService.recognizeText(
                    in: image, language: language)
                guard !finished, translationRequestID == requestID,
                      selectedRect == region, inlineCanvas === canvas,
                      canvas.contentGeneration == snapshot.generation else { return }
                guard !lines.isEmpty else {
                    cancelTranslation()
                    reportTranslationError(NSError(
                        domain: "NativeScreenshotTranslation", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: nativeScreenshotLabel(
                            "选区中没有可翻译的文字。", "No text to translate in the selection.")]))
                    return
                }
                translationContext = TranslationContext(
                    id: requestID, region: region, canvas: canvas,
                    generation: snapshot.generation, image: image, lines: lines)
                let request = NativeScreenshotOverlayTranslationRequest(
                    id: requestID, sourceLines: lines.map(\.text))
                let host = NSHostingView(rootView: NativeScreenshotOverlayTranslationTaskView(
                    request: request,
                    onTranslated: { [weak self] id, translations in
                        self?.finishTranslation(id: id, translations: translations)
                    },
                    onFailure: { [weak self] id, error in
                        guard self?.translationRequestID == id else { return }
                        self?.cancelTranslation()
                        self?.reportTranslationError(error)
                    }))
                host.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
                canvas.addSubview(host)
                translationHostingView = host
            } catch {
                guard !finished, translationRequestID == requestID else { return }
                cancelTranslation()
                reportTranslationError(error)
            }
        }
    }

    private func finishTranslation(id: UUID, translations: [String]) {
        guard let context = translationContext, context.id == id,
              translationRequestID == id, !finished,
              selectedRect == context.region, inlineCanvas === context.canvas,
              context.canvas.contentGeneration == context.generation else {
            cancelTranslation()
            return
        }
        do {
            let annotations = try NativeScreenshotTranslatedAnnotationFactory.makeAnnotations(
                in: context.image, recognizedLines: context.lines,
                translatedLines: translations)
            cancelTranslation()
            guard !annotations.isEmpty else { return }
            _ = context.canvas.insertAnnotations(annotations)
            inlinePanel?.makeKeyAndOrderFront(nil)
        } catch {
            cancelTranslation()
            reportTranslationError(error)
        }
    }

    private func cancelTranslation() {
        translationRequestID = nil
        translationContext = nil
        translationHostingView?.removeFromSuperview()
        translationHostingView = nil
    }

    private func reportTranslationError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = nativeScreenshotLabel("翻译失败", "Translation failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: nativeScreenshotLabel("确定", "OK"))
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        alert.runModal()
    }

    @objc fileprivate func requestMove() {
        guard let selectedRect else { return }
        // A moved selection is recaptured. Explain why its processed bitmap
        // cannot be carried to another screen region without changing content.
        if inlineCanvas?.hasImageTransform == true {
            let alert = NSAlert()
            alert.messageText = nativeScreenshotLabel("请先撤销图像处理", "Undo the image effect first")
            alert.informativeText = nativeScreenshotLabel(
                "移动选区会重新截取屏幕。请先按 ⌘Z 撤销图像处理，再移动选区。",
                "Moving the selection captures the screen again. Press Command-Z to undo the image effect first.")
            alert.addButton(withTitle: nativeScreenshotLabel("确定", "OK"))
            alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            alert.runModal()
            return
        }
        if let inlineCanvas, inlineCanvas.hasUnsavedEdits {
            movingAnnotations = (
                original: selectedRect,
                imageSize: CGSize(width: inlineCanvas.image.width, height: inlineCanvas.image.height),
                annotations: inlineCanvas.previewDocument.annotations,
                tool: activeTool
            )
        }
        inlinePanel?.orderOut(nil)
        inlinePanel = nil
        inlineCanvas = nil
        // A manually moved window or full-screen outline is a screen region
        // from this point on; keeping window selection mode would ignore drags.
        mode = .region
        activeTool = nil
        hideControls()
        panels.first?.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func requestEditor() { Task { await prepareEditor() } }

    @objc fileprivate func undoAnnotation() {
        guard let canvas = inlineCanvas else { return }
        let oldSize = CGSize(width: canvas.image.width, height: canvas.image.height)
        canvas.undo()
        synchronizeInlineCanvasGeometry(canvas, previousSize: oldSize)
        showActionPanel()
        inlinePanel?.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func redoAnnotation() {
        guard let canvas = inlineCanvas else { return }
        let oldSize = CGSize(width: canvas.image.width, height: canvas.image.height)
        canvas.redo()
        synchronizeInlineCanvasGeometry(canvas, previousSize: oldSize)
        showActionPanel()
        inlinePanel?.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func requestRecording() {
        guard let selectedRect, !recordingHandoffPending,
              captureIsReady else { return }
        enterRecordingHandoff(for: selectedRect)
    }

    private func enterRecordingHandoff(for selectedRect: CGRect) {
        recordingHandoffPending = true
        hideControls()
        showSizePanel(for: selectedRect, above: true)
        inlinePanel?.orderOut(nil)
        for panel in panels { panel.ignoresMouseEvents = true }
        callbacks.onRecordingRequested(selectedRect)
    }

    @objc fileprivate func requestScrolling() {
        guard let selectedRect, captureIsReady else { return }
        finish(restoreFocus: true)
        callbacks.onScrollingRequested(selectedRect)
    }

    @objc fileprivate func cancelFromButton() { cancel() }

    private func prepareEditor() async {
        guard !delivering, captureIsReady else { return }
        delivering = true
        do {
            let base = try await selectedImage()
            guard !finished else { return }
            hideSelectionPanels()
            let editor = NativeScreenshotEditorController(
                base: base,
                defaultsAlreadyApplied: true,
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
        guard !delivering, captureIsReady else { return }
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
        if let inlineCanvas, inlineCanvas.hasUnsavedEdits {
            let rendered = try inlineCanvas.renderedImage()
            return try await processSelectedImage(NativeScreenshotCapturedImage(
                image: rendered, sourceRect: selectedRect,
                pixelsPerPoint: CGFloat(rendered.width) / max(1, selectedRect.width)
            ))
        }
        if mode == .window, let selectedWindowID {
            hideSelectionPanels()
            try await Task.sleep(nanoseconds: 80_000_000)
            let image = try await capture.captureWindow(windowID: selectedWindowID,
                                                        showsCursor: preferences.captureCursor)
            return try await processSelectedImage(image)
        }
        if preferences.captureCursor {
            hideSelectionPanels()
            try await Task.sleep(nanoseconds: 80_000_000)
            let image = try await capture.captureRegion(selectedRect, showsCursor: true)
            return try await processSelectedImage(image)
        }
        let pieces = snapshots.map {
            NativeScreenshotCapturePiece(displayFrame: $0.display.frame, image: $0.capture.image)
        }
        let (image, scale) = try NativeScreenshotCaptureComposer.compose(
            region: selectedRect, pieces: pieces, maxOutputPixels: capture.maxOutputPixels
        )
        return try await processSelectedImage(NativeScreenshotCapturedImage(
            image: image, sourceRect: selectedRect, pixelsPerPoint: scale
        ))
    }

    private func previewSelectedImage() throws -> NativeScreenshotCapturedImage {
        guard let selectedRect else { throw NativeScreenshotCaptureError.invalidRegion }
        if let inlineCanvas, inlineCanvas.hasUnsavedEdits {
            let image = try inlineCanvas.renderedImage()
            return try processSelectedImageSynchronously(NativeScreenshotCapturedImage(
                image: image, sourceRect: selectedRect,
                pixelsPerPoint: CGFloat(image.width) / max(1, selectedRect.width)))
        }
        let pieces = snapshots.map {
            NativeScreenshotCapturePiece(displayFrame: $0.display.frame, image: $0.capture.image)
        }
        let (image, scale) = try NativeScreenshotCaptureComposer.compose(
            region: selectedRect, pieces: pieces, maxOutputPixels: capture.maxOutputPixels
        )
        return try processSelectedImageSynchronously(NativeScreenshotCapturedImage(
            image: image, sourceRect: selectedRect, pixelsPerPoint: scale))
    }

    private func processSelectedImage(
        _ captured: NativeScreenshotCapturedImage
    ) async throws -> NativeScreenshotCapturedImage {
        let currentEffects = effects
        let currentBeautify = beautifyOptions
        let shouldBeautify = beautifyEnabled
        guard !currentEffects.isIdentity || shouldBeautify else { return captured }
        let output = try await Task.detached(priority: .userInitiated) {
            let adjusted = try NativeScreenshotImageProcessor.applyEffects(
                captured.image, using: currentEffects)
            return shouldBeautify
                ? try NativeScreenshotImageEditor.wrap(adjusted, options: currentBeautify)
                : adjusted
        }.value
        return NativeScreenshotCapturedImage(
            image: output, sourceRect: captured.sourceRect,
            pixelsPerPoint: CGFloat(output.width) / max(1, captured.sourceRect.width))
    }

    private func processSelectedImageSynchronously(
        _ captured: NativeScreenshotCapturedImage
    ) throws -> NativeScreenshotCapturedImage {
        guard !effects.isIdentity || beautifyEnabled else { return captured }
        let adjusted = try NativeScreenshotImageProcessor.applyEffects(captured.image, using: effects)
        let output = beautifyEnabled
            ? try NativeScreenshotImageEditor.wrap(adjusted, options: beautifyOptions)
            : adjusted
        return NativeScreenshotCapturedImage(
            image: output, sourceRect: captured.sourceRect,
            pixelsPerPoint: CGFloat(output.width) / max(1, captured.sourceRect.width))
    }

    private func hideSelectionPanels() {
        hideControls()
        inlinePanel?.orderOut(nil)
        for panel in panels { panel.orderOut(nil) }
    }

    private func finish(restoreFocus: Bool) {
        guard !finished else { return }
        finished = true
        hideSelectionPanels()
        panels.removeAll()
        inlinePanel = nil
        inlineCanvas = nil
        movingAnnotations = nil
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        editor?.close()
        editor = nil
        NativeScreenshotOverlayColorWell.restorePanelLevel()
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

/// Keep the system color picker above the temporary full-screen capture
/// panels, then restore its normal level when the session ends.
private final class NativeScreenshotOverlayColorWell: NSColorWell {
    private static var priorPanelLevel: NSWindow.Level?

    override func mouseDown(with event: NSEvent) {
        let panel = NSColorPanel.shared
        if Self.priorPanelLevel == nil { Self.priorPanelLevel = panel.level }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        super.mouseDown(with: event)
    }

    static func restorePanelLevel() {
        guard let level = priorPanelLevel else { return }
        NSColorPanel.shared.orderOut(nil)
        NSColorPanel.shared.level = level
        priorPanelLevel = nil
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotActionPanel: NativeScreenshotSelectionPanel {
    static func preferredHeight(configuration: NativeScreenshotToolbarConfiguration) -> CGFloat {
        CGFloat(NativeScreenshotToolbarConfiguration.rightActionIDs.filter {
            configuration.isActionEnabled($0)
        }.count) * 34 + 6
    }

    func installButtons(target: NativeScreenshotOverlayController,
                        configuration: NativeScreenshotToolbarConfiguration) {
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        background.layer?.backgroundColor = configuration.backgroundColor.cgColor
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0,
                                              width: frame.width, height: frame.height))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = Self.preferredHeight(configuration: configuration) > frame.height
        scroll.scrollerStyle = .overlay
        let documentHeight = Self.preferredHeight(configuration: configuration)
        let column = NSView(frame: CGRect(x: 0, y: 0, width: frame.width,
                                          height: documentHeight))
        let actions: [(String, String, String, String, Selector)] = [
            ("cancel", "xmark", "取消", "Cancel", #selector(NativeScreenshotOverlayController.cancelFromButton)),
            ("move", "arrow.up.left.and.arrow.down.right", "移动选区", "Move selection", #selector(NativeScreenshotOverlayController.requestMove)),
            ("editor", "rectangle.and.pencil.and.ellipsis", "打开编辑器", "Open editor", #selector(NativeScreenshotOverlayController.requestEditor)),
            ("copy", "doc.on.doc", "复制", "Copy", #selector(NativeScreenshotOverlayController.copySelection)),
            ("save", "square.and.arrow.down", "保存", "Save", #selector(NativeScreenshotOverlayController.requestSave)),
            ("share", "square.and.arrow.up", "分享", "Share", #selector(NativeScreenshotOverlayController.requestShare)),
            ("pin", "pin", "贴图", "Pin", #selector(NativeScreenshotOverlayController.requestPin)),
            ("ocr", "text.viewfinder", "文字识别", "Recognize text", #selector(NativeScreenshotOverlayController.requestOCR)),
            ("translate", "character.bubble", "翻译", "Translate", #selector(NativeScreenshotOverlayController.requestTranslation)),
            ("qrCode", "qrcode.viewfinder", "识别二维码", "Scan QR code", #selector(NativeScreenshotOverlayController.requestQRCode)),
            ("autoRedact", "eye.slash", "遮挡敏感信息", "Redact sensitive text", #selector(NativeScreenshotOverlayController.requestAutoRedact)),
            ("scroll", "arrow.down.right.and.arrow.up.left", "滚动截图", "Scrolling capture", #selector(NativeScreenshotOverlayController.requestScrolling)),
            ("record", "record.circle", "录屏", "Record", #selector(NativeScreenshotOverlayController.requestRecording))
        ]
        let step: CGFloat = 34
        for (index, item) in actions.filter({ configuration.isActionEnabled($0.0) }).enumerated() {
            let button = NativeScreenshotToolbarChrome.iconButton(
                symbol: item.1, title: nativeScreenshotLabel(item.2, item.3),
                target: target, action: item.4
            )
            button.contentTintColor = configuration.iconColor
            button.frame = CGRect(x: 4, y: documentHeight - 3 - CGFloat(index + 1) * step,
                                  width: 32, height: 32)
            column.addSubview(button)
        }
        scroll.documentView = column
        background.addSubview(scroll)
        contentView = background
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotToolPanel: NativeScreenshotSelectionPanel {
    private var toolButtons: [NSButton] = []
    private weak var colorButton: NSButton?
    private var accent: NSColor = .controlAccentColor

    static func preferredWidth(configuration: NativeScreenshotToolbarConfiguration) -> CGFloat {
        var effectCount = NativeScreenshotToolbarConfiguration.effectActionIDs.filter {
            configuration.isActionEnabled($0)
        }.count
        if #unavailable(macOS 14.0), configuration.isActionEnabled("removeBackground") {
            effectCount -= 1
        }
        return CGFloat(configuration.enabledToolIDs.filter { $0 != "select" }.count
                       + 3 + effectCount) * 34 + 6
    }

    func installButtons(target: NativeScreenshotOverlayController,
                        selectedTool: NativeScreenshotAnnotationKind?,
                        configuration: NativeScreenshotToolbarConfiguration,
                        currentColor: NSColor) {
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        background.layer?.backgroundColor = configuration.backgroundColor.cgColor
        accent = configuration.accentColor
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 1,
                                              width: frame.width, height: frame.height - 2))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .automatic
        let row = NSView(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth(configuration: configuration), height: 38))
        let tools: [(NativeScreenshotAnnotationKind, String, String, String)] = [
            (.pencil, "scribble", "画笔", "Pencil"),
            (.line, "line.diagonal", "直线", "Line"),
            (.arrow, "arrow.up.right", "箭头", "Arrow"),
            (.rectangle, "rectangle", "矩形", "Rectangle"),
            (.ellipse, "oval", "椭圆", "Ellipse"),
            (.highlighter, "highlighter", "荧光笔", "Highlighter"),
            (.richText, "textformat", "文字", "Text"),
            (.number, "1.circle.fill", "编号", "Number"),
            (.pixelate, "checkerboard", "马赛克", "Pixelate"),
            (.spotlight, "sun.max", "聚光灯", "Spotlight"),
            (.magnifier, "magnifyingglass", "放大镜", "Magnifier"),
            (.stamp, "face.smiling", "图章", "Stamp"),
            (.colorSampler, "eyedropper", "取色", "Color picker"),
            (.ruler, "ruler", "测距", "Ruler"),
            (.filledRectangle, "rectangle.fill", "实心矩形", "Filled rectangle"),
            (.blur, "drop.halffull", "模糊", "Blur"),
            (.solidCensor, "rectangle.fill", "纯色遮挡", "Solid censor"),
            (.eraseCensor, "eraser", "擦除", "Erase")
        ]
        var x: CGFloat = 2
        for (index, entry) in tools.filter({ configuration.isToolEnabled($0.0.rawValue) }).enumerated() {
            let shortcut = configuration.shortcut(forToolID: entry.0.rawValue)
            let title = nativeScreenshotLabel(entry.2, entry.3)
            let button = NativeScreenshotToolbarChrome.iconButton(
                symbol: entry.1,
                title: shortcut == nil || !PreferencesManager.shared.showToolShortcutsInTooltips
                    ? title : "\(title) (\(shortcut!.uppercased()))",
                target: target,
                action: #selector(NativeScreenshotOverlayController.selectToolbarTool(_:))
            )
            button.contentTintColor = configuration.iconColor
            button.tag = (NativeScreenshotAnnotationKind.allCases.firstIndex(of: entry.0) ?? 0) + 1
            button.setButtonType(.toggle)
            button.frame = CGRect(x: x, y: 3, width: 32, height: 32)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.setAccessibilityIdentifier("capture.tool.\(index)")
            row.addSubview(button)
            toolButtons.append(button)
            x += 34
        }
        x += 4
        let swatch = NSButton(title: "", target: target,
                              action: #selector(NativeScreenshotOverlayController.showToolOptionsFromButton))
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.frame = CGRect(x: x + 5, y: 8, width: 22, height: 22)
        swatch.layer?.cornerRadius = 6
        swatch.layer?.borderWidth = 2
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        swatch.toolTip = nativeScreenshotLabel("颜色和选项", "Color and options")
        swatch.setAccessibilityLabel(swatch.toolTip ?? "")
        row.addSubview(swatch)
        colorButton = swatch
        updateColor(currentColor)
        x += 34
        for item in [
            ("arrow.uturn.backward", "撤销", "Undo", #selector(NativeScreenshotOverlayController.undoAnnotation)),
            ("arrow.uturn.forward", "重做", "Redo", #selector(NativeScreenshotOverlayController.redoAnnotation))
        ] {
            let button = NativeScreenshotToolbarChrome.iconButton(
                symbol: item.0, title: nativeScreenshotLabel(item.1, item.2),
                target: target, action: item.3
            )
            button.contentTintColor = configuration.iconColor
            button.frame = CGRect(x: x, y: 3, width: 32, height: 32)
            row.addSubview(button)
            x += 34
        }
        let effects: [(String, String, String, String, Selector)] = [
            ("invertColors", "circle.lefthalf.filled", "反色", "Invert colors", #selector(NativeScreenshotOverlayController.invertSelectionColors)),
            ("imageEffects", "slider.horizontal.3", "调整特效", "Image effects", #selector(NativeScreenshotOverlayController.showInlineEffects)),
            ("beautify", "sparkles", "美化", "Beautify", #selector(NativeScreenshotOverlayController.showInlineBeautify)),
            ("removeBackground", "person.crop.circle.dashed", "移除背景", "Remove background", #selector(NativeScreenshotOverlayController.removeSelectionBackground))
        ]
        for item in effects where configuration.isActionEnabled(item.0) {
            if item.0 == "removeBackground" {
                if #unavailable(macOS 14.0) { continue }
            }
            let button = NativeScreenshotToolbarChrome.iconButton(
                symbol: item.1, title: nativeScreenshotLabel(item.2, item.3),
                target: target, action: item.4)
            button.contentTintColor = configuration.iconColor
            button.frame = CGRect(x: x, y: 3, width: 32, height: 32)
            row.addSubview(button)
            x += 34
        }
        row.setFrameSize(CGSize(width: x, height: 38))
        scroll.documentView = row
        background.addSubview(scroll)
        contentView = background
        updateSelection(selectedTool)
    }

    func updateSelection(_ kind: NativeScreenshotAnnotationKind?) {
        let configuration = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
        let mainKind: NativeScreenshotAnnotationKind?
        switch kind {
        case .blur, .solidCensor, .eraseCensor:
            mainKind = kind.flatMap { configuration.isToolEnabled($0.rawValue) ? $0 : .pixelate }
        case .filledRectangle:
            mainKind = configuration.isToolEnabled("filledRectangle") ? .filledRectangle : .rectangle
        default: mainKind = kind
        }
        let wanted = mainKind.flatMap { NativeScreenshotAnnotationKind.allCases.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        for button in toolButtons {
            let selected = button.tag == wanted
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .white : configuration.iconColor
            button.layer?.backgroundColor = selected ? accent.cgColor : NSColor.clear.cgColor
        }
    }

    func updateColor(_ color: NSColor) {
        colorButton?.layer?.backgroundColor = color.cgColor
    }
}

/// Compact fixed palette for the live beautify style picker. The colors are
/// authored here independently of the former screenshot implementation.
private enum NativeScreenshotBeautifyPalette {
    static let count = 18

    static func colors(at index: Int) -> (NativeScreenshotEditorColor, NativeScreenshotEditorColor) {
        let offset = CGFloat(max(0, index) % count) / CGFloat(count)
        let top = NSColor(calibratedHue: offset, saturation: 0.75,
                          brightness: 0.98, alpha: 1).usingColorSpace(.deviceRGB)!
        let bottom = NSColor(calibratedHue: (offset + 0.17).truncatingRemainder(dividingBy: 1),
                             saturation: 0.50, brightness: 0.86, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        return (
            NativeScreenshotEditorColor(red: top.redComponent, green: top.greenComponent,
                                         blue: top.blueComponent),
            NativeScreenshotEditorColor(red: bottom.redComponent, green: bottom.greenComponent,
                                         blue: bottom.blueComponent)
        )
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotOptionPanel: NativeScreenshotSelectionPanel, NSTextFieldDelegate {
    private weak var canvas: NativeScreenshotAnnotationCanvasView?
    var onColorChanged: ((NSColor) -> Void)?
    var onToolModeChanged: ((NativeScreenshotAnnotationKind) -> Void)?
    private var tool: NativeScreenshotAnnotationKind = .pencil
    private var onText: ((String) -> Void)?
    private var arrowButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private weak var customColorWell: NSColorWell?
    private weak var clearStampButton: NSButton?
    private var adjustmentSliders: [NSSlider] = []
    private var beautifySliders: [NSSlider] = []
    private var effectSwatches: [NSButton] = []
    private var currentEffects = NativeScreenshotImageProcessor.Effects()
    private var onEffectsChanged: ((NativeScreenshotImageProcessor.Effects) -> Void)?
    private var currentBeautify = NativeScreenshotBeautifyOptions()
    private var currentBeautifyStyle = 0
    private var currentBeautifyEnabled = false
    private var onBeautifyChanged: ((NativeScreenshotBeautifyOptions, Int, Bool) -> Void)?
    private weak var beautifyModeControl: NSSegmentedControl?
    private weak var beautifyStyleButton: NSButton?
    private var beautifyPopover: NSPopover?
    private var onChooseBeautifyBackground: (() -> Void)?
    private static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]

    static func preferredWidth(for tool: NativeScreenshotAnnotationKind) -> CGFloat {
        switch tool {
        case .richText: return 1000
        case .stamp: return 790
        case .pixelate, .blur, .solidCensor, .eraseCensor: return 780
        default: return 650
        }
    }

    func installAdjustmentControls(
        initial: NativeScreenshotImageProcessor.Effects,
        onChange: @escaping (NativeScreenshotImageProcessor.Effects) -> Void
    ) {
        currentEffects = initial
        onEffectsChanged = onChange
        effectSwatches.removeAll()
        adjustmentSliders.removeAll()
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        background.layer?.backgroundColor = PreferencesManager.shared
            .nativeScreenshotToolbarConfiguration.backgroundColor.cgColor
        let width = frame.width
        let heading = effectLabel("预设", "Presets", frame: CGRect(x: 12, y: 331, width: 120, height: 17))
        background.addSubview(heading)
        for (index, preset) in NativeScreenshotImageProcessor.EffectPreset.allCases.enumerated() {
            let col = index % 4
            let row = index / 4
            let button = NSButton(image: Self.effectSwatch(for: preset), target: self,
                                  action: #selector(effectPresetSelected(_:)))
            button.tag = preset.rawValue
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.frame = CGRect(x: 13 + CGFloat(col) * 63,
                                  y: 263 - CGFloat(row) * 63, width: 52, height: 52)
            button.toolTip = preset.title
            button.setAccessibilityLabel(preset.title)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            background.addSubview(button)
            effectSwatches.append(button)
        }
        updateEffectSwatchSelection()
        let divider = NSBox(frame: CGRect(x: 12, y: 187, width: width - 24, height: 1))
        divider.boxType = .separator
        background.addSubview(divider)
        background.addSubview(effectLabel("调整", "Adjustments",
                                         frame: CGRect(x: 12, y: 166, width: 120, height: 17)))
        let values = initial.adjustments
        let entries: [(String, String, Double, Double, Double)] = [
            ("亮度", "Brightness", -0.5, 0.5, Double(values.brightness)),
            ("对比度", "Contrast", 0.5, 2, Double(values.contrast)),
            ("饱和度", "Saturation", 0, 2, Double(values.saturation)),
            ("锐度", "Sharpness", 0, 2, Double(values.sharpness))
        ]
        for (index, entry) in entries.enumerated() {
            let y = 142 - CGFloat(index) * 24
            background.addSubview(effectLabel(entry.0, entry.1,
                                             frame: CGRect(x: 12, y: y + 3, width: 72, height: 16)))
            let slider = NSSlider(value: entry.4, minValue: entry.2, maxValue: entry.3,
                                  target: self, action: #selector(imageAdjustmentChanged(_:)))
            slider.frame = CGRect(x: 85, y: y, width: width - 100, height: 22)
            slider.controlSize = .small
            slider.isContinuous = true
            slider.setAccessibilityLabel(nativeScreenshotLabel(entry.0, entry.1))
            background.addSubview(slider)
            adjustmentSliders.append(slider)
        }
        let reset = NSButton(title: nativeScreenshotLabel("重置", "Reset"), target: self,
                             action: #selector(resetEffects))
        reset.frame = CGRect(x: width - 76, y: 10, width: 62, height: 22)
        reset.controlSize = .small
        background.addSubview(reset)
        contentView = background
    }

    func installBeautifyControls(
        initial: NativeScreenshotBeautifyOptions,
        styleIndex: Int,
        enabled: Bool,
        isWindowSnap: Bool,
        onChange: @escaping (NativeScreenshotBeautifyOptions, Int, Bool) -> Void,
        onChooseCustomBackground: @escaping () -> Void
    ) {
        currentBeautify = initial
        currentBeautifyStyle = styleIndex
        currentBeautifyEnabled = enabled
        onBeautifyChanged = onChange
        onChooseBeautifyBackground = onChooseCustomBackground
        beautifySliders.removeAll()
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        background.layer?.backgroundColor = PreferencesManager.shared
            .nativeScreenshotToolbarConfiguration.backgroundColor.cgColor
        let row = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 54))
        var x: CGFloat = 12
        if !isWindowSnap {
            let mode = NSSegmentedControl(labels: ["W", "R"], trackingMode: .selectOne,
                                          target: self, action: #selector(beautifyModeChanged(_:)))
            mode.frame = CGRect(x: x, y: 16, width: 56, height: 22)
            mode.selectedSegment = initial.mode == .window ? 0 : 1
            mode.toolTip = nativeScreenshotLabel("窗口 / 圆角", "Window / rounded")
            row.addSubview(mode)
            beautifyModeControl = mode
            x += 66
            row.addSubview(effectDivider(at: x))
            x += 12
        }
        let entries: [(String, String, Double, Double, Double)] = [
            ("边距", "Padding", 16, 96, Double(initial.margin)),
            ("圆角", "Radius", 0, 30, Double(initial.cornerRadius)),
            ("阴影", "Shadow", 0, 100, Double(initial.shadowRadius))
        ]
        for (index, entry) in entries.enumerated() {
            if index == 1 && isWindowSnap { continue }
            let label = effectLabel(entry.0, entry.1,
                                    frame: CGRect(x: x, y: 19, width: 42, height: 17))
            row.addSubview(label)
            x += 43
            let slider = NSSlider(value: entry.4, minValue: entry.2, maxValue: entry.3,
                                  target: self, action: #selector(beautifySliderChanged(_:)))
            slider.tag = index
            slider.frame = CGRect(x: x, y: 15, width: 107, height: 23)
            slider.controlSize = .small
            slider.isContinuous = true
            slider.toolTip = label.stringValue
            slider.setAccessibilityLabel(label.stringValue)
            row.addSubview(slider)
            beautifySliders.append(slider)
            x += 114
        }
        if styleIndex == -1 {
            row.addSubview(effectLabel("模糊", "Blur",
                                       frame: CGRect(x: x, y: 19, width: 42, height: 17)))
            x += 43
            let blur = NSSlider(value: Double(initial.backgroundBlur), minValue: 0,
                                maxValue: 50, target: self,
                                action: #selector(beautifySliderChanged(_:)))
            blur.tag = 3
            blur.frame = CGRect(x: x, y: 15, width: 107, height: 23)
            blur.controlSize = .small
            blur.isContinuous = true
            blur.setAccessibilityLabel(nativeScreenshotLabel("背景模糊", "Background blur"))
            row.addSubview(blur)
            beautifySliders.append(blur)
            x += 114
        }
        row.addSubview(effectDivider(at: x))
        x += 12
        let swatch = NSButton(image: Self.beautifySwatch(styleIndex), target: self,
                              action: #selector(showBeautifyStyles(_:)))
        swatch.isBordered = false
        swatch.frame = CGRect(x: x, y: 15, width: 24, height: 24)
        swatch.toolTip = nativeScreenshotLabel("渐变样式", "Gradient style")
        swatch.setAccessibilityLabel(swatch.toolTip ?? "")
        row.addSubview(swatch)
        beautifyStyleButton = swatch
        x += 28
        let arrow = NSButton(image: NSImage(systemSymbolName: "chevron.down",
                                            accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(showBeautifyStyles(_:)))
        arrow.isBordered = false
        arrow.frame = CGRect(x: x, y: 19, width: 14, height: 16)
        row.addSubview(arrow)
        x += 22
        row.addSubview(effectDivider(at: x))
        x += 13
        let toggle = NSButton(checkboxWithTitle: nativeScreenshotLabel("开启", "On"), target: self,
                              action: #selector(beautifyToggleChanged(_:)))
        toggle.state = enabled ? .on : .off
        toggle.frame = CGRect(x: x, y: 16, width: 55, height: 22)
        toggle.font = .systemFont(ofSize: 10, weight: .medium)
        row.addSubview(toggle)
        row.setFrameSize(CGSize(width: max(800, x + 70), height: 54))
        let scroll = makeEffectsScroll(row: row)
        background.addSubview(scroll)
        contentView = background
    }

    private func makeEffectsScroll(row: NSView) -> NSScrollView {
        let scroll = NSScrollView(frame: CGRect(x: 5, y: 2,
                                              width: frame.width - 10, height: frame.height - 4))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = row.frame.width > scroll.frame.width
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = row
        return scroll
    }

    private func effectLabel(_ chinese: String, _ english: String, frame: CGRect) -> NSTextField {
        let label = NSTextField(labelWithString: nativeScreenshotLabel(chinese, english))
        label.frame = frame
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .labelColor
        return label
    }

    private func effectDivider(at x: CGFloat) -> NSBox {
        let divider = NSBox(frame: CGRect(x: x, y: 12, width: 1, height: 30))
        divider.boxType = .separator
        return divider
    }

    private static func effectSwatch(
        for preset: NativeScreenshotImageProcessor.EffectPreset
    ) -> NSImage {
        let size = CGSize(width: 104, height: 104)
        let sample = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.25, green: 0.55, blue: 0.92, alpha: 1),
                                NSColor(red: 0.98, green: 0.60, blue: 0.32, alpha: 1),
                                NSColor(red: 0.28, green: 0.78, blue: 0.52, alpha: 1)])?
                .draw(in: rect, angle: 135)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 12, y: 25, width: 45, height: 45)).fill()
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(rect: CGRect(x: 62, y: 20, width: 30, height: 52)).fill()
            return true
        }
        let base = sample.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let result = base.flatMap { try? NativeScreenshotImageProcessor.applyEffects(
            $0, using: .init(preset: preset)) }
        let image = NSImage(size: CGSize(width: 52, height: 52), flipped: false) { rect in
            NSImage(cgImage: result ?? base!, size: size).draw(in: rect)
            let name = preset.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor.white,
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                    shadow.shadowBlurRadius = 2
                    return shadow
                }()
            ]
            let text = name.size(withAttributes: attributes)
            name.draw(at: CGPoint(x: max(1, (rect.width - text.width) / 2), y: 4),
                      withAttributes: attributes)
            return true
        }
        return image
    }

    private func updateEffectSwatchSelection() {
        for button in effectSwatches {
            button.layer?.borderWidth = button.tag == currentEffects.preset.rawValue ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    @objc private func effectPresetSelected(_ sender: NSButton) {
        guard let preset = NativeScreenshotImageProcessor.EffectPreset(rawValue: sender.tag) else { return }
        currentEffects.preset = preset
        if preset == .none || preset == .vivid {
            currentEffects.adjustments = .init()
            let values: [Double] = [0, 1, 1, 0]
            for (slider, value) in zip(adjustmentSliders, values) { slider.doubleValue = value }
        }
        updateEffectSwatchSelection()
        onEffectsChanged?(currentEffects)
    }

    @objc private func imageAdjustmentChanged(_ sender: NSSlider) {
        guard adjustmentSliders.count == 4 else { return }
        currentEffects.preset = .none
        currentEffects.adjustments = .init(
            brightness: Float(adjustmentSliders[0].doubleValue),
            contrast: Float(adjustmentSliders[1].doubleValue),
            saturation: Float(adjustmentSliders[2].doubleValue),
            sharpness: Float(adjustmentSliders[3].doubleValue))
        updateEffectSwatchSelection()
        onEffectsChanged?(currentEffects)
    }

    @objc private func resetEffects() {
        currentEffects = .init()
        for (slider, value) in zip(adjustmentSliders, [0.0, 1.0, 1.0, 0.0]) {
            slider.doubleValue = value
        }
        updateEffectSwatchSelection()
        onEffectsChanged?(currentEffects)
    }

    @objc private func beautifyModeChanged(_ sender: NSSegmentedControl) {
        currentBeautify.mode = sender.selectedSegment == 0 ? .window : .rounded
        notifyBeautifyChanged()
    }

    @objc private func beautifySliderChanged(_ sender: NSSlider) {
        switch sender.tag {
        case 0: currentBeautify.margin = CGFloat(sender.doubleValue)
        case 1: currentBeautify.cornerRadius = CGFloat(sender.doubleValue)
        case 2: currentBeautify.shadowRadius = CGFloat(sender.doubleValue)
        case 3: currentBeautify.backgroundBlur = CGFloat(sender.doubleValue)
        default: return
        }
        notifyBeautifyChanged()
    }

    @objc private func beautifyToggleChanged(_ sender: NSButton) {
        currentBeautifyEnabled = sender.state == .on
        notifyBeautifyChanged()
    }

    private func notifyBeautifyChanged() {
        onBeautifyChanged?(currentBeautify, currentBeautifyStyle, currentBeautifyEnabled)
    }

    @objc private func showBeautifyStyles(_ sender: NSButton) {
        if beautifyPopover?.isShown == true {
            beautifyPopover?.close()
            return
        }
        let count = NativeScreenshotBeautifyPalette.count
        let hasCustom = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData") != nil
        let rows = Int(ceil(Double(count + (hasCustom ? 2 : 1)) / 6.0))
        let palette = NSView(frame: CGRect(x: 0, y: 0, width: 214,
                                          height: CGFloat(rows) * 34 + 12))
        for index in 0..<count {
            let button = NSButton(image: Self.beautifySwatch(index), target: self,
                                  action: #selector(beautifyStyleSelected(_:)))
            button.tag = index
            button.isBordered = false
            button.frame = CGRect(x: 8 + CGFloat(index % 6) * 34,
                                  y: palette.frame.height - 37 - CGFloat(index / 6) * 34,
                                  width: 28, height: 28)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = index == currentBeautifyStyle ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.toolTip = nativeScreenshotLabel("渐变 \(index + 1)", "Gradient \(index + 1)")
            button.setAccessibilityLabel(button.toolTip ?? "")
            palette.addSubview(button)
        }
        if hasCustom, let thumbnail = Self.savedCustomBackgroundSwatch() {
            let custom = NSButton(image: thumbnail, target: self,
                                  action: #selector(selectStoredBeautifyImage(_:)))
            custom.isBordered = false
            custom.frame = CGRect(x: 8 + CGFloat(count % 6) * 34,
                                  y: palette.frame.height - 37 - CGFloat(count / 6) * 34,
                                  width: 28, height: 28)
            custom.wantsLayer = true
            custom.layer?.cornerRadius = 6
            custom.layer?.borderWidth = currentBeautifyStyle == -1 ? 2 : 0
            custom.layer?.borderColor = NSColor.controlAccentColor.cgColor
            custom.toolTip = nativeScreenshotLabel("已保存的背景", "Saved background")
            palette.addSubview(custom)
        }
        let addIndex = count + (hasCustom ? 1 : 0)
        let add = NSButton(image: NSImage(systemSymbolName: "photo.badge.plus",
                                          accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(chooseBeautifyImage(_:)))
        add.isBordered = false
        add.frame = CGRect(x: 8 + CGFloat(addIndex % 6) * 34,
                           y: palette.frame.height - 37 - CGFloat(addIndex / 6) * 34,
                           width: 28, height: 28)
        add.toolTip = nativeScreenshotLabel("自定义背景图片…", "Custom background image…")
        palette.addSubview(add)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = palette.frame.size
        let controller = NSViewController()
        controller.view = palette
        popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        beautifyPopover = popover
    }

    @objc private func beautifyStyleSelected(_ sender: NSButton) {
        currentBeautifyStyle = sender.tag
        let colors = NativeScreenshotBeautifyPalette.colors(at: sender.tag)
        currentBeautify.gradientTop = colors.0
        currentBeautify.gradientBottom = colors.1
        currentBeautify.backgroundImage = nil
        currentBeautify.backgroundBlur = 0
        beautifyStyleButton?.image = Self.beautifySwatch(sender.tag)
        beautifyPopover?.close()
        notifyBeautifyChanged()
    }

    @objc private func chooseBeautifyImage(_ sender: NSButton) {
        beautifyPopover?.close()
        onChooseBeautifyBackground?()
    }

    @objc private func selectStoredBeautifyImage(_ sender: NSButton) {
        guard let bytes = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { return }
        beautifyPopover?.close()
        currentBeautify.backgroundBlur = CGFloat(
            UserDefaults.standard.double(forKey: "beautifyBgBlur"))
        selectCustomBeautifyImage(image)
    }

    private static func savedCustomBackgroundSwatch() -> NSImage? {
        guard let bytes = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 56
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: 28, height: 28))
    }

    func selectCustomBeautifyImage(_ image: CGImage) {
        currentBeautifyStyle = -1
        currentBeautify.backgroundImage = image
        beautifyStyleButton?.image = NSImage(cgImage: image, size: CGSize(width: 24, height: 24))
        notifyBeautifyChanged()
    }

    private static func beautifySwatch(_ index: Int) -> NSImage {
        let colors = NativeScreenshotBeautifyPalette.colors(at: index)
        return NSImage(size: CGSize(width: 28, height: 28), flipped: false) { rect in
            let top = NSColor(red: colors.0.red, green: colors.0.green,
                              blue: colors.0.blue, alpha: 1)
            let bottom = NSColor(red: colors.1.red, green: colors.1.green,
                                 blue: colors.1.blue, alpha: 1)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                    xRadius: 6, yRadius: 6)
            NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 135)
            return true
        }
    }

    func installControls(tool: NativeScreenshotAnnotationKind,
                         canvas: NativeScreenshotAnnotationCanvasView,
                         text: String, onText: @escaping (String) -> Void) {
        self.tool = tool
        self.canvas = canvas
        self.onText = onText
        colorButtons.removeAll()
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        let toolbarColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
        background.layer?.backgroundColor = toolbarColor.backgroundColor.cgColor
        let contentWidth = Self.preferredWidth(for: tool)
        let scroll = NSScrollView(frame: CGRect(x: 5, y: 4,
                                              width: frame.width - 10, height: frame.height - 8))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = contentWidth > frame.width - 10
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .automatic
        let row = NSView(frame: CGRect(x: 0, y: 0, width: contentWidth, height: 46))
        var x: CGFloat = 10
        let title = NSTextField(labelWithString: nativeScreenshotLabel("工具选项", "Tool options"))
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.frame = CGRect(x: x, y: 16, width: 58, height: 18)
        row.addSubview(title)
        x += 62

        for (index, color) in Self.colors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(chooseColor(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 10
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
            button.frame = CGRect(x: x, y: 16, width: 20, height: 20)
            button.toolTip = nativeScreenshotLabel("选择颜色", "Choose color")
            button.setAccessibilityLabel(button.toolTip ?? "")
            row.addSubview(button)
            colorButtons.append(button)
            x += 24
        }
        let custom = NativeScreenshotOverlayColorWell(frame: CGRect(x: x, y: 13, width: 31, height: 26))
        custom.color = NSColor(cgColor: canvas.style.strokeColor.cgColor) ?? .systemRed
        custom.target = self
        custom.action = #selector(customColorChanged(_:))
        custom.toolTip = nativeScreenshotLabel("自选颜色", "Custom color")
        row.addSubview(custom)
        customColorWell = custom
        x += 38
        updateColorSelection(custom.color)

        let width = NSSlider(value: Double(canvas.style.lineWidth), minValue: 1,
                             maxValue: 30, target: self, action: #selector(sliderChanged(_:)))
        width.frame = CGRect(x: x, y: 12, width: 78, height: 25)
        width.toolTip = nativeScreenshotLabel("线条宽度", "Line width")
        width.setAccessibilityLabel(width.toolTip ?? "")
        row.addSubview(width)
        x += 84

        switch tool {
        case .arrow:
            let shapes = ["↗", "⇢", "⤴", "⤴⋯", "〰", "↔"]
            let names = [
                nativeScreenshotLabel("实线", "Solid"),
                nativeScreenshotLabel("虚线", "Dashed"),
                nativeScreenshotLabel("弯曲", "Curved"),
                nativeScreenshotLabel("弯曲虚线", "Curved dashed"),
                nativeScreenshotLabel("手绘", "Sketch"),
                nativeScreenshotLabel("双向", "Double")
            ]
            for index in shapes.indices {
                let button = NSButton(title: shapes[index], target: self,
                                      action: #selector(arrowStyleChosen(_:)))
                button.tag = index
                button.setButtonType(.toggle)
                button.state = canvas.arrowStyle.rawValue == index ? .on : .off
                button.font = .systemFont(ofSize: 16, weight: .medium)
                button.isBordered = false
                button.frame = CGRect(x: x + CGFloat(index) * 34, y: 8,
                                      width: 32, height: 32)
                button.toolTip = names[index]
                button.setAccessibilityLabel(names[index])
                row.addSubview(button)
                arrowButtons.append(button)
            }
        case .richText, .stamp:
            let field = NSTextField(frame: CGRect(x: x, y: 13, width: 118, height: 25))
            field.stringValue = text
            field.placeholderString = tool == .stamp
                ? nativeScreenshotLabel("表情图章", "Emoji stamp")
                : nativeScreenshotLabel("输入文字", "Type text")
            field.delegate = self
            field.toolTip = field.placeholderString
            row.addSubview(field)
            if tool == .richText {
                let styles: [(String, String, String, Bool, Selector)] = [
                    ("B", "粗体", "Bold", canvas.textBold, #selector(toggleBold(_:))),
                    ("I", "斜体", "Italic", canvas.textItalic, #selector(toggleItalic(_:))),
                    ("U", "下划线", "Underline", canvas.textUnderline, #selector(toggleUnderline(_:)))
                ]
                for (index, item) in styles.enumerated() {
                    let button = NSButton(title: item.0, target: self, action: item.4)
                    button.setButtonType(.toggle)
                    button.state = item.3 ? .on : .off
                    button.frame = CGRect(x: x + 120 + CGFloat(index) * 27,
                                          y: 11, width: 26, height: 27)
                    button.toolTip = nativeScreenshotLabel(item.1, item.2)
                    button.setAccessibilityLabel(button.toolTip ?? "")
                    row.addSubview(button)
                }
                let outline = NSButton(checkboxWithTitle: nativeScreenshotLabel("描边", "Outline"),
                    target: self, action: #selector(toggleOutline(_:)))
                outline.state = canvas.textOutlineWidth > 0 ? .on : .off
                outline.frame = CGRect(x: x + 202, y: 10, width: 75, height: 28)
                outline.toolTip = nativeScreenshotLabel("文字描边", "Text outline")
                row.addSubview(outline)
                let backgroundCheck = NSButton(
                    checkboxWithTitle: nativeScreenshotLabel("背景", "BG"),
                    target: self, action: #selector(toggleTextBackground(_:)))
                backgroundCheck.state = canvas.textBackgroundEnabled ? .on : .off
                backgroundCheck.frame = CGRect(x: x + 280, y: 10, width: 70, height: 28)
                backgroundCheck.toolTip = nativeScreenshotLabel("文字背景", "Text background")
                row.addSubview(backgroundCheck)
                let backgroundColor = NativeScreenshotOverlayColorWell(frame: CGRect(x: x + 353, y: 13,
                                                               width: 30, height: 25))
                backgroundColor.color = NSColor(cgColor: canvas.textBackgroundColor.cgColor) ?? .yellow
                backgroundColor.target = self
                backgroundColor.action = #selector(textBackgroundColorChanged(_:))
                backgroundColor.toolTip = nativeScreenshotLabel("背景颜色", "Background color")
                row.addSubview(backgroundColor)
                let size = NSTextField(frame: CGRect(x: x + 388, y: 13, width: 45, height: 25))
                size.stringValue = String(Int(canvas.textFontSize.rounded()))
                size.alignment = .center
                size.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                size.target = self
                size.action = #selector(fontSizeChanged(_:))
                size.toolTip = nativeScreenshotLabel("字号，回车应用", "Font size; press Return")
                row.addSubview(size)
                let font = NSPopUpButton(frame: CGRect(x: x + 438, y: 11,
                                                     width: 160, height: 28), pullsDown: false)
                let currentName = canvas.textFontName
                font.addItem(withTitle: nativeScreenshotLabel("系统字体", "System font"))
                for family in NSFontManager.shared.availableFontFamilies.sorted() {
                    guard let fontName = NSFontManager.shared.availableMembers(
                        ofFontFamily: family)?.first?.first as? String else { continue }
                    font.addItem(withTitle: family)
                    font.lastItem?.representedObject = fontName
                }
                if let currentName,
                   !font.itemArray.contains(where: { $0.representedObject as? String == currentName }) {
                    font.addItem(withTitle: currentName)
                    font.lastItem?.representedObject = currentName
                }
                if let currentName,
                   let selected = font.itemArray.first(where: { $0.representedObject as? String == currentName }) {
                    font.select(selected)
                } else {
                    font.selectItem(at: 0)
                }
                font.target = self
                font.action = #selector(fontChanged(_:))
                font.toolTip = nativeScreenshotLabel("字体", "Font")
                row.addSubview(font)
            } else {
                let imageButton = NSButton(title: nativeScreenshotLabel("导入图片", "Import image"),
                    target: self, action: #selector(importStampImage(_:)))
                imageButton.frame = CGRect(x: x + 124, y: 11, width: 88, height: 27)
                imageButton.toolTip = nativeScreenshotLabel("使用图片图章", "Use image stamp")
                row.addSubview(imageButton)
                let clearButton = NSButton(title: nativeScreenshotLabel("清除图片", "Clear image"),
                    target: self, action: #selector(clearStampImage(_:)))
                clearButton.frame = CGRect(x: x + 216, y: 11, width: 88, height: 27)
                clearButton.isEnabled = canvas.stampImage != nil
                clearButton.toolTip = nativeScreenshotLabel("改回表情图章", "Use emoji stamp")
                row.addSubview(clearButton)
                clearStampButton = clearButton
            }
        case .pixelate, .blur, .solidCensor, .eraseCensor:
            let modes: [(NativeScreenshotAnnotationKind, String, String)] = [
                (.pixelate, "马赛克", "Pixelate"),
                (.blur, "模糊", "Blur"),
                (.solidCensor, "纯色", "Solid"),
                (.eraseCensor, "擦除", "Erase")
            ]
            for (index, mode) in modes.enumerated() {
                let button = NSButton(title: nativeScreenshotLabel(mode.1, mode.2),
                                      target: self, action: #selector(censorModeChosen(_:)))
                button.tag = index
                button.setButtonType(.toggle)
                button.state = tool == mode.0 ? .on : .off
                button.frame = CGRect(x: x + CGFloat(index) * 72, y: 11,
                                      width: 68, height: 27)
                row.addSubview(button)
            }
            if tool == .pixelate || tool == .blur {
                let slider = NSSlider(value: tool == .pixelate ? Double(canvas.pixelBlockSize)
                                        : Double(canvas.blurRadius),
                                      minValue: 3, maxValue: 32,
                                      target: self, action: #selector(effectSliderChanged(_:)))
                slider.frame = CGRect(x: x + 296, y: 12, width: 90, height: 25)
                slider.toolTip = nativeScreenshotLabel("效果强度", "Effect strength")
                row.addSubview(slider)
            }
        case .magnifier:
            let slider = NSSlider(value: Double(canvas.magnifierScale) * 10,
                                  minValue: 3, maxValue: 32,
                                  target: self, action: #selector(effectSliderChanged(_:)))
            slider.frame = CGRect(x: x, y: 12, width: 112, height: 25)
            slider.toolTip = nativeScreenshotLabel("放大倍数", "Magnification")
            row.addSubview(slider)
        case .rectangle, .filledRectangle:
            let rectangleModes: [(NativeScreenshotAnnotationKind, String, String)] = [
                (.rectangle, "轮廓", "Outline"),
                (.filledRectangle, "填充", "Fill")
            ]
            for (index, mode) in rectangleModes.enumerated() {
                let button = NSButton(title: nativeScreenshotLabel(mode.1, mode.2),
                                      target: self, action: #selector(rectangleModeChosen(_:)))
                button.tag = index
                button.setButtonType(.toggle)
                button.state = tool == mode.0 ? .on : .off
                button.frame = CGRect(x: x + CGFloat(index) * 76, y: 11,
                                      width: 72, height: 27)
                row.addSubview(button)
            }
        case .pencil:
            let popup = NSPopUpButton(frame: CGRect(x: x, y: 12, width: 120, height: 27), pullsDown: false)
            popup.addItems(withTitles: [nativeScreenshotLabel("无平滑", "No smoothing"),
                                        nativeScreenshotLabel("平滑", "Smooth"),
                                        nativeScreenshotLabel("精细", "Refined")])
            popup.selectItem(at: canvas.pencilSmoothing.rawValue)
            popup.target = self
            popup.action = #selector(smoothingChanged(_:))
            row.addSubview(popup)
        case .highlighter:
            let check = NSButton(checkboxWithTitle: nativeScreenshotLabel("智能宽度", "Smart width"),
                                 target: self, action: #selector(smartMarkerChanged(_:)))
            check.state = canvas.smartMarkerEnabled ? .on : .off
            check.frame = CGRect(x: x, y: 11, width: 120, height: 28)
            row.addSubview(check)
        default: break
        }
        scroll.documentView = row
        background.addSubview(scroll)
        contentView = background
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        onText?(field.stringValue)
    }

    @objc private func chooseColor(_ sender: NSButton) {
        guard Self.colors.indices.contains(sender.tag) else { return }
        setColor(Self.colors[sender.tag])
    }

    @objc private func customColorChanged(_ sender: NSColorWell) { setColor(sender.color) }

    private func setColor(_ color: NSColor) {
        guard let rgba = color.usingColorSpace(.sRGB) else { return }
        let value = NativeScreenshotColor(red: rgba.redComponent, green: rgba.greenComponent,
                                          blue: rgba.blueComponent, alpha: rgba.alphaComponent)
        canvas?.style.strokeColor = value
        canvas?.style.fillColor = value
        _ = canvas?.updateSelectedRichTextStyle()
        customColorWell?.color = color
        updateColorSelection(color)
        onColorChanged?(color)
    }

    private func updateColorSelection(_ color: NSColor) {
        let selected = color.usingColorSpace(.sRGB)
        for (index, button) in colorButtons.enumerated() {
            let sample = Self.colors[index].usingColorSpace(.sRGB)
            let matches = selected != nil && sample != nil &&
                abs(selected!.redComponent - sample!.redComponent) < 0.015 &&
                abs(selected!.greenComponent - sample!.greenComponent) < 0.015 &&
                abs(selected!.blueComponent - sample!.blueComponent) < 0.015
            button.layer?.borderWidth = matches ? 3 : 1
            button.layer?.borderColor = matches
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.55).cgColor
            button.setAccessibilityValue(matches ? nativeScreenshotLabel("已选中", "Selected") : "")
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        canvas?.style.lineWidth = CGFloat(sender.doubleValue)
    }

    @objc private func effectSliderChanged(_ sender: NSSlider) {
        switch tool {
        case .pixelate: canvas?.pixelBlockSize = CGFloat(sender.doubleValue)
        case .blur: canvas?.blurRadius = CGFloat(sender.doubleValue)
        case .magnifier: canvas?.magnifierScale = CGFloat(sender.doubleValue / 10)
        default: break
        }
    }

    @objc private func censorModeChosen(_ sender: NSButton) {
        let modes: [NativeScreenshotAnnotationKind] = [.pixelate, .blur, .solidCensor, .eraseCensor]
        guard modes.indices.contains(sender.tag) else { return }
        onToolModeChanged?(modes[sender.tag])
    }

    @objc private func rectangleModeChosen(_ sender: NSButton) {
        onToolModeChanged?(sender.tag == 1 ? .filledRectangle : .rectangle)
    }

    @objc private func arrowStyleChosen(_ sender: NSButton) {
        canvas?.arrowStyle = NativeScreenshotArrowStyle(rawValue: sender.tag) ?? .solid
        for button in arrowButtons { button.state = button.tag == sender.tag ? .on : .off }
    }

    @objc private func smoothingChanged(_ sender: NSPopUpButton) {
        canvas?.pencilSmoothing = NativeScreenshotPencilSmoothing(rawValue: sender.indexOfSelectedItem) ?? .smooth
    }

    @objc private func toggleBold(_ sender: NSButton) {
        canvas?.textBold = sender.state == .on
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func toggleItalic(_ sender: NSButton) {
        canvas?.textItalic = sender.state == .on
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func toggleUnderline(_ sender: NSButton) {
        canvas?.textUnderline = sender.state == .on
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func toggleOutline(_ sender: NSButton) {
        canvas?.textOutlineWidth = sender.state == .on ? 1 : 0
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func toggleTextBackground(_ sender: NSButton) {
        canvas?.textBackgroundEnabled = sender.state == .on
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func textBackgroundColorChanged(_ sender: NSColorWell) {
        guard let rgba = sender.color.usingColorSpace(.sRGB) else { return }
        canvas?.textBackgroundColor = NativeScreenshotColor(
            red: rgba.redComponent, green: rgba.greenComponent,
            blue: rgba.blueComponent, alpha: rgba.alphaComponent
        )
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func fontSizeChanged(_ sender: NSTextField) {
        guard let size = Double(sender.stringValue), size.isFinite else {
            NSSound.beep()
            return
        }
        let clamped = max(10, min(96, size))
        sender.stringValue = String(Int(clamped.rounded()))
        canvas?.textFontSize = CGFloat(clamped)
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        canvas?.textFontName = sender.indexOfSelectedItem == 0
            ? nil : sender.selectedItem?.representedObject as? String
        _ = canvas?.updateSelectedRichTextStyle()
    }

    @objc private func importStampImage(_ sender: NSButton) {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.prompt = nativeScreenshotLabel("导入", "Import")
        // The capture overlay sits at screenSaver level. Keep the user's file
        // picker above it so the import action remains reachable.
        picker.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [String: Any],
                  let width = (metadata[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
                  let height = (metadata[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= 8_192, height <= 8_192,
                  width <= 16_000_000 / height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                self.showStampImportError()
                return
            }
            self.canvas?.stampImage = image
            self.clearStampButton?.isEnabled = true
        }
    }

    @objc private func clearStampImage(_ sender: NSButton) {
        canvas?.stampImage = nil
        sender.isEnabled = false
    }

    private func showStampImportError() {
        let alert = NSAlert()
        alert.messageText = nativeScreenshotLabel("无法导入图片图章", "Cannot import image stamp")
        alert.informativeText = nativeScreenshotLabel(
            "请选择有效的图片，宽高不超过 8192 像素且总像素不超过 1600 万。",
            "Choose a valid image up to 8192 pixels per side and 16 million pixels in total."
        )
        alert.alertStyle = .warning
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        alert.beginSheetModal(for: self)
    }

    @objc private func smartMarkerChanged(_ sender: NSButton) {
        canvas?.smartMarkerEnabled = sender.state == .on
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotSizePanel: NativeScreenshotSelectionPanel, NSTextFieldDelegate {
    private weak var widthField: NSTextField?
    private weak var heightField: NSTextField?
    private var onResize: ((Int, Int) -> Void)?
    private var onPresetRequested: ((NSView) -> Void)?
    private var lockedSelectionRatio: CGFloat?
    private var pixelsPerPoint: CGFloat = 1
    private var unitIsPoints = false
    private var suppressNextEndEditingCommit = false

    func install(widthPixels: Int, heightPixels: Int,
                 preset: NativeScreenshotSelectionPreset,
                 pixelsPerPoint: CGFloat, unitIsPoints: Bool,
                 onPresetRequested: @escaping (NSView) -> Void,
                 onResize: @escaping (Int, Int) -> Void) {
        self.onResize = onResize
        self.onPresetRequested = onPresetRequested
        lockedSelectionRatio = preset.aspectRatio
        self.pixelsPerPoint = pixelsPerPoint
        self.unitIsPoints = unitIsPoints
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        let configuration = PreferencesManager.shared.nativeScreenshotToolbarConfiguration
        background.layer?.backgroundColor = configuration.backgroundColor.cgColor
        let width = numberField(value: NativeScreenshotSelectionSizing.displayedDimension(
            pixels: widthPixels, pixelsPerPoint: pixelsPerPoint, unitIsPoints: unitIsPoints),
            frame: CGRect(x: 9, y: 7, width: 55, height: 24))
        widthField = width
        background.addSubview(width)
        let times = NSTextField(labelWithString: "×")
        times.alignment = .center
        times.textColor = .secondaryLabelColor
        times.frame = CGRect(x: 65, y: 9, width: 15, height: 20)
        background.addSubview(times)
        let height = numberField(value: NativeScreenshotSelectionSizing.displayedDimension(
            pixels: heightPixels, pixelsPerPoint: pixelsPerPoint, unitIsPoints: unitIsPoints),
            frame: CGRect(x: 81, y: 7, width: 55, height: 24))
        heightField = height
        background.addSubview(height)
        let label = preset == .freeform ? nativeScreenshotLabel("自由", "Freeform") : preset.title
        let button = NSButton(title: "\(label)  ▾", target: self, action: #selector(showPresets(_:)))
        button.frame = CGRect(x: 139, y: 5, width: 125, height: 28)
        button.bezelStyle = .rounded
        button.toolTip = nativeScreenshotLabel("选区比例与精确像素", "Aspect ratio and exact pixel presets")
        background.addSubview(button)
        contentView = background
    }

    func updateUnitDisplay(widthPixels: Int, heightPixels: Int, unitIsPoints: Bool) {
        self.unitIsPoints = unitIsPoints
        widthField?.integerValue = NativeScreenshotSelectionSizing.displayedDimension(
            pixels: widthPixels, pixelsPerPoint: pixelsPerPoint, unitIsPoints: unitIsPoints)
        heightField?.integerValue = NativeScreenshotSelectionSizing.displayedDimension(
            pixels: heightPixels, pixelsPerPoint: pixelsPerPoint, unitIsPoints: unitIsPoints)
    }

    private func numberField(value: Int, frame: CGRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = String(value)
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.formatter = NumberFormatter()
        field.delegate = self
        field.toolTip = nativeScreenshotLabel("回车应用宽高", "Press Return to apply")
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if suppressNextEndEditingCommit {
            suppressNextEndEditingCommit = false
            return
        }
        applyDimensions(edited: editedDimension(for: obj.object))
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.cancelOperation(_:)) {
            suppressNextEndEditingCommit = true
            applyDimensions(edited: editedDimension(for: control))
            makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func editedDimension(for control: Any?) -> NativeScreenshotEditedDimension {
        guard let control = control as? NSTextField else { return .width }
        return control === heightField ? .height : .width
    }

    @objc private func showPresets(_ sender: NSButton) { onPresetRequested?(sender) }

    private func applyDimensions(edited: NativeScreenshotEditedDimension) {
        guard let widthField, let heightField,
              let width = Int(widthField.stringValue), width >= 4,
              let height = Int(heightField.stringValue), height >= 4 else {
            NSSound.beep()
            return
        }
        let adjusted = NativeScreenshotSelectionSizing.pixels(
            width: width, height: height, aspectRatio: lockedSelectionRatio, edited: edited)
        onResize?(
            NativeScreenshotSelectionSizing.pixelDimension(
                displayed: adjusted.width, pixelsPerPoint: pixelsPerPoint, unitIsPoints: unitIsPoints),
            NativeScreenshotSelectionSizing.pixelDimension(
                displayed: adjusted.height, pixelsPerPoint: pixelsPerPoint, unitIsPoints: unitIsPoints))
    }
}

@available(macOS 13.0, *)
private final class NativeScreenshotPresetPanel: NativeScreenshotSelectionPanel {
    struct Choice {
        let title: String
        let preset: NativeScreenshotSelectionPreset
        let selected: Bool
    }

    private var choices: [NativeScreenshotSelectionPreset] = []
    private var onChoice: ((NativeScreenshotSelectionPreset) -> Void)?
    private var onKeepRatio: ((Bool) -> Void)?
    private var onUnit: ((Bool) -> Void)?

    static func preferredSize(ratioCount: Int, showsUnits: Bool) -> CGSize {
        CGSize(width: 302, height: 12 + 20 + CGFloat(max(ratioCount, 7)) * 25
            + (showsUnits ? 66 : 40))
    }

    func install(ratios: [Choice], resolutions: [Choice], keepRatio: Bool,
                 unitIsPoints: Bool, showsUnits: Bool,
                 onChoice: @escaping (NativeScreenshotSelectionPreset) -> Void,
                 onKeepRatio: @escaping (Bool) -> Void,
                 onUnit: @escaping (Bool) -> Void) {
        self.onChoice = onChoice
        self.onKeepRatio = onKeepRatio
        self.onUnit = onUnit
        let background = NativeScreenshotToolbarChrome(frame: CGRect(origin: .zero, size: frame.size))
        background.layer?.backgroundColor = PreferencesManager.shared
            .nativeScreenshotToolbarConfiguration.backgroundColor.cgColor
        contentView = background
        let headerY = frame.height - 31
        let titleColor = PreferencesManager.shared.nativeScreenshotToolbarConfiguration.iconColor
        for (x, title) in [(10.0, nativeScreenshotLabel("比例", "Aspect ratio")),
                           (156.0, nativeScreenshotLabel("精确像素", "Pixel resolution"))] {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = titleColor.withAlphaComponent(0.7)
            label.frame = CGRect(x: x + 7, y: headerY, width: 130, height: 18)
            background.addSubview(label)
        }
        let divider = NSView(frame: CGRect(x: 150, y: 42, width: 1,
                                           height: frame.height - 54))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = titleColor.withAlphaComponent(0.2).cgColor
        background.addSubview(divider)
        for (index, choice) in ratios.enumerated() {
            addRow(choice, x: 10, y: headerY - 25 - CGFloat(index) * 25,
                   to: background, color: titleColor)
        }
        for (index, choice) in resolutions.enumerated() {
            addRow(choice, x: 156, y: headerY - 25 - CGFloat(index) * 25,
                   to: background, color: titleColor)
        }
        let footerLineY: CGFloat = showsUnits ? 65 : 39
        let footerLine = NSView(frame: CGRect(x: 10, y: footerLineY, width: 282, height: 1))
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = titleColor.withAlphaComponent(0.2).cgColor
        background.addSubview(footerLine)

        let keepLabel = NSTextField(labelWithString:
            nativeScreenshotLabel("下次截图保持比例", "Keep ratio for next captures"))
        keepLabel.font = .systemFont(ofSize: 11)
        keepLabel.textColor = titleColor
        keepLabel.frame = CGRect(x: 17, y: showsUnits ? 39 : 13,
                                 width: 225, height: 19)
        background.addSubview(keepLabel)
        let keep = NSSwitch()
        keep.state = keepRatio ? .on : .off
        keep.target = self
        keep.action = #selector(toggleKeepRatio(_:))
        keep.frame.origin = CGPoint(x: 250, y: showsUnits ? 35 : 9)
        background.addSubview(keep)

        if showsUnits {
            let unitLabel = NSTextField(labelWithString: nativeScreenshotLabel("单位", "Units"))
            unitLabel.font = .systemFont(ofSize: 11)
            unitLabel.textColor = titleColor
            unitLabel.frame = CGRect(x: 17, y: 11, width: 70, height: 19)
            background.addSubview(unitLabel)
            let unit = NSSegmentedControl(labels: ["px", "pt"], trackingMode: .selectOne,
                                          target: self, action: #selector(changeUnit(_:)))
            unit.selectedSegment = unitIsPoints ? 1 : 0
            unit.frame = CGRect(x: 208, y: 7, width: 80, height: 23)
            background.addSubview(unit)
        }
    }

    private func addRow(_ choice: Choice, x: CGFloat, y: CGFloat,
                        to background: NSView, color: NSColor) {
        let button = NSButton(title: (choice.selected ? "✓  " : "    ") + choice.title,
                              target: self, action: #selector(selectPreset(_:)))
        button.tag = choices.count
        choices.append(choice.preset)
        button.frame = CGRect(x: x, y: y, width: 137, height: 24)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 12, weight: choice.selected ? .semibold : .regular)
        button.contentTintColor = choice.selected
            ? PreferencesManager.shared.nativeScreenshotToolbarConfiguration.accentColor : color
        background.addSubview(button)
    }

    @objc private func selectPreset(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag) else { return }
        onChoice?(choices[sender.tag])
    }

    @objc private func toggleKeepRatio(_ sender: NSSwitch) {
        onKeepRatio?(sender.state == .on)
    }

    @objc private func changeUnit(_ sender: NSSegmentedControl) {
        onUnit?(sender.selectedSegment == 1)
    }
}

@available(macOS 13.0, *)
private class NativeScreenshotToolbarChrome: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    static func iconButton(symbol: String, title: String,
                           target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        if symbol == "checkerboard" {
            button.image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
                for row in 0..<4 {
                    for column in 0..<4 {
                        NSColor.white.withAlphaComponent((row + column).isMultiple(of: 2) ? 0.95 : 0.24)
                            .setFill()
                        NSBezierPath(rect: NSRect(x: CGFloat(column * 5), y: CGFloat(row * 5),
                                                  width: 5, height: 5)).fill()
                    }
                }
                return true
            }
        } else {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }
}

private func nativeScreenshotLabel(_ chinese: String, _ english: String) -> String {
    let raw = UserDefaults.standard.string(forKey: "appLanguage")
    let useChinese = raw == "zh" || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    return useChinese ? chinese : english
}

@available(macOS 13.0, *)
private final class NativeScreenshotSelectionView: NSView {
    let image: CGImage
    let displayFrame: CGRect
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var hoveredElement: CGRect? { didSet { needsDisplay = true } }
    var guideX: CGFloat? { didSet { needsDisplay = true } }
    var guideY: CGFloat? { didSet { needsDisplay = true } }
    var pointer: CGPoint? { didSet { needsDisplay = true } }
    var showsMagnifier = false
    var elementSnapHint = false
    var selectionAccent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var showsPreselectionPreset = false {
        didSet {
            presetButton.isHidden = !showsPreselectionPreset
            needsDisplay = true
        }
    }
    var preselectionPresetActive = false {
        didSet {
            presetButton.contentTintColor = preselectionPresetActive
                ? selectionAccent : .white
        }
    }
    var onPresetRequested: ((NSView) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDrag: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onMouseMove: ((CGPoint) -> Void)?
    var onRightMouseDown: ((CGPoint) -> Void)?
    var onConfirm: (() -> Void)?
    private lazy var presetButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(openPresets(_:)))
        button.frame = CGRect(x: bounds.midX - 17, y: bounds.midY + 10,
                              width: 34, height: 28)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.toolTip = nativeScreenshotLabel("选区比例与精确像素", "Aspect ratio and exact pixel presets")
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.layer?.cornerRadius = 6
        button.isHidden = true
        return button
    }()

    init(image: CGImage, displayFrame: CGRect) {
        self.image = image
        self.displayFrame = displayFrame
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        addSubview(presetButton)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let selection,
              NativeScreenshotCaptureGeometry.intersection(
                  selection, displayFrame: displayFrame) != nil else { return }
        let local = selection.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        let interior = local.insetBy(dx: 9, dy: 9).intersection(bounds)
        if !interior.isNull { addCursorRect(interior, cursor: .openHand) }
        let anchors: [(CGPoint, NSCursor)] = [
            (CGPoint(x: local.minX, y: local.minY), .crosshair),
            (CGPoint(x: local.midX, y: local.minY), .resizeUpDown),
            (CGPoint(x: local.maxX, y: local.minY), .crosshair),
            (CGPoint(x: local.maxX, y: local.midY), .resizeLeftRight),
            (CGPoint(x: local.maxX, y: local.maxY), .crosshair),
            (CGPoint(x: local.midX, y: local.maxY), .resizeUpDown),
            (CGPoint(x: local.minX, y: local.maxY), .crosshair),
            (CGPoint(x: local.minX, y: local.midY), .resizeLeftRight)
        ]
        for (point, cursor) in anchors {
            guard bounds.insetBy(dx: -7, dy: -7).contains(point) else { continue }
            addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14),
                          cursor: cursor)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        guard let selection,
              let visible = NativeScreenshotCaptureGeometry.intersection(selection, displayFrame: displayFrame) else {
            NSColor.black.withAlphaComponent(0.42).setFill()
            bounds.fill()
            drawAids()
            if showsPreselectionPreset {
                let prompt = nativeScreenshotLabel("拖动框选区域", "Drag to select an area")
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
                let size = (prompt as NSString).size(withAttributes: attributes)
                let card = CGRect(x: bounds.midX - max(110, size.width / 2 + 16),
                                  y: bounds.midY - 31,
                                  width: max(220, size.width + 32), height: 76)
                NSColor.black.withAlphaComponent(0.65).setFill()
                NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
                (prompt as NSString).draw(
                    at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - 21),
                    withAttributes: attributes)
            }
            return
        }

        let cut = visible.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        NSColor.black.withAlphaComponent(0.48).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: max(0, cut.minY)).fill()
        CGRect(x: 0, y: cut.maxY, width: bounds.width, height: max(0, bounds.maxY - cut.maxY)).fill()
        CGRect(x: 0, y: cut.minY, width: max(0, cut.minX), height: cut.height).fill()
        CGRect(x: cut.maxX, y: cut.minY, width: max(0, bounds.maxX - cut.maxX), height: cut.height).fill()
        selectionAccent.setStroke()
        let border = NSBezierPath(rect: cut)
        border.lineWidth = 2
        border.stroke()
        drawResizeHandles(for: selection)
        drawDimensions(for: selection, in: cut)
        drawAids()
    }

    private func drawResizeHandles(for selection: CGRect) {
        let rect = selection.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        let anchors = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)
        ]
        for anchor in anchors {
            guard bounds.insetBy(dx: -5, dy: -5).contains(anchor) else { continue }
            let handle = CGRect(x: anchor.x - 5, y: anchor.y - 5, width: 10, height: 10)
            selectionAccent.setFill()
            NSBezierPath(ovalIn: handle).fill()
            NSColor.white.setStroke()
            let stroke = NSBezierPath(ovalIn: handle)
            stroke.lineWidth = 1.25
            stroke.stroke()
        }
    }

    private func drawDimensions(for selection: CGRect, in visible: CGRect) {
        let scale = CGFloat(image.width) / max(1, displayFrame.width)
        let width = Int((selection.width * scale).rounded())
        let height = Int((selection.height * scale).rounded())
        let label = "\(width) × \(height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: min(max(6, visible.minX + 8), max(6, bounds.maxX - size.width - 14)),
                             y: visible.minY >= size.height + 16 ? visible.minY - size.height - 13
                                : visible.minY + 8)
        let background = CGRect(x: origin.x - 5, y: origin.y - 3,
                                width: size.width + 10, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: origin, withAttributes: attributes)
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
    override func mouseDragged(with event: NSEvent) {
        onMouseDrag?(globalPoint(event), event.modifierFlags)
    }
    override func mouseUp(with event: NSEvent) { onMouseUp?(globalPoint(event)) }
    override func mouseMoved(with event: NSEvent) { onMouseMove?(globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { onRightMouseDown?(globalPoint(event)) }
    @objc private func openPresets(_ sender: NSButton) { onPresetRequested?(sender) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onConfirm?() }
        else { super.keyDown(with: event) }
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: displayFrame.minX + local.x, y: displayFrame.minY + local.y)
    }
}
