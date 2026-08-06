import AppKit
import AVFoundation
import Foundation

/// Drives macshot's screen-recording session.
///
/// Mirrors macshot's AppDelegate recording flow (minus webcam/mouse-highlight/
/// keystroke overlays and audio-merge, which are out of scope for clipy1):
///   1. Dismiss the capture overlay + restore focus to the previous app.
///   2. Show a `SelectionBorderOverlay` so the user sees the recorded region.
///   3. Show a `RecordingHUDPanel` (elapsed timer + stop + pause/resume).
///   4. Build a `RecordingEngine` (SCStream → AVAssetWriter MP4), wire its
///      `onProgress`/`onPauseChanged`/`onCompletion` callbacks.
///   5. Exclude the border + HUD windows from the recording.
///   6. On completion: deliver the MP4 (reveal in Finder / copy path / open in
///      macshot's video editor, per the `recordingOnStop` preference).
@MainActor
final class ScreenshotRecorder {
    static let shared = ScreenshotRecorder()
    private init() {}

    private var engine: RecordingEngine?
    private var hudPanel: RecordingHUDPanel?
    private var selectionBorder: SelectionBorderOverlay?
    /// Optional recording overlays (webcam / mouse-click highlight / keystrokes).
    /// These are intentionally part of the recording, so their window numbers are
    /// NOT added to the engine's exclude list (only the border + HUD are).
    private var webcamOverlay: WebcamOverlay?
    private var mouseHighlightOverlay: MouseHighlightOverlay?
    private var keystrokeOverlay: KeystrokeOverlay?
    private weak var recordingScreen: NSScreen?
    private var recordingRect: NSRect = .zero

    // MARK: - Start

    /// Begin recording. `onOverlayDismissed` is called once the capture overlay has
    /// been torn down (so the coordinator can reset its session state) — the
    /// recording itself then runs independently with its own HUD.
    func startRecording(rect: NSRect, screen: NSScreen, onOverlayDismissed: @escaping () -> Void) {
        guard engine == nil else { return }
        recordingRect = rect
        recordingScreen = screen

        appLog("Screenshot: recording starting at \(Int(rect.width))x\(Int(rect.height))", level: .info)

        // Tear down the capture overlay first (mirrors macshot's dismissOverlays
        // before building the recording UI). The coordinator resets its session.
        onOverlayDismissed()

        // Build the engine + UI on the next run loop so the overlay dismissal +
        // focus transfer complete first (macshot does the same).
        DispatchQueue.main.async { [weak self] in
            self?.beginRecording(rect: rect, screen: screen)
        }
    }

    private func beginRecording(rect: NSRect, screen: NSScreen) {
        let engine = RecordingEngine()

        // Per-session overrides from the overlay (nil = use UserDefaults).
        engine.onProgress = { [weak self] seconds in
            self?.hudPanel?.update(elapsedSeconds: seconds)
        }
        engine.onPauseChanged = { [weak self] paused in
            self?.hudPanel?.setPaused(paused)
        }
        engine.onCompletion = { [weak self] url, error in
            self?.handleCompletion(url: url, error: error)
        }
        self.engine = engine

        // Selection border so the user sees what's being recorded.
        let border = SelectionBorderOverlay(screen: screen)
        border.setSelectionRect(rect)
        border.orderFrontRegardless()
        selectionBorder = border

        // Floating timer HUD (unless the user hid it).
        let hideHUD = UserDefaults.standard.bool(forKey: "hideRecordingHUD")
        if !hideHUD {
            let hud = RecordingHUDPanel()
            hud.update(elapsedSeconds: 0)
            hud.positionOnScreen(relativeTo: rect, screen: screen)
            hud.onStopRecording = { [weak self] in self?.stopRecording() }
            hud.onPauseRecording = { [weak self] in self?.engine?.pauseRecording() }
            hud.onResumeRecording = { [weak self] in self?.engine?.resumeRecording() }
            hud.orderFrontRegardless()
            hudPanel = hud
        }

        // Mouse-click highlight overlay (requires Input Monitoring permission).
        // Drawn above normal windows so SCStream captures the highlights.
        if UserDefaults.standard.bool(forKey: "recordMouseHighlight") && CGPreflightListenEventAccess() {
            let overlay = MouseHighlightOverlay(screen: screen)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            mouseHighlightOverlay = overlay
        }

        // Keystroke overlay (requires Input Monitoring permission).
        if UserDefaults.standard.bool(forKey: "recordKeystroke") && KeystrokeOverlay.hasInputMonitoringPermission {
            let overlay = KeystrokeOverlay(screen: screen)
            overlay.setRecordingRect(rect)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            keystrokeOverlay = overlay
        }

        // Webcam overlay (requires camera authorization). Locked in place during
        // recording (not draggable) so it stays in the configured corner.
        if UserDefaults.standard.bool(forKey: "recordWebcam") &&
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            let overlay = WebcamOverlay(screen: screen)
            let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
            let wcSize = WebcamSize(rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium") ?? .medium
            let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle
            overlay.configure(position: position, size: wcSize, shape: shape, recordingRect: rect)
            overlay.startPreview(deviceUID: UserDefaults.standard.string(forKey: "selectedCameraDeviceUID"))
            overlay.setDraggable(false)
            overlay.orderFrontRegardless()
            webcamOverlay = overlay
        }

        // Exclude our own chrome (border + HUD) from the captured frames.
        // Webcam / mouse-highlight / keystroke overlays are intentionally part of
        // the recording, so their window numbers are NOT excluded.
        var excludeIDs: [CGWindowID] = []
        if let w = selectionBorder { excludeIDs.append(CGWindowID(w.windowNumber)) }
        if let w = hudPanel { excludeIDs.append(CGWindowID(w.windowNumber)) }

        engine.startRecording(rect: rect, screen: screen, excludeWindowNumbers: excludeIDs)
    }

    // MARK: - Stop

    /// User pressed Stop (HUD button, menu bar, or overlay Esc). Finalization is
    /// asynchronous — `onCompletion` fires with the MP4 URL.
    func stopRecording() {
        engine?.stopRecording()
    }

    func pauseRecording() { engine?.pauseRecording() }
    func resumeRecording() { engine?.resumeRecording() }
    var isRecording: Bool { engine?.state == .recording || engine?.state == .paused }

    // MARK: - Completion

    private func handleCompletion(url: URL?, error: Error?) {
        // Tear down the recording UI + all optional overlays.
        hudPanel?.close()
        hudPanel = nil
        selectionBorder?.close()
        selectionBorder = nil
        mouseHighlightOverlay?.stopMonitoring()
        mouseHighlightOverlay?.close()
        mouseHighlightOverlay = nil
        // stopMonitoring (not just close) — the event tap and its refcon outlive
        // the window otherwise, and keep listening into the next recording.
        keystrokeOverlay?.stopMonitoring()
        keystrokeOverlay?.close()
        keystrokeOverlay = nil
        webcamOverlay?.stopPreview()
        webcamOverlay?.close()
        webcamOverlay = nil
        engine = nil

        if let error = error {
            appLog("Screenshot: recording failed — \(error.localizedDescription)", level: .warning)
            Self.presentRecordingFailure(error)
            return
        }
        guard let url = url else {
            appLog("Screenshot: recording produced no file", level: .warning)
            Self.presentRecordingFailure(nil)
            return
        }

        appLog("Screenshot: recording saved to \(url.path)", level: .info)
        ScreenshotSounds.playCapture()

        // Deliver per the user's on-stop preference (default: editor).
        let onStop = UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
        switch onStop {
        case "finder":
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case "clipboard":
            // Copy the file URL (videos can't go on the pasteboard as image data).
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        default:
            // Open in macshot's video editor (trim/export/upload).
            VideoEditorWindowController.open(url: url)
        }
    }

    /// A failed recording used to be log-only, so the user just saw the HUD
    /// disappear and assumed the file was saved somewhere.
    private static func presentRecordingFailure(_ error: Error?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Recording failed")
        alert.informativeText = error?.localizedDescription ?? L("The recording could not be saved.")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

/// Drives macshot's scroll-capture (long-screenshot) session.
///
/// Mirrors macshot's AppDelegate scroll-capture flow:
///   1. Require Accessibility trust (Vision shift detection + scroll injection
///      both need it). If missing, prompt the user and bail.
///   2. Build a `ScrollCaptureController(captureRect:screen:)` and exclude the
///      overlay windows from each frame capture.
///   3. Flip the triggering overlay into scroll-capture mode (transparent +
///      click-through, scroll HUD shown) so the user can scroll the live app.
///   4. Show a `ScrollCapturePreviewPanel` beside the capture region for live
///      preview of the stitched image as it grows.
///   5. Wire the controller's callbacks (strip added / preview updated /
///      auto-scroll started / session done) back to the overlay HUD + preview.
///   6. On done (or stop): tear everything down and hand the final image to the
///      coordinator's ingest path (history + sync + auto-save).
@MainActor
final class ScreenshotScroller {
    static let shared = ScreenshotScroller()
    private init() {}

    private weak var overlay: OverlayWindowController?
    private var controller: ScrollCaptureController?
    private var previewPanel: ScrollCapturePreviewPanel?
    /// Called once with the final stitched image (nil if the session produced nothing).
    var onCompleted: ((NSImage?) -> Void)?

    // MARK: - Start

    func start(rect: NSRect, screen: NSScreen, overlay: OverlayWindowController) {
        // Accessibility is required: the controller resolves the target window via
        // the AX API and (in auto-scroll mode) injects scroll events.
        guard AccessibilityManager.isTrusted else {
            promptForAccessibility()
            return
        }

        self.overlay = overlay

        let scc = ScrollCaptureController(captureRect: rect, screen: screen)
        // Exclude every overlay panel so the captured frames never include our
        // own chrome (selection border, HUD, preview).
        scc.excludedWindowIDs = ScreenshotSessionCoordinator.shared.activeOverlayWindowNumbers
        controller = scc

        // Read max height for the overlay HUD progress bar (matches macshot key).
        let maxH = max(2000, min(40000, UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000))

        // Flip the triggering overlay into scroll-capture mode.
        overlay.setScrollCaptureState(isActive: true, maxHeight: maxH)

        // Live preview panel (beside the capture region if there's room).
        if let panel = ScrollCapturePreviewPanel(captureRect: rect, screen: screen, overlayLevel: 257) {
            panel.orderFront(nil)
            previewPanel = panel
        }

        // Callbacks.
        scc.onStripAdded = { [weak self, weak overlay] count in
            guard let self = self, let scc = self.controller else { return }
            overlay?.updateScrollCaptureProgress(
                stripCount: count, pixelSize: scc.stitchedPixelSize,
                autoScrolling: scc.autoScrollActive)
        }
        scc.onPreviewUpdated = { [weak self] image in
            self?.previewPanel?.updatePreview(image: image)
        }
        scc.onAutoScrollStarted = { [weak self, weak overlay] in
            guard let self = self, let scc = self.controller else { return }
            overlay?.updateScrollCaptureProgress(
                stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
                autoScrolling: true)
        }
        scc.onSessionDone = { [weak self] finalImage in
            self?.handleDone(finalImage: finalImage)
        }

        appLog("Screenshot: scroll capture started (\(Int(rect.width))x\(Int(rect.height)))", level: .info)
        Task { await scc.startSession() }
    }

    // MARK: - Controls

    func toggleAutoScroll() {
        controller?.toggleAutoScroll()
    }

    /// User pressed Stop (or Esc): the controller finalizes the stitch and fires
    /// `onSessionDone` asynchronously. We don't tear down here — done is.
    func stop(completion: @escaping (NSImage?) -> Void) {
        onCompleted = completion
        controller?.stopSession()
    }

    // MARK: - Completion

    private func handleDone(finalImage: NSImage?) {
        previewPanel?.orderOut(nil)
        previewPanel = nil
        overlay?.setScrollCaptureState(isActive: false)
        overlay = nil
        controller = nil

        if let image = finalImage {
            appLog("Screenshot: scroll capture done (\(Int(image.size.width))x\(Int(image.size.height)))", level: .info)
        } else {
            appLog("Screenshot: scroll capture produced no image", level: .warning)
        }

        if let completion = onCompleted {
            // User-initiated stop path: hand the image to the coordinator's ingest.
            onCompleted = nil
            completion(finalImage)
        } else {
            // Session ended on its own (e.g. first-frame capture failed) before the
            // user clicked stop. The coordinator's stop handler was never installed,
            // so tear the session down ourselves to avoid stranding the overlay.
            ScreenshotSessionCoordinator.shared.cancelCaptureSession()
        }
    }

    // MARK: - Accessibility prompt

    private func promptForAccessibility() {
        AccessibilityManager.requestSystemPrompt()
        let alert = NSAlert()
        alert.messageText = L("Accessibility Access Required")
        alert.informativeText = L("macshot needs Accessibility permission for scroll capture. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityManager.openSettings()
        }
    }
}
