import AppKit

final class CaptureMagnifierController {
    private var panel: NSPanel?
    private let contentView = MagnifierContentView()
    private var snapshot: NSImage?
    private var snapshotOrigin: NSPoint = .zero

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

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        snapshotOrigin = screen.frame.origin
        ScreenshotCaptureService.capture(rect: screen.frame) { [weak self] image in
            self?.snapshot = image
            self?.contentView.snapshot = image
            self?.contentView.snapshotOrigin = screen.frame.origin
        }
    }

    func update(at screenPoint: NSPoint) {
        guard let panel else { return }
        contentView.screenPoint = screenPoint
        contentView.needsDisplay = true

        let offset: CGFloat = 16
        panel.setFrameOrigin(NSPoint(x: screenPoint.x + offset, y: screenPoint.y + offset))
    }

    func dismiss() {
        panel?.close()
        panel = nil
        snapshot = nil
    }
}

private final class MagnifierContentView: NSView {
    var screenPoint: NSPoint = .zero
    var snapshot: NSImage?
    var snapshotOrigin: NSPoint = .zero
    private let zoomFactor: CGFloat = 10

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let imageSize = ScreenshotChrome.magnifierSize
        let imageRect = NSRect(x: 0, y: 20, width: imageSize, height: imageSize)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        if let cropped = magnifiedCrop() {
            cropped.draw(in: imageRect)
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

    private func magnifiedCrop() -> NSImage? {
        guard let snapshot else { return nil }
        let sampleSize = ScreenshotChrome.magnifierSize / zoomFactor
        let localX = screenPoint.x - snapshotOrigin.x
        let localY = screenPoint.y - snapshotOrigin.y
        let scaleX = snapshot.size.width / max((NSScreen.screens.first?.frame.width ?? snapshot.size.width), 1)
        let scaleY = snapshot.size.height / max((NSScreen.screens.first?.frame.height ?? snapshot.size.height), 1)

        let cropRect = NSRect(
            x: (localX - sampleSize / 2) * scaleX,
            y: (localY - sampleSize / 2) * scaleY,
            width: sampleSize * scaleX,
            height: sampleSize * scaleY
        )

        guard let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: cropRect.integral) else {
            return nil
        }

        return NSImage(
            cgImage: cropped,
            size: NSSize(width: ScreenshotChrome.magnifierSize, height: ScreenshotChrome.magnifierSize)
        )
    }
}
