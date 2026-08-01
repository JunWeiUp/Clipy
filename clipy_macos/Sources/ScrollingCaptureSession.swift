import AppKit

/// Semi-automatic scrolling capture: user scrolls manually; we stitch frames.
final class ScrollingCaptureSession {
    private let selectionRect: NSRect
    private let onComplete: (NSImage?, NSRect?) -> Void

    private var overlayWindows: [CaptureOverlayWindow] = []
    private var overviewPanel: ScrollingCaptureOverviewPanel?
    private var stitchedImage: NSImage?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var keyMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var isCapturingFrame = false
    private var isFinished = false
    private var consecutiveDuplicates = 0
    private var consecutiveWeakMatches = 0
    private var lastDuplicateHint = false
    private var limitReached = false
    /// Last accepted frame fingerprint to skip no-op captures before stitching.
    private var lastFrameFingerprint: UInt64 = 0

    init(selectionRect: NSRect, onComplete: @escaping (NSImage?, NSRect?) -> Void) {
        self.selectionRect = selectionRect
        self.onComplete = onComplete
    }

    func start(overlayWindows: [CaptureOverlayWindow]) {
        self.overlayWindows = overlayWindows
        overlayWindows.forEach {
            $0.setPhase(.scrolling)
            $0.setScrollingPassThroughRect(selectionRect)
            $0.ignoresMouseEvents = true
        }

        let overview = ScrollingCaptureOverviewPanel()
        overview.overviewDelegate = self
        overviewPanel = overview
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        overview.placeDefault(on: screen)
        overview.orderFrontRegardless()

        captureInitialFrame()

        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.scheduleCapture()
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.scheduleCapture()
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isFinished else { return event }
            if event.keyCode == 53 { // Esc
                self.cancel()
                return nil
            }
            if event.keyCode == 36 { // Return
                self.finish()
                return nil
            }
            return event
        }
    }

    private func captureInitialFrame() {
        isCapturingFrame = true
        ScreenshotCaptureService.capture(rect: selectionRect, showsCursor: false) { [weak self] image in
            guard let self, !self.isFinished else { return }
            self.isCapturingFrame = false
            guard let image else {
                self.cancel()
                return
            }
            self.stitchedImage = image
            self.lastFrameFingerprint = Self.fingerprint(image)
            self.refreshOverview()
        }
    }

    private func scheduleCapture() {
        guard !isFinished, !limitReached else { return }
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.captureAndStitch()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func captureAndStitch() {
        guard !isFinished, !isCapturingFrame, !limitReached else { return }
        isCapturingFrame = true
        ScreenshotCaptureService.capture(rect: selectionRect, showsCursor: false) { [weak self] image in
            guard let self, !self.isFinished else { return }
            defer { self.isCapturingFrame = false }
            guard let image, let base = self.stitchedImage else { return }

            let fingerprint = Self.fingerprint(image)
            if fingerprint != 0, fingerprint == self.lastFrameFingerprint {
                self.consecutiveDuplicates += 1
                self.lastDuplicateHint = self.consecutiveDuplicates >= 2
                self.refreshOverview()
                return
            }

            guard let result = ScrollingImageStitcher.append(base: base, incoming: image) else {
                return
            }

            if result.reachedLimit {
                self.limitReached = true
                self.lastDuplicateHint = false
                self.refreshOverview()
                return
            }

            if result.weakMatch {
                self.consecutiveWeakMatches += 1
                // Don't update stitched image; wait for a clearer scroll frame.
                return
            }

            self.consecutiveWeakMatches = 0

            if result.duplicate {
                self.consecutiveDuplicates += 1
                self.lastDuplicateHint = self.consecutiveDuplicates >= 2
                self.lastFrameFingerprint = fingerprint
            } else {
                self.consecutiveDuplicates = 0
                self.lastDuplicateHint = false
                self.stitchedImage = result.image
                self.lastFrameFingerprint = fingerprint
            }
            self.refreshOverview()
        }
    }

    /// Cheap content fingerprint (center-column samples) to detect unchanged frames.
    private static func fingerprint(_ image: NSImage) -> UInt64 {
        guard let cg = ScreenshotImageProcessor.bestCGImage(from: image) else { return 0 }
        let w = cg.width
        let h = cg.height
        guard w > 8, h > 8 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 14695981039346656037
        let x = w / 2
        for y in stride(from: 0, to: h, by: max(1, h / 48)) {
            let o = (y * w + x) * 4
            let v = UInt64(pixels[o]) ^ (UInt64(pixels[o + 1]) << 8) ^ (UInt64(pixels[o + 2]) << 16)
            hash ^= v &+ UInt64(y)
            hash = hash &* 1099511628211
        }
        return hash
    }

    private func refreshOverview() {
        guard let image = stitchedImage else { return }
        let pixelHeight = Int(ScreenshotImageProcessor.bestCGImage(from: image)?.height ?? Int(image.size.height))
        let thumb = downsampledPreview(image)
        overviewPanel?.update(
            preview: thumb,
            pixelHeight: pixelHeight,
            duplicateHint: lastDuplicateHint,
            limitHint: limitReached
        )
    }

    private func downsampledPreview(_ image: NSImage) -> NSImage {
        let maxSide: CGFloat = 180
        let scale = min(maxSide / max(image.size.width, 1), maxSide / max(image.size.height, 1), 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let preview = NSImage(size: size)
        preview.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(origin: .zero, size: size))
        preview.unlockFocus()
        return preview
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        cleanupMonitors()
        let image = stitchedImage
        let rect = selectionRect
        tearDownUI()
        onComplete(image, rect)
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        cleanupMonitors()
        tearDownUI()
        onComplete(nil, nil)
    }

    /// Tear down without invoking completion (controller is aborting).
    func abandon() {
        guard !isFinished else { return }
        isFinished = true
        cleanupMonitors()
        tearDownUI()
    }

    private func cleanupMonitors() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func tearDownUI() {
        overviewPanel?.close()
        overviewPanel = nil
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
    }
}

extension ScrollingCaptureSession: ScrollingCaptureOverviewDelegate {
    func scrollingOverviewDidFinish() {
        finish()
    }

    func scrollingOverviewDidCancel() {
        cancel()
    }
}
