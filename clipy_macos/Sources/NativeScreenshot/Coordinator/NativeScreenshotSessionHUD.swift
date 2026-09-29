import AppKit
import CoreGraphics

/// The long capture preview is an image-only window beside the selection.
/// The controls stay in a separate, compact bar below it.
@MainActor
final class NativeScreenshotLongCaptureHUD: NSObject {
    private static let escapeHotKeyID: UInt32 = 0x5343_5245 // SCRE
    let window: NSPanel
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScrollToggle: ((Bool) -> Void)?

    private let preview = NSImageView()
    private var previewWindow: NSPanel?
    private var selectionBorderWindow: NSPanel?
    private let status = NSTextField(labelWithString: "")
    private let autoScrollButton = NSButton()
    private let stopButton = NSButton()
    private let cancelButton = NSButton()
    private var selectionFrame: CGRect?
    private var selectionScreen: NSScreen?
    private var isOpen = false
    private var automaticScrollEnabled = false
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var registeredEscapeHotKey = false

    override init() {
        window = NativeScreenshotHUDPanel(
            contentRect: CGRect(x: 0, y: 0, width: 350, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false

        let bar = NativeScreenshotHUDChrome(frame: CGRect(x: 0, y: 0, width: 350, height: 36))
        status.frame = CGRect(x: 8, y: 7, width: 148, height: 22)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .white
        status.lineBreakMode = .byTruncatingTail
        bar.addSubview(status)

        configureAction(autoScrollButton, title: "", color: .systemBlue,
                        frame: CGRect(x: 164, y: 6, width: 86, height: 24),
                        action: #selector(autoScrollChanged))
        autoScrollButton.setButtonType(.pushOnPushOff)
        bar.addSubview(autoScrollButton)
        configureAction(stopButton,
                        title: NativeScreenshotUserText.string("停止", "Stop"),
                        color: .systemRed,
                        frame: CGRect(x: 258, y: 6, width: 56, height: 24),
                        action: #selector(stopPressed))
        stopButton.setAccessibilityLabel(
            NativeScreenshotUserText.string("结束长截图", "Finish long screenshot"))
        bar.addSubview(stopButton)

        cancelButton.frame = CGRect(x: 320, y: 6, width: 24, height: 24)
        cancelButton.isBordered = false
        cancelButton.bezelStyle = .regularSquare
        cancelButton.image = NSImage(systemSymbolName: "xmark",
                                     accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = .white
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.toolTip = NativeScreenshotUserText.string("取消长截图", "Cancel long screenshot")
        cancelButton.setAccessibilityLabel(cancelButton.toolTip)
        bar.addSubview(cancelButton)
        window.contentView = bar
        setStatus(NativeScreenshotUserText.string("滚动长截图", "Scroll Capture"))
    }

    func show(near selection: CGRect, autoScrollEnabled: Bool) {
        let mapped = NSScreen.screens.compactMap { screen -> (NSScreen, CGRect, CGRect)? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let overlap = selection.intersection(display)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            return (screen, display, overlap)
        }.max { lhs, rhs in
            lhs.2.width * lhs.2.height < rhs.2.width * rhs.2.height
        }
        if let (screen, display, overlap) = mapped {
            selectionScreen = screen
            selectionFrame = CGRect(
                x: screen.frame.minX + overlap.minX - display.minX,
                y: screen.frame.maxY - (overlap.maxY - display.minY),
                width: overlap.width, height: overlap.height)
        } else {
            selectionScreen = NSScreen.main
            selectionFrame = nil
        }

        setAutoScrollEnabled(autoScrollEnabled)
        isOpen = true
        layoutControlBar()
        makeSelectionBorderWindow()
        if let selectionFrame, let visible = selectionScreen?.visibleFrame {
            if NativeScreenshotSessionHUDGeometry.scrollPreviewFrame(
                selection: selectionFrame, visible: visible,
                imagePixels: CGSize(width: 1, height: 1),
                controls: window.frame) != nil {
                makePreviewWindow()
            }
        } else if let visible = selectionScreen?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.maxY - window.frame.height - 16))
        }
        selectionBorderWindow?.orderFrontRegardless()
        window.orderFrontRegardless()
        // A Carbon hotkey works without Input Monitoring or Accessibility.
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

    func hideForFrame() {
        selectionBorderWindow?.orderOut(nil)
        window.orderOut(nil)
        previewWindow?.orderOut(nil)
    }

    func restoreAfterFrame() {
        guard isOpen else { return }
        selectionBorderWindow?.orderFrontRegardless()
        window.orderFrontRegardless()
        if preview.image != nil { previewWindow?.orderFrontRegardless() }
    }

    func close() {
        isOpen = false
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
        selectionBorderWindow?.orderOut(nil)
        selectionBorderWindow?.contentView = nil
        selectionBorderWindow = nil
        previewWindow?.orderOut(nil)
        previewWindow?.contentView = nil
        previewWindow = nil
        preview.image = nil
        onStop = nil
        onCancel = nil
        onAutoScrollToggle = nil
        selectionFrame = nil
        selectionScreen = nil
    }

    func updatePreview(_ image: CGImage, addedRows: Int?) {
        guard isOpen else { return }
        setStatus(NativeScreenshotUserText.string(
            "长截图 · \(image.width)×\(image.height)",
            "Scroll Capture · \(image.width)×\(image.height)"))
        if let addedRows {
            status.toolTip = NativeScreenshotUserText.string(
                "新增 \(addedRows) 像素 · 总高 \(image.height) 像素",
                "Added \(addedRows) px · \(image.height) px total")
        }
        guard let previewWindow, let selectionFrame,
              let visible = selectionScreen?.visibleFrame,
              let frame = NativeScreenshotSessionHUDGeometry.scrollPreviewFrame(
                selection: selectionFrame, visible: visible,
                imagePixels: CGSize(width: image.width, height: image.height),
                controls: window.frame)
        else { return }
        let maximumWidth: CGFloat = NativeScreenshotSessionHUDGeometry.previewWidth - 8
        let scale = min(1, maximumWidth / CGFloat(max(1, image.width)),
                        900 / CGFloat(max(1, image.height)))
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
                preview.image = NSImage(cgImage: small, size: CGSize(width: width, height: height))
            }
        }
        previewWindow.setFrame(frame, display: true)
        preview.frame = CGRect(origin: .zero, size: frame.size)
        previewWindow.orderFrontRegardless()
    }

    func setStatus(_ message: String) {
        status.stringValue = message
        status.toolTip = message
        if isOpen { layoutControlBar() }
    }

    func setAutoScrollEnabled(_ enabled: Bool) {
        automaticScrollEnabled = enabled
        autoScrollButton.state = enabled ? .on : .off
        autoScrollButton.title = enabled
            ? NativeScreenshotUserText.string("滚动中…", "Scrolling…")
            : NativeScreenshotUserText.string("自动滚动", "Auto Scroll")
        autoScrollButton.layer?.backgroundColor =
            (enabled ? NSColor.systemOrange : .systemBlue)
                .withAlphaComponent(0.85).cgColor
        autoScrollButton.toolTip = NativeScreenshotUserText.string(
            enabled ? "切换到手动滚动" : "切换到自动滚动",
            enabled ? "Switch to manual scrolling" : "Switch to automatic scrolling")
        autoScrollButton.setAccessibilityLabel(autoScrollButton.toolTip)
    }

    private func makePreviewWindow() {
        guard previewWindow == nil else { return }
        let panel = NativeScreenshotHUDPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignTop
        preview.autoresizingMask = [.width, .height]
        preview.frame = container.bounds
        preview.setAccessibilityLabel(NativeScreenshotUserText.string(
            "长截图实时预览", "Live long screenshot preview"))
        container.addSubview(preview)
        panel.contentView = container
        previewWindow = panel
    }

    private func makeSelectionBorderWindow() {
        guard selectionBorderWindow == nil, let selectionFrame else { return }
        let inset: CGFloat = 2.5
        let frame = selectionFrame.insetBy(dx: -inset, dy: -inset)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NativeScreenshotCaptureBorderView(
            frame: CGRect(origin: .zero, size: frame.size),
            selectionInset: inset, phase: .scrolling,
            accent: .controlAccentColor)
        selectionBorderWindow = panel
    }

    private func layoutControlBar() {
        let measured = (status.stringValue as NSString).size(
            withAttributes: [.font: status.font ?? .systemFont(ofSize: 12)]).width
        let screenWidth = selectionScreen?.visibleFrame.width ?? 600
        let labelWidth = min(max(148, ceil(measured) + 4),
                             240, max(80, screenWidth - 210))
        let width = labelWidth + 202
        status.frame.size.width = labelWidth
        autoScrollButton.frame.origin.x = labelWidth + 16
        stopButton.frame.origin.x = labelWidth + 110
        cancelButton.frame.origin.x = labelWidth + 172
        window.setContentSize(NSSize(width: width, height: 36))
        if let selectionFrame, let visible = selectionScreen?.visibleFrame {
            window.setFrame(
                NativeScreenshotSessionHUDGeometry.scrollControlFrame(
                    selection: selectionFrame, visible: visible, width: width),
                display: true)
        }
    }

    private func configureAction(
        _ button: NSButton, title: String, color: NSColor,
        frame: CGRect, action: Selector
    ) {
        button.title = title
        button.frame = frame
        button.bezelStyle = .recessed
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
        button.contentTintColor = .white
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = action
    }

    @objc private func autoScrollChanged() {
        let next = !automaticScrollEnabled
        setAutoScrollEnabled(next)
        onAutoScrollToggle?(next)
    }
    @objc private func stopPressed() { onStop?() }
    @objc private func cancelPressed() { onCancel?() }
}

private final class NativeScreenshotCaptureBorderView: NSView {
    private let selectionInset: CGFloat
    private let phase: NativeScreenshotSelectionChrome.Phase
    private let accent: NSColor

    init(frame: CGRect, selectionInset: CGFloat,
         phase: NativeScreenshotSelectionChrome.Phase, accent: NSColor) {
        self.selectionInset = selectionInset
        self.phase = phase
        self.accent = accent
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NativeScreenshotSelectionChrome.draw(
            in: context,
            rect: bounds.insetBy(dx: selectionInset, dy: selectionInset),
            style: NativeScreenshotSelectionChrome.style(
                for: phase, accent: accent))
    }
}

@MainActor
final class NativeScreenshotRecordingHUD: NSObject {
    let window: NSPanel
    var captureExcludedWindowNumbers: Set<Int> {
        var numbers: Set<Int> = [window.windowNumber]
        if let selectionBorderWindow, selectionBorderWindow.isVisible {
            numbers.insert(selectionBorderWindow.windowNumber)
        }
        return numbers
    }
    var visibleSelectionBorderWindowNumber: Int? {
        guard let selectionBorderWindow, selectionBorderWindow.isVisible else { return nil }
        return selectionBorderWindow.windowNumber
    }
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPauseToggle: (() -> Void)?

    private let bar = NativeScreenshotHUDChrome(frame: CGRect(x: 0, y: 0, width: 164, height: 32))
    private let warningBox = NativeScreenshotHUDChrome(frame: .zero)
    private var selectionBorderWindow: NSPanel?
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let recordDot = NSTextField(labelWithString: "●")
    private let warningLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private let dragHandle = NativeScreenshotHUDDragHandle(
        frame: CGRect(x: 134, y: 0, width: 30, height: 32))
    private var warningMessages: [String] = []
    private var timer: Timer?
    private var startUptime: TimeInterval?
    private var pauseUptime: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var isPaused = false
    private let showTimer: Bool

    init(showTimer: Bool) {
        self.showTimer = showTimer
        window = NativeScreenshotHUDPanel(
            contentRect: CGRect(x: 0, y: 0, width: 164, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false

        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        root.autoresizingMask = [.width, .height]
        root.addSubview(bar)
        window.contentView = root

        configureIcon(stopButton, symbol: "stop.fill",
                      label: NativeScreenshotUserText.string(
                        "结束并保存录屏；按住 Option 点击可丢弃",
                        "Finish and save; Option-click to discard"),
                      frame: CGRect(x: 6, y: 4, width: 24, height: 24),
                      action: #selector(stopPressed))
        bar.addSubview(stopButton)
        configureIcon(pauseButton, symbol: "pause.fill",
                      label: NativeScreenshotUserText.string("暂停录屏", "Pause recording"),
                      frame: CGRect(x: 32, y: 4, width: 24, height: 24),
                      action: #selector(pausePressed))
        pauseButton.isEnabled = false
        bar.addSubview(pauseButton)

        recordDot.frame = CGRect(x: 64, y: 7, width: 14, height: 18)
        recordDot.font = .systemFont(ofSize: 11, weight: .bold)
        recordDot.textColor = .systemRed
        recordDot.isHidden = !showTimer
        bar.addSubview(recordDot)
        timerLabel.frame = CGRect(x: 79, y: 6, width: 55, height: 19)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timerLabel.textColor = .white
        timerLabel.isHidden = !showTimer
        bar.addSubview(timerLabel)
        bar.addSubview(dragHandle)

        warningBox.isHidden = true
        warningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 3
        warningBox.addSubview(warningLabel)
        root.addSubview(warningBox)

        let menu = NSMenu()
        let cancel = menu.addItem(
            withTitle: NativeScreenshotUserText.string("取消并丢弃录屏", "Discard recording"),
            action: #selector(cancelPressed), keyEquivalent: "")
        cancel.target = self
        root.menu = menu
        bar.menu = menu
        dragHandle.menu = menu
    }

    /// `region` uses ScreenCaptureKit's display frame (top-left origin).
    func show(near region: CGRect? = nil, displayID: CGDirectDisplayID? = nil) {
        if let region, let displayID {
            NativeScreenshotRecordingPanelPlacement.place(window, near: region,
                                                           displayID: displayID)
            makeSelectionBorderWindow(region: region, displayID: displayID)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.maxY - window.frame.height - 20))
        }
        selectionBorderWindow?.orderFrontRegardless()
        window.orderFrontRegardless()
    }

    private func makeSelectionBorderWindow(region: CGRect, displayID: CGDirectDisplayID) {
        guard selectionBorderWindow == nil,
              let selection = NativeScreenshotRecordingPanelPlacement.selectionFrame(
                region: region, displayID: displayID) else { return }
        let inset: CGFloat = 3
        let frame = selection.insetBy(dx: -inset, dy: -inset)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NativeScreenshotCaptureBorderView(
            frame: CGRect(origin: .zero, size: frame.size),
            selectionInset: inset, phase: .recording,
            accent: PreferencesManager.shared.nativeScreenshotToolbarConfiguration.accentColor)
        selectionBorderWindow = panel
    }

    func hideSelectionBorder() {
        selectionBorderWindow?.orderOut(nil)
    }

    /// Start the visible clock only after ScreenCaptureKit starts delivering.
    func startTiming() {
        startUptime = ProcessInfo.processInfo.systemUptime
        pauseUptime = nil
        pausedDuration = 0
        isPaused = false
        pauseButton.isEnabled = true
        refreshElapsed()
        timer?.invalidate()
        if showTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshElapsed() }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        guard startUptime != nil, paused != isPaused else { return }
        isPaused = paused
        let now = ProcessInfo.processInfo.systemUptime
        if paused {
            pauseUptime = now
        } else {
            if let pauseUptime { pausedDuration += max(0, now - pauseUptime) }
            pauseUptime = nil
        }
        pauseButton.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        pauseButton.toolTip = NativeScreenshotUserText.string(
            paused ? "继续录屏" : "暂停录屏",
            paused ? "Resume recording" : "Pause recording")
        pauseButton.setAccessibilityLabel(pauseButton.toolTip)
        recordDot.textColor = paused ? .systemOrange : .systemRed
        refreshElapsed()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        selectionBorderWindow?.orderOut(nil)
        selectionBorderWindow?.contentView = nil
        selectionBorderWindow = nil
        window.orderOut(nil)
        window.contentView = nil
        onStop = nil
        onCancel = nil
        onPauseToggle = nil
        warningMessages.removeAll()
    }

    func addWarning(_ message: String) {
        guard !warningMessages.contains(message) else { return }
        warningMessages.append(message)
        if warningMessages.count > 3 { warningMessages.removeFirst() }
        warningLabel.stringValue = warningMessages.joined(separator: "\n")
        warningLabel.toolTip = warningLabel.stringValue
        warningBox.isHidden = false
        warningBox.frame = CGRect(x: 0, y: 38, width: 300, height: 68)
        warningLabel.frame = CGRect(x: 10, y: 7, width: 280, height: 54)
        let origin = window.frame.origin
        window.setContentSize(NSSize(width: 300, height: 106))
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: max(visible.minX + 4, min(origin.x, visible.maxX - 304)),
                y: max(visible.minY + 4, min(origin.y, visible.maxY - 110))))
        } else {
            window.setFrameOrigin(origin)
        }
    }

    private func configureIcon(
        _ button: NSButton, symbol: String, label: String,
        frame: CGRect, action: Selector
    ) {
        button.frame = frame
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    private func refreshElapsed() {
        guard showTimer, let startUptime else { return }
        let now = pauseUptime ?? ProcessInfo.processInfo.systemUptime
        let seconds = max(0, Int(now - startUptime - pausedDuration))
        timerLabel.stringValue = seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        timerLabel.font = .monospacedDigitSystemFont(
            ofSize: seconds >= 3_600 ? 10 : 13, weight: .semibold)
    }

    @objc private func pausePressed() { onPauseToggle?() }
    @objc private func stopPressed() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { onCancel?() }
        else { onStop?() }
    }
    @objc private func cancelPressed() { onCancel?() }
}

private final class NativeScreenshotHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class NativeScreenshotHUDChrome: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(
            calibratedWhite: 0.12, alpha: 0.94).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

private final class NativeScreenshotHUDDragHandle: NSView {
    private var pointerOffset: NSPoint?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        pointerOffset = NSPoint(
            x: pointer.x - window.frame.minX,
            y: pointer.y - window.frame.minY)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let pointerOffset else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: pointer.x - pointerOffset.x,
            y: pointer.y - pointerOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        pointerOffset = nil
        NSCursor.openHand.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 1, y: 7))
        separator.line(to: NSPoint(x: 1, y: bounds.height - 7))
        separator.lineWidth = 0.5
        separator.stroke()
        let glyph = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        glyph?.draw(in: CGRect(x: 8, y: 8, width: 15, height: 16),
                    from: .zero, operation: .sourceOver, fraction: 0.45)
    }
}
