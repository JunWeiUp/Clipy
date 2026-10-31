import Cocoa

/// Floating recording control bar with stop, pause/resume, timer, and drag handle.
/// Sits at `.statusBar + 2` so it's above all recording overlays but not captured by SCStream.
class RecordingHUDPanel: NSPanel {

    var onStopRecording: (() -> Void)?
    var onPauseRecording: (() -> Void)?
    var onResumeRecording: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let recordDot = NSTextField(labelWithString: "●")
    private let formatLabel = NSTextField(labelWithString: "")
    private let stopButton = HUDStopButton()
    private let formatChip = NSView()
    private let pauseButton = NSButton()
    private let dragHandle = NSImageView()
    private let containerView = HUDContainerView()
    private(set) var isPaused = false
    fileprivate(set) var userHasDragged = false

    // mac-recording.html `.ctl`: 6pt padding around 36pt controls, 14pt radius.
    private let hudHeight: CGFloat = 48
    private let cornerRadius: CGFloat = 14

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar + 2
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = cornerRadius
        containerView.panel = self
        containerView.layer?.backgroundColor = NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 34 / 255, alpha: 0.92).cgColor
        containerView.layer?.borderWidth = 0.5
        containerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        appearance = NSAppearance(named: .darkAqua)
        contentView = containerView

        setupStopButton()
        setupPauseButton()
        setupTimeLabel()
        let fps = UserDefaults.standard.integer(forKey: "recordingFPS")
        formatLabel.stringValue = "MP4 · \(fps > 0 ? fps : 30)fps"
        formatLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        formatLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        formatLabel.alignment = .center
        formatChip.wantsLayer = true
        formatChip.layer?.cornerRadius = 6
        formatChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        containerView.addSubview(formatChip)
        formatChip.addSubview(formatLabel)
        setupDragHandle()
    }

    // MARK: - Setup

    private func setupStopButton() {
        // Red "结束" button with a white square (mac-recording.html `.stop`).
        stopButton.title = L("End")
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = L("Stop Recording")
        stopButton.setAccessibilityLabel(L("Stop Recording"))
        containerView.addSubview(stopButton)
    }

    private func setupPauseButton() {
        pauseButton.bezelStyle = .regularSquare
        pauseButton.isBordered = false
        pauseButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        pauseButton.imageScaling = .scaleProportionallyDown
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.toolTip = L("Pause")
        updatePauseIcon()
        containerView.addSubview(pauseButton)
    }

    private func setupTimeLabel() {
        recordDot.font = .systemFont(ofSize: 13, weight: .bold)
        recordDot.textColor = .systemRed
        recordDot.isBezeled = false
        recordDot.drawsBackground = false
        recordDot.isEditable = false
        containerView.addSubview(recordDot)

        timeLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        timeLabel.isEditable = false
        containerView.addSubview(timeLabel)
    }

    private func setupDragHandle() {
        // The grip dots are drawn by the container (mac-recording.html `.grip`).
        dragHandle.isHidden = true
    }

    // MARK: - Layout

    private func layoutControls() {
        let h = hudHeight
        // grip · ● 00:42 · [MP4 · 60fps] | pause · 结束 — left to right like the design.
        recordDot.sizeToFit()
        timeLabel.sizeToFit()
        recordDot.frame.origin = NSPoint(x: 26, y: (h - recordDot.frame.height) / 2)
        timeLabel.frame.origin = NSPoint(x: recordDot.frame.maxX + 4, y: (h - timeLabel.frame.height) / 2)
        formatLabel.sizeToFit()
        let fmtW = formatLabel.frame.width + 16
        let fmtChip = NSRect(x: timeLabel.frame.maxX + 12, y: (h - 24) / 2, width: fmtW, height: 24)
        formatChip.frame = fmtChip
        formatLabel.frame = NSRect(x: 0, y: (24 - formatLabel.frame.height) / 2, width: fmtW, height: formatLabel.frame.height)
        let sepX = fmtChip.maxX + 8
        containerView.separatorX = sepX
        pauseButton.frame = NSRect(x: sepX + 8, y: (h - 36) / 2, width: 36, height: 36)
        let stopW = stopButton.preferredWidth
        stopButton.frame = NSRect(x: pauseButton.frame.maxX + 4, y: (h - 36) / 2, width: stopW, height: 36)
        let totalW = stopButton.frame.maxX + 6

        if abs(frame.width - totalW) > 0.5 || frame.height != h {
            var f = frame
            f.size = NSSize(width: totalW, height: h)
            setFrame(f, display: true)
            contentView?.frame.size = f.size
        }
    }

    // MARK: - Public API

    func update(elapsedSeconds: Int) {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        timeLabel.stringValue = String(format: "%02d:%02d", mins, secs)
        layoutControls()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        updatePauseIcon()
        recordDot.textColor = paused ? .systemGray : .systemRed
        pauseButton.toolTip = paused ? L("Resume") : L("Pause")
    }

    /// Position relative to a screen-space rect. Tries above the rect first,
    /// falls back to below if it would go off screen.
    func positionOnScreen(relativeTo screenRect: NSRect, screen: NSScreen?) {
        let w = frame.width
        let h = frame.height
        let gap: CGFloat = 8

        var pillX = screenRect.maxX - w - gap
        var pillY = screenRect.maxY + gap  // above selection

        if let screen = screen {
            let vis = screen.visibleFrame
            // If above would be off screen, place below
            if pillY + h > vis.maxY {
                pillY = screenRect.minY - h - gap
            }
            // Clamp horizontal
            pillX = max(vis.minX + 4, min(pillX, vis.maxX - w - 4))
            // Clamp vertical
            pillY = max(vis.minY + 4, min(pillY, vis.maxY - h - 4))
        }

        setFrameOrigin(NSPoint(x: pillX, y: pillY))
    }

    // MARK: - Actions

    @objc private func stopClicked() { onStopRecording?() }

    @objc private func pauseClicked() {
        if isPaused {
            onResumeRecording?()
        } else {
            onPauseRecording?()
        }
    }

    private func updatePauseIcon() {
        let name = isPaused ? "play.fill" : "pause.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        pauseButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    override var canBecomeKey: Bool { false }
}

// MARK: - Container view (drag handle + hover effects)

private class HUDContainerView: NSView {
    weak var panel: RecordingHUDPanel?
    private var dragOffset: NSPoint = .zero  // offset from panel origin to mouse at drag start
    private var isDragging = false
    private var trackingArea: NSTrackingArea?
    var separatorX: CGFloat = 0 { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if isInDragZone(localPoint) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if isInDragZone(localPoint) {
            isDragging = true
            // Store offset from mouse to panel origin — used for absolute positioning
            let mouseScreen = NSEvent.mouseLocation
            let panelOrigin = panel?.frame.origin ?? .zero
            dragOffset = NSPoint(x: mouseScreen.x - panelOrigin.x, y: mouseScreen.y - panelOrigin.y)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let panel = panel else { return }
        panel.userHasDragged = true
        // Absolute positioning from screen coords — no delta accumulation, no drift
        let mouseScreen = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouseScreen.x - dragOffset.x, y: mouseScreen.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            let localPoint = convert(event.locationInWindow, from: nil)
            if isInDragZone(localPoint) {
                NSCursor.openHand.set()
            }
        }
    }

    /// The grip at the leading edge is the drag zone.
    private func isInDragZone(_ localPoint: NSPoint) -> Bool {
        localPoint.x <= 26
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Grip: 2 × 3 dots at the leading edge.
        NSColor.white.withAlphaComponent(0.4).setFill()
        for row in 0..<3 {
            for col in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(col) * 4.5, y: bounds.midY - 6 + CGFloat(row) * 4.5, width: 2.4, height: 2.4)).fill()
            }
        }
        guard separatorX > 0 else { return }
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSRect(x: separatorX, y: (bounds.height - 24) / 2, width: 0.5, height: 24).fill()
    }
}

/// Red stop button: white rounded square + "结束" (mac-recording.html `.stop`).
private final class HUDStopButton: NSButton {
    private let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
    }
    required init?(coder: NSCoder) { fatalError() }
    var preferredWidth: CGFloat {
        14 + 11 + 7 + ceil((title as NSString).size(withAttributes: [.font: labelFont]).width) + 14
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(isHighlighted ? 0.8 : 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 14, y: bounds.midY - 5.5, width: 11, height: 11), xRadius: 2.5, yRadius: 2.5).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 14 + 11 + 7, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
