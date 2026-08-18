import AppKit
import Foundation
import ScreenCaptureKit
import Vision

/// Drives the macshot capture pipeline inside clipy1.
///
/// Mirrors macshot's `AppDelegate` capture flow (startCapture → performCapture →
/// installAndShowOverlays) but is scoped to screenshots only — no menu bar, no
/// settings, no Sparkle. One overlay controller is kept alive per screen so the
/// NSPanel surface is reused across sessions for instant warm captures.
///
/// Confirmation routes back into clipy1's own store:
///   - `ClipboardManager.ingestCapturedImage` (history + sync)
///   - `ScreenshotSaveService` (auto-save)
///   - `PinPanelController` (pin to screen)
///   - `ImageOCRService` (OCR result window)
@MainActor
final class ScreenshotSessionCoordinator {

    // MARK: - Singleton

    static let shared = ScreenshotSessionCoordinator()

    // MARK: - State

    /// Re-entry guard — true while a capture session is live.
    private(set) var isCapturing = false
    /// Bumped each time a capture starts; lets stale async callbacks detect they're stale.
    private var captureSessionID = 0
    /// The app that was frontmost when the capture was triggered (restored on dismiss).
    private var previousApp: NSRunningApplication?
    /// One overlay controller per screen, kept alive for the app's lifetime (warm capture).
    private var overlayControllerPool: [ObjectIdentifier: OverlayWindowController] = [:]
    /// Active controllers for the current session (subset of the pool, one per screen).
    private var activeControllers: [OverlayWindowController] = []
    /// Stitched full image during a cross-screen drag, or nil.
    private var crossScreenImage: NSImage?
    /// Caption / window title captured for save-file naming + history.
    private var capturedWindowTitle: String?
    /// Retains the OCR result window; released via its `onClose`.
    private var ocrResultController: OCRResultController?

    private init() {
        // NSScreen identity (ObjectIdentifier) changes when a display is
        // unplugged/reconfigured or after sleep. Pooled controllers keyed by a
        // dead screen would otherwise accumulate forever (a fullscreen panel +
        // view tree each), so prune them on every configuration change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneStaleOverlayControllers()
            }
        }
    }

    // MARK: - Public entry points

    enum Mode {
        case region       // selection overlay (default)
        case window       // selection overlay, starts in window-snap mode
        case fullscreen   // immediate capture, no overlay
    }

    /// Begin a capture session.
    /// `nonisolated` so it can be called from `@objc` menu actions and Carbon
    /// hotkey callbacks that aren't statically main-actor-isolated; the work is
    /// hopped to the main actor inside.
    nonisolated func startCapture(mode: Mode = .region, fromMenu: Bool = false) {
        MainActor.assumeIsolated {
            beginCapture(mode: mode, fromMenu: fromMenu)
        }
    }

    /// Cancel any in-flight session (Esc from overlay also lands here via the delegate).
    nonisolated func cancel() {
        MainActor.assumeIsolated {
            tearDownOverlays(refocusPreviousApp: true)
        }
    }

    /// MainActor-cancel the current session. Used by sub-systems (e.g. the scroll
    /// capture controller) that end on their own and need the overlay torn down
    /// without going through the user-initiated `stop` completion.
    func cancelCaptureSession() {
        tearDownOverlays(refocusPreviousApp: true)
    }

    private func beginCapture(mode: Mode, fromMenu: Bool) {
        guard !isCapturing else { return }
        guard ScreenCapturePermissionManager.ensureAccess() else {
            appLog("Screenshot: screen capture permission not granted", level: .warning)
            return
        }
        isCapturing = true
        captureSessionID += 1
        let sessionID = captureSessionID

        // Remember the frontmost app so we can hand focus back when the overlay dismisses.
        previousApp = NSWorkspace.shared.frontmostApplication

        // Re-arm the cross-screen stitched image.
        crossScreenImage = nil

        appLog("Screenshot: starting capture mode=\(mode) fromMenu=\(fromMenu)", level: .info)

        switch mode {
        case .fullscreen:
            performFullscreenCapture(sessionID: sessionID)
        case .window:
            // Window mode is region capture with window-snap enabled by default.
            performRegionCapture(sessionID: sessionID, enableWindowSnap: true)
        case .region:
            performRegionCapture(sessionID: sessionID, enableWindowSnap: false)
        }
    }

    // MARK: - Capture pipeline

    /// Full-screen mode: capture every display immediately and ingest — no overlay.
    private func performFullscreenCapture(sessionID: Int) {
        let context = ScreenCaptureManager.makeImmediateCaptureContext()
        Task.detached(priority: .userInitiated) { [weak self] in
            // macOS 14+ prefers SCK; fall back to synchronous CGWindowList.
            var captures: [ScreenCapture] = []
            if #available(macOS 14.0, *) {
                if let sck = await ScreenCaptureManager.captureAllScreensImmediatelySCK() {
                    captures = sck
                } else {
                    captures = ScreenCaptureManager.captureAllScreensImmediately(context: context)
                }
            } else {
                captures = ScreenCaptureManager.captureAllScreensImmediately(context: context)
            }
            await MainActor.run { self?.handleFullscreenCaptures(captures, sessionID: sessionID) }
        }
    }

    private func handleFullscreenCaptures(_ captures: [ScreenCapture], sessionID: Int) {
        guard sessionID == captureSessionID, isCapturing else { return }
        defer { MemoryFootprintReclaimer.reclaimAfterScreenshot() }
        guard !captures.isEmpty else {
            appLog("Screenshot: fullscreen capture produced no images", level: .warning)
            tearDownOverlays(refocusPreviousApp: true)
            return
        }
        // For fullscreen, ingest each screen image directly. A single screen is the
        // common case; multi-display users get one history entry per screen.
        for capture in captures {
            // Fullscreen never goes through the overlay-confirm path, so the image
            // isn't on the pasteboard yet — copy it (last screen wins on the board).
            let img = NSImage(cgImage: capture.image, size: capture.screen.frame.size)
            ingestConfirmedImage(img, windowTitle: nil, copyToPasteboard: true)
        }
        if !captures.isEmpty {
            ScreenshotSounds.playCapture()
            // Show the last captured screen as the thumbnail.
            if let last = captures.last {
                FloatingThumbnailPresenter.shared.show(
                    image: NSImage(cgImage: last.image, size: last.screen.frame.size))
            }
        }
        tearDownOverlays(refocusPreviousApp: true)
    }

    /// Region/window mode: capture every display, then show the selection overlay.
    private func performRegionCapture(sessionID: Int, enableWindowSnap: Bool) {
        // Snapshot trigger-time state (screens, mouse, cursor) BEFORE activating,
        // so transient UI (menus, Spotlight) is preserved.
        let context = ScreenCaptureManager.makeImmediateCaptureContext()

        Task.detached(priority: .userInitiated) { [weak self] in
            var captures: [ScreenCapture] = []
            if #available(macOS 14.0, *) {
                if let sck = await ScreenCaptureManager.captureAllScreensImmediatelySCK() {
                    captures = sck
                } else {
                    captures = ScreenCaptureManager.captureAllScreensImmediately(context: context)
                }
            } else {
                captures = ScreenCaptureManager.captureAllScreensImmediately(context: context)
            }
            await MainActor.run { self?.installAndShowOverlays(captures, sessionID: sessionID, enableWindowSnap: enableWindowSnap) }
        }
    }

    /// Install the captured screenshot into one overlay per screen and order them front.
    private func installAndShowOverlays(_ captures: [ScreenCapture], sessionID: Int, enableWindowSnap: Bool) {
        guard sessionID == captureSessionID, isCapturing else { return }
        guard !captures.isEmpty else {
            appLog("Screenshot: region capture produced no images", level: .warning)
            tearDownOverlays(refocusPreviousApp: true)
            return
        }

        activeControllers = captures.compactMap { capture in
            let controller = controllerForScreen(capture.screen)
            controller.overlayDelegate = self
            controller.capturedWindowTitle = nil
            controller.setScreenshot(capture.image)
            return controller
        }

        // Order every overlay front. The primary screen (the one with the mouse)
        // is shown last so it ends up key.
        let mouseLocation = NSEvent.mouseLocation
        activeControllers.forEach { $0.triggerRedraw() }
        // Show non-primary first, then the screen under the cursor so it's key.
        for controller in activeControllers where !controller.screen.frame.contains(mouseLocation) {
            controller.showOverlay()
        }
        let keyController = activeControllers.first { $0.screen.frame.contains(mouseLocation) }
            ?? activeControllers.first
        keyController?.showOverlay()
    }

    // MARK: - Overlay pool

    /// Window numbers of every currently-active overlay, so capture paths that
    /// must exclude our own chrome (scroll-capture frames, recording) can do so.
    var activeOverlayWindowNumbers: [CGWindowID] {
        activeControllers.map { $0.windowNumber }
    }

    /// Fetch (creating if needed) the pooled overlay controller for a screen.
    private func controllerForScreen(_ screen: NSScreen) -> OverlayWindowController {
        let key = ObjectIdentifier(screen)
        if let existing = overlayControllerPool[key] {
            existing.overlayDelegate = self
            return existing
        }
        let controller = OverlayWindowController(screen: screen)
        controller.overlayDelegate = self
        overlayControllerPool[key] = controller
        return controller
    }

    /// Drop pooled controllers whose screen no longer exists (unplug,
    /// resolution change, sleep/wake re-creating NSScreen instances).
    private func pruneStaleOverlayControllers() {
        guard !isCapturing else { return }
        let liveKeys = Set(NSScreen.screens.map { ObjectIdentifier($0) })
        for (key, controller) in overlayControllerPool where !liveKeys.contains(key) {
            controller.tearDown()
            overlayControllerPool.removeValue(forKey: key)
        }
    }

    /// Tear the whole warm overlay pool down while idle. Each pooled
    /// controller keeps a fullscreen layer-backed panel + overlay view tree
    /// whose backing store still holds the last captured frame (~33-70MB per
    /// Retina screen); the pool only exists to warm the *next* capture, so
    /// after a quiet period it is pure overhead. Called by
    /// MemoryFootprintReclaimer on idle/delayed reclaims.
    func releaseIdleOverlayPool() {
        guard !isCapturing, !overlayControllerPool.isEmpty else { return }
        for controller in overlayControllerPool.values {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        appLog("Screenshot: idle overlay pool released", level: .info)
    }

    /// Tear down the active session. Overlay windows are KEPT ALIVE (returned to
    /// idle click-through state) so the next capture reuses their NSPanel surface.
    private func tearDownOverlays(refocusPreviousApp: Bool) {
        for controller in activeControllers {
            controller.dismiss()
        }
        activeControllers = []
        isCapturing = false
        crossScreenImage = nil

        if refocusPreviousApp, let previousApp = previousApp {
            // LSUIElement app: re-activate the previously frontmost app so the user
            // lands back where they were. `activateAllWindows` is too aggressive; the
            // modern `activate` no-options call focuses without raising all windows.
            previousApp.activate(options: [])
        }
        previousApp = nil
        MemoryFootprintReclaimer.reclaimAfterScreenshot()
    }

    // MARK: - Output (clipy1 integration)

    /// Route a confirmed screenshot image into clipy1's history + sync + auto-save.
    /// macshot's overlay already copied to the system pasteboard via ImageEncoder;
    /// this additionally records it in clipy1's history and broadcasts to sync peers.
    /// Route a confirmed screenshot image into clipy1's history + sync + auto-save.
    /// macshot's overlay already copied to the system pasteboard via ImageEncoder;
    /// this additionally records it in clipy1's history and broadcasts to sync peers.
    private func ingestConfirmedImage(_ image: NSImage, windowTitle: String?) {
        ingestConfirmedImage(image, windowTitle: windowTitle, copyToPasteboard: false)
    }

    /// Variant for paths whose image is NOT yet on the system pasteboard
    /// (scroll capture, fullscreen capture): set `copyToPasteboard` true so the
    /// result is pasteable immediately, matching the overlay-confirm experience.
    private func ingestConfirmedImage(_ image: NSImage, windowTitle: String?, copyToPasteboard: Bool) {
        // Encoding a 4K/5K capture to PNG takes hundreds of milliseconds and used
        // to run right here on the main thread, stalling the post-capture UI.
        let autoSave = PreferencesManager.shared.isScreenshotAutoSaveEnabled
        Task.detached(priority: .userInitiated) {
            // Cooperative-pool threads have no per-work-item autorelease drain;
            // without this the encoder's intermediate bitmaps linger on the
            // thread until it picks up unrelated work.
            let encoded = autoreleasepool {
                // PNG for paste/history compatibility (matches ScreenshotExport.exportPNG).
                ImageEncoder.encodePNG(image) ?? image.tiffRepresentation
            }
            guard let pngData = encoded else {
                appLog("Screenshot: failed to encode confirmed image", level: .warning)
                // Even a failed flow touched the capture pipeline — still
                // return its pages rather than stranding them.
                MemoryFootprintReclaimer.scheduleDelayedReclaim()
                return
            }
            await MainActor.run {
                ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: copyToPasteboard)
            }
            if autoSave {
                _ = ScreenshotSaveService.save(pngData: pngData)
            }
            // This encode (plus the thumbnail offload) runs AFTER the
            // reclaimAfterScreenshot at overlay teardown; schedule the second
            // pass that actually returns those pages.
            MemoryFootprintReclaimer.scheduleDelayedReclaim()
        }
    }
}

// MARK: - OverlayWindowControllerDelegate

extension ScreenshotSessionCoordinator: OverlayWindowControllerDelegate {

    func overlayDidCancel(_ controller: OverlayWindowController) {
        // Any single overlay cancelling ends the whole session.
        tearDownOverlays(refocusPreviousApp: true)
    }

    func overlayDidConfirm(_ controller: OverlayWindowController,
                           capturedImage: NSImage?,
                           annotationData: CaptureAnnotationData?) {
        // Grab the capture rect before tearing down — afterwards the overlay view
        // is gone and globalSelectionRect would return nil. The rect flows to the
        // floating thumbnail so a later "pin" from it lands on the original spot.
        let captureRect = controller.globalSelectionRect
        let image = capturedImage ?? controller.screenshotImage
        tearDownOverlays(refocusPreviousApp: true)
        guard let image = image else { return }
        ingestConfirmedImage(image, windowTitle: controller.capturedWindowTitle)
        // Right-bottom draggable thumbnail with copy/save/pin/edit actions
        // (matches macshot's post-capture feedback).
        FloatingThumbnailPresenter.shared.show(image: image, annotationData: annotationData, captureScreenRect: captureRect)
    }

    func overlayDidEncodePNG(_ controller: OverlayWindowController, image: NSImage, pngData: Data?) {
        // The clipboard encode just produced the full-image PNG; hand it to the
        // floating thumbnail so its offload is a plain file write instead of
        // another full-image encode on top of the peak.
        FloatingThumbnailPresenter.shared.provideEncodedPNG(pngData, for: image)
    }

    func overlayDidRequestPin(_ controller: OverlayWindowController,
                              image: NSImage,
                              annotationData: CaptureAnnotationData?,
                              screenRect: NSRect?) {
        tearDownOverlays(refocusPreviousApp: false)
        // Use clipy1's existing pin (its own history-aware pin controller).
        // screenRect is the original capture location → pin in place, no jump.
        PinPanelController.shared.pin(image: image, at: screenRect, skipIngest: false)
    }

    func overlayDidRequestOCR(_ controller: OverlayWindowController,
                              result: OCRScanResult,
                              image: NSImage?) {
        // OCR already ran (Vision). Copy the text so the common case needs no
        // extra click, then show the result window, which also offers per-line
        // copy, language selection, translation and QR payload actions.
        let text = result.text
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // OCR is a terminal action: tear down overlays on ALL screens so the
        // other monitors' captures are dismissed too. The originating controller
        // already dismissed itself (see OverlayWindowController.overlayViewDidRequestOCR),
        // but every other active controller is still on screen — dismiss them
        // here just like confirm/cancel/pin do. dismiss() is idempotent.
        tearDownOverlays(refocusPreviousApp: true)

        guard !text.isEmpty || !result.qrCodes.isEmpty else {
            appLog("Screenshot OCR: no text or QR code found", level: .info)
            return
        }
        ocrResultController?.close()
        let controller = OCRResultController(text: text, image: image, qrCodes: result.qrCodes)
        controller.onClose = { [weak self] in self?.ocrResultController = nil }
        ocrResultController = controller
        controller.show()
    }

    func overlayDidRequestUpload(_ controller: OverlayWindowController,
                                 image: NSImage,
                                 annotationData: CaptureAnnotationData?) {
        // No upload backends in clipy1 (OFFLINE build). Treat as a normal confirm.
        overlayDidConfirm(controller, capturedImage: image, annotationData: annotationData)
    }

    func overlayDidRequestStartRecording(_ controller: OverlayWindowController,
                                         rect: NSRect, screen: NSScreen) {
        // ScreenshotRecorder owns the full recording flow: it tears down the
        // capture overlay (via onOverlayDismissed), then runs the SCStream +
        // AVAssetWriter engine with its own selection border + timer HUD.
        // Completion delivers the MP4 (editor / Finder / clipboard).
        ScreenshotRecorder.shared.startRecording(rect: rect, screen: screen) { [weak self] in
            self?.tearDownOverlays(refocusPreviousApp: true)
        }
    }

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {
        // Stop is asynchronous; finalization lands via the engine's onCompletion
        // callback inside ScreenshotRecorder (no coordinator teardown needed here
        // — the overlay was already dismissed when recording started).
        ScreenshotRecorder.shared.stopRecording()
    }

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController,
                                        rect: NSRect, screen: NSScreen) {
        // ScreenshotScroller owns the whole flow: accessibility check, overlay
        // scroll-mode state, preview panel, HUD progress, and teardown. It calls
        // back via its `stop` completion with the final stitched image.
        ScreenshotScroller.shared.start(rect: rect, screen: screen, overlay: controller)
    }

    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {
        ScreenshotScroller.shared.stop { [weak self] image in
            // ScreenshotScroller.handleDone already reset the overlay + preview;
            // here we just tear the session down and ingest the result.
            self?.tearDownOverlays(refocusPreviousApp: true)
            if let image = image {
                // The stitched image was never copied to the pasteboard (it's built
                // inside ScrollCaptureController, not via the overlay-confirm path),
                // so copy it here — otherwise Cmd+V pastes the stale prior content
                // and the capture looks like it "did nothing".
                self?.ingestConfirmedImage(image, windowTitle: nil, copyToPasteboard: true)
                ScreenshotSounds.playCapture()
                // Right-bottom thumbnail feedback (matches macshot).
                FloatingThumbnailPresenter.shared.show(image: image)
            }
        }
    }

    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {
        ScreenshotScroller.shared.toggleAutoScroll()
    }

    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {
        AccessibilityManager.requestSystemPrompt()
    }

    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController) {
        // First call CGRequestListenEventAccess() — this triggers the system TCC
        // prompt on first use (without it, the permission is never requested and
        // the keystroke/mouse-highlight overlays silently stay disabled). If the
        // user previously denied, the prompt won't re-show, so we also open the
        // System Settings pane as a fallback.
        KeystrokeOverlay.requestInputMonitoringPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Input_Monitoring") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        // Selection started on this screen — ensure it's the key controller.
        if controller !== activeControllers.last {
            activeControllers.removeAll { $0 === controller }
            activeControllers.append(controller)
        }
    }

    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Propagate the in-progress selection to other screens so the chrome
        // (resize handles, dim) stays visually consistent across displays.
        for other in activeControllers where other !== controller {
            let local = NSRect(
                x: globalRect.minX - other.screen.frame.minX,
                y: globalRect.minY - other.screen.frame.minY,
                width: globalRect.width, height: globalRect.height)
            other.setRemoteSelection(local, fullRect: globalRect)
        }
    }

    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Mirror a remote (cross-screen) resize onto every other overlay.
        overlayDidChangeSelection(controller, globalRect: globalRect)
    }

    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in activeControllers where other !== controller {
            other.clearSelection()
        }
    }

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        crossScreenImage
    }

    func overlayDidChangeWindowSnapState(_ controller: OverlayWindowController) {
        // No-op for clipy1: window-snap is local to each overlay.
    }
}
