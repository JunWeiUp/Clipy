import AppKit

final class ScreenshotCoordinator {
    static let shared = ScreenshotCoordinator()

    private var overlayController: CaptureOverlayController?
    private var isCapturing = false

    private init() {}

    func start(mode: ScreenshotCaptureMode? = nil) {
        guard !isCapturing else { return }
        guard ScreenCapturePermissionManager.ensureAccess() else {
            appLog("Screenshot skipped: screen recording permission not granted", level: .warning)
            return
        }

        let captureMode = mode ?? PreferencesManager.shared.screenshotDefaultMode
        isCapturing = true

        switch captureMode {
        case .fullscreen:
            let screenRect = NSScreen.main?.frame ?? .zero
            ScreenshotCaptureService.captureFullscreen { [weak self] image in
                guard let self else { return }
                autoreleasepool {
                    guard let image,
                          let pngData = ScreenshotImageProcessor.pngData(from: image, logicalSize: image.size) else {
                        self.handleCaptureResult(screenRect: nil)
                        return
                    }
                    let action = PreferencesManager.shared.screenshotPostCaptureAction
                    ScreenshotExport.applyPostAction(
                        action,
                        pngData: pngData,
                        image: image,
                        logicalSize: image.size,
                        screenRect: screenRect
                    )
                    self.handleCaptureResult(screenRect: screenRect)
                }
            }
        case .region, .window:
            overlayController = CaptureOverlayController(mode: captureMode) { [weak self] rect in
                self?.overlayController = nil
                self?.handleCaptureResult(screenRect: rect)
            }
            overlayController?.present()
        }
    }

    func cancel() {
        overlayController?.cancel()
        overlayController = nil
        isCapturing = false
    }

    private func handleCaptureResult(screenRect: NSRect?) {
        isCapturing = false
        guard let screenRect, screenRect.width > 1, screenRect.height > 1 else {
            appLog("Screenshot capture failed or was cancelled", level: .warning)
            // Even on cancel, release the transient CIContext pool so its
            // IOSurface cache does not linger from a prior mosaic annotation.
            MemoryFootprintReclaimer.reclaimAfterScreenshot()
            return
        }
        appLog("Screenshot captured \(Int(screenRect.width))x\(Int(screenRect.height))", level: .info)
        // The capture pipeline briefly held several large bitmaps (full-display
        // capture, cropped copy, flatten context, PNG encoding) plus a CIContext
        // pool used for mosaic annotations. Drop the CIContext and nudge malloc
        // zones to return the now-free pages to the system, so the footprint
        // recovers toward baseline instead of staying near the peak.
        MemoryFootprintReclaimer.reclaimAfterScreenshot()
    }
}
