import AppKit

final class ScreenshotCoordinator {
    static let shared = ScreenshotCoordinator()

    private var overlayController: CaptureOverlayController?
    private var isCapturing = false

    private init() {}

    func start(mode: ScreenshotCaptureMode? = nil) {
        guard !isCapturing else { return }
        guard ScreenCapturePermissionManager.ensureAccess() else { return }

        let captureMode = mode ?? PreferencesManager.shared.screenshotDefaultMode
        isCapturing = true
        NSApp.activate(ignoringOtherApps: true)

        switch captureMode {
        case .fullscreen:
            let screenRect = NSScreen.main?.frame ?? .zero
            ScreenshotCaptureService.captureFullscreen { [weak self] image in
                self?.handleCaptureResult(image, screenRect: screenRect)
            }
        case .region, .window:
            overlayController = CaptureOverlayController(mode: captureMode) { [weak self] image, rect in
                self?.overlayController = nil
                self?.handleCaptureResult(image, screenRect: rect)
            }
            overlayController?.present()
        }
    }

    func cancel() {
        overlayController?.cancel()
        overlayController = nil
        ScreenshotInlineEditor.current?.dismiss()
        isCapturing = false
    }

    private func handleCaptureResult(_ image: NSImage?, screenRect: NSRect?) {
        isCapturing = false
        guard let image, let screenRect, screenRect.width > 1, screenRect.height > 1 else {
            if image == nil {
                appLog("Screenshot capture failed or was cancelled", level: .warning)
            }
            return
        }
        presentInlineEditor(image: image, screenRect: screenRect)
    }

    private func presentInlineEditor(image: NSImage, screenRect: NSRect) {
        ScreenshotInlineEditor.present(image: image, screenRect: screenRect)
    }
}
