import AppKit
import CoreGraphics

@MainActor
final class NativeScreenshotLongCaptureHUD: NSObject {
    private static let escapeHotKeyID: UInt32 = 0x5343_5245 // SCRE
    let window: NSPanel
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var registeredEscapeHotKey = false

    private let preview = NSImageView()
    private let status = NSTextField(labelWithString:
        NativeScreenshotUserText.string("滚动页面以继续截取", "Scroll the page to extend the capture"))

    override init() {
        window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 430),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = NativeScreenshotUserText.string("滚动长截图", "Long Screenshot")
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 430))
        status.frame = CGRect(x: 16, y: 390, width: 268, height: 24)
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        preview.frame = CGRect(x: 16, y: 58, width: 268, height: 322)
        preview.imageScaling = .scaleProportionallyDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 8
        root.addSubview(preview)
        let stop = NSButton(title: NativeScreenshotUserText.string("完成", "Finish"),
                            target: self, action: #selector(stopPressed))
        stop.frame = CGRect(x: 155, y: 15, width: 128, height: 30)
        stop.bezelStyle = .rounded
        root.addSubview(stop)
        let cancel = NSButton(title: NativeScreenshotUserText.string("取消", "Cancel"),
                              target: self, action: #selector(cancelPressed))
        cancel.frame = CGRect(x: 16, y: 15, width: 128, height: 30)
        cancel.bezelStyle = .rounded
        root.addSubview(cancel)
        window.contentView = root
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.maxX - window.frame.width - 20,
                y: frame.midY - window.frame.height / 2
            ))
        }
        window.orderFrontRegardless()
        // Carbon hotkeys work without Input Monitoring or Accessibility access.
        // Keep event monitors as a fallback when another app reserves Escape.
        registeredEscapeHotKey = HotKeyManager.shared.register(
            keyCode: 53, modifiers: 0, id: Self.escapeHotKeyID
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.onCancel?() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in self?.onCancel?() }
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.onCancel?() }
        }
    }

    func hideForFrame() { window.orderOut(nil) }
    func restoreAfterFrame() { window.orderFrontRegardless() }
    func close() {
        if registeredEscapeHotKey {
            HotKeyManager.shared.unregister(id: Self.escapeHotKeyID)
            registeredEscapeHotKey = false
        }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        localEscapeMonitor = nil
        globalEscapeMonitor = nil
        window.orderOut(nil)
        window.contentView = nil
        preview.image = nil
        onStop = nil
        onCancel = nil
    }

    func updatePreview(_ image: CGImage, addedRows: Int?) {
        let scale = min(1, 268 / CGFloat(image.width), 322 / CGFloat(image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let small = context.makeImage() {
                preview.image = NSImage(cgImage: small, size: NSSize(width: width, height: height))
            }
        }
        if let addedRows {
            status.stringValue = NativeScreenshotUserText.string(
                "新增 \(addedRows) 像素 · 总高 \(image.height) 像素",
                "Added \(addedRows) px · \(image.height) px total")
        }
    }

    func setStatus(_ message: String) { status.stringValue = message }
    @objc private func stopPressed() { onStop?() }
    @objc private func cancelPressed() { onCancel?() }
}

@MainActor
final class NativeScreenshotRecordingHUD: NSObject {
    let window: NSPanel
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let warningLabel = NSTextField(labelWithString: "")
    private var warningMessages: [String] = []
    private var timer: Timer?
    private var startUptime: TimeInterval = 0

    init(showTimer: Bool) {
        window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: showTimer ? 240 : 180, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let root = NSVisualEffectView(frame: CGRect(origin: .zero,
                                                   size: window.frame.size))
        root.material = .hudWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        warningLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 3
        warningLabel.isHidden = true
        root.addSubview(warningLabel)
        if showTimer {
            timerLabel.frame = CGRect(x: 12, y: 14, width: 58, height: 22)
            timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            root.addSubview(timerLabel)
        }
        let left = showTimer ? 73.0 : 12.0
        let stop = NSButton(title: NativeScreenshotUserText.string("停止", "Stop"),
                            target: self, action: #selector(stopPressed))
        stop.frame = CGRect(x: left, y: 11, width: 70, height: 30)
        stop.bezelStyle = .rounded
        root.addSubview(stop)
        let cancel = NSButton(title: NativeScreenshotUserText.string("取消", "Cancel"),
                              target: self, action: #selector(cancelPressed))
        cancel.frame = CGRect(x: left + 73, y: 11, width: 70, height: 30)
        cancel.bezelStyle = .rounded
        root.addSubview(cancel)
        window.contentView = root
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.maxY - window.frame.height - 20
            ))
        }
        startUptime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshElapsed() }
        }
        window.orderFrontRegardless()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        window.contentView = nil
        onStop = nil
        onCancel = nil
    }

    func addWarning(_ message: String) {
        guard !warningMessages.contains(message) else { return }
        warningMessages.append(message)
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: window.frame.width, height: 116))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        warningLabel.frame = CGRect(x: 12, y: 54, width: window.frame.width - 24, height: 56)
        warningLabel.stringValue = warningMessages.joined(separator: "\n")
        warningLabel.isHidden = false
    }

    private func refreshElapsed() {
        let seconds = max(0, Int(ProcessInfo.processInfo.systemUptime - startUptime))
        timerLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    @objc private func stopPressed() { onStop?() }
    @objc private func cancelPressed() { onCancel?() }
}
