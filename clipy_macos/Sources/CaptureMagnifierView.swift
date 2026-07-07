import AppKit

final class CaptureMagnifierController {
    private var panel: NSPanel?
    private let contentView = MagnifierContentView()
    private var captureWorkItem: DispatchWorkItem?
    private var captureGeneration: UInt = 0
    private let debounceInterval: TimeInterval = 0.04
    private let zoomFactor: CGFloat = 10

    func show() {
        guard PreferencesManager.shared.isScreenshotMagnifierEnabled else { return }

        let size = NSSize(
            width: ScreenshotChrome.magnifierSize,
            height: ScreenshotChrome.magnifierSize + 20
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true

        contentView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = contentView
        panel.orderFrontRegardless()
        self.panel = panel

        update(at: NSEvent.mouseLocation)
    }

    func update(at screenPoint: NSPoint) {
        guard let panel else { return }
        contentView.screenPoint = screenPoint
        contentView.needsDisplay = true

        let offset: CGFloat = 16
        panel.setFrameOrigin(NSPoint(x: screenPoint.x + offset, y: screenPoint.y + offset))
        scheduleLocalCapture(at: screenPoint)
    }

    func dismiss() {
        captureWorkItem?.cancel()
        captureWorkItem = nil
        panel?.close()
        panel = nil
        contentView.cachedCrop = nil
    }

    private func scheduleLocalCapture(at screenPoint: NSPoint) {
        captureWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.captureLocalSample(at: screenPoint)
        }
        captureWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func captureLocalSample(at screenPoint: NSPoint) {
        let sampleSize = ScreenshotChrome.magnifierSize / zoomFactor
        let rect = NSRect(
            x: screenPoint.x - sampleSize / 2,
            y: screenPoint.y - sampleSize / 2,
            width: sampleSize,
            height: sampleSize
        )

        captureGeneration += 1
        let generation = captureGeneration
        ScreenshotCaptureService.capture(rect: rect, forMagnifier: true) { [weak self] image in
            guard let self, generation == self.captureGeneration else { return }
            self.contentView.cachedCrop = image
            self.contentView.needsDisplay = true
        }
    }
}

private final class MagnifierContentView: NSView {
    var screenPoint: NSPoint = .zero
    var cachedCrop: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let imageSize = ScreenshotChrome.magnifierSize
        let imageRect = NSRect(x: 0, y: 20, width: imageSize, height: imageSize)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        if let cachedCrop {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            cachedCrop.draw(in: imageRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.white.withAlphaComponent(0.6).setStroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: NSPoint(x: imageRect.midX, y: imageRect.minY))
        crosshair.line(to: NSPoint(x: imageRect.midX, y: imageRect.maxY))
        crosshair.move(to: NSPoint(x: imageRect.minX, y: imageRect.midY))
        crosshair.line(to: NSPoint(x: imageRect.maxX, y: imageRect.midY))
        crosshair.lineWidth = 1
        crosshair.stroke()

        let coordText = "\(Int(screenPoint.x)), \(Int(screenPoint.y))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (coordText as NSString).size(withAttributes: attributes)
        (coordText as NSString).draw(
            at: NSPoint(x: (bounds.width - textSize.width) / 2, y: 4),
            withAttributes: attributes
        )
    }
}
