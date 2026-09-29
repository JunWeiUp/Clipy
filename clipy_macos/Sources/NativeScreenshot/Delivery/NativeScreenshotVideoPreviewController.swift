import AppKit
import AVFoundation
import AVKit
import CoreImage
import UniformTypeIdentifiers

@MainActor
private final class NativeScreenshotVideoEditorWindow: NSWindow {
    var onPlaybackKey: ((UInt16) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !(firstResponder is NSTextView),
           [UInt16(49), 123, 124].contains(event.keyCode) {
            onPlaybackKey?(event.keyCode)
            return
        }
        super.sendEvent(event)
    }
}

/// One cut range and playhead, shared by the sliders and the film timeline.
@MainActor
private final class NativeScreenshotVideoTimeline: NSView {
    enum DragTarget {
        case start, end, playhead
        case segmentStart(Int), segmentEnd(Int), segmentMove(Int, TimeInterval)
    }
    var duration: TimeInterval = 1 { didSet { needsDisplay = true } }
    var start: TimeInterval = 0 { didSet { needsDisplay = true } }
    var end: TimeInterval = 1 { didSet { needsDisplay = true } }
    var playhead: TimeInterval = 0 { didSet { needsDisplay = true } }
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }
    var segments: [NativeScreenshotVideoEffectSegment] = [] { didSet { needsDisplay = true } }
    var onStartChanged: ((TimeInterval) -> Void)?
    var onEndChanged: ((TimeInterval) -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onSegmentChanged: ((Int, TimeInterval, TimeInterval) -> Void)?
    private var dragTarget: DragTarget?
    private let inset: CGFloat = 10

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = CGRect(x: inset, y: 5, width: max(1, bounds.width - inset * 2),
                           height: max(1, bounds.height - 10))
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()
        if !thumbnails.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).addClip()
            let slice = track.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                image.draw(in: CGRect(x: track.minX + CGFloat(index) * slice,
                                      y: track.minY, width: slice, height: track.height),
                           from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        for segment in segments {
            let left = xPosition(for: segment.start)
            let right = xPosition(for: segment.end)
            let color: NSColor
            switch segment.content {
            case .cut: color = .systemGray
            case .speed: color = .systemGreen
            case .zoom: color = .systemOrange
            case .redaction, .styledRedaction: color = .systemRed
            case .text, .styledText: color = .systemPurple
            }
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: left, y: track.maxY - 6,
                                            width: max(2, right - left), height: 5),
                         xRadius: 2, yRadius: 2).fill()
        }
        guard duration > 0 else { return }
        let selected = CGRect(x: xPosition(for: start), y: track.minY,
                              width: max(2, xPosition(for: end) - xPosition(for: start)),
                              height: track.height)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: selected, xRadius: 4, yRadius: 4).fill()
        for segment in segments {
            guard case .cut = segment.content else { continue }
            let left = xPosition(for: segment.start)
            let right = xPosition(for: segment.end)
            let deleted = CGRect(x: left, y: track.minY,
                                 width: max(2, right - left), height: track.height)
            NSColor.black.withAlphaComponent(0.68).setFill()
            NSBezierPath(rect: deleted).fill()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let stripes = NSBezierPath()
            stride(from: deleted.minX - deleted.height, through: deleted.maxX,
                   by: CGFloat(12)).forEach { x in
                stripes.move(to: CGPoint(x: max(deleted.minX, x),
                                         y: deleted.minY + max(0, deleted.minX - x)))
                stripes.line(to: CGPoint(x: min(deleted.maxX, x + deleted.height),
                                         y: deleted.maxY - max(0, x + deleted.height - deleted.maxX)))
            }
            stripes.lineWidth = 1
            stripes.stroke()
        }
        NSColor.controlAccentColor.setFill()
        for position in [xPosition(for: start), xPosition(for: end)] {
            NSBezierPath(roundedRect: CGRect(x: position - 3, y: track.minY,
                                            width: 6, height: track.height),
                         xRadius: 2, yRadius: 2).fill()
        }
        NSColor.labelColor.setStroke()
        let cursor = NSBezierPath()
        cursor.move(to: CGPoint(x: xPosition(for: playhead), y: 1))
        cursor.line(to: CGPoint(x: xPosition(for: playhead), y: bounds.height - 1))
        cursor.lineWidth = 1.5
        cursor.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= bounds.height - 13 {
            for index in segments.indices.reversed() {
                let left = xPosition(for: segments[index].start)
                let right = xPosition(for: segments[index].end)
                if abs(point.x - left) <= 9 {
                    dragTarget = .segmentStart(index)
                    return
                }
                if abs(point.x - right) <= 9 {
                    dragTarget = .segmentEnd(index)
                    return
                }
                if point.x > left && point.x < right {
                    let clickedTime = TimeInterval((point.x - inset)
                        / max(1, bounds.width - inset * 2)) * duration
                    dragTarget = .segmentMove(index, clickedTime - segments[index].start)
                    return
                }
            }
        }
        let startDistance = abs(point.x - xPosition(for: start))
        let endDistance = abs(point.x - xPosition(for: end))
        if min(startDistance, endDistance) <= 12 {
            dragTarget = startDistance <= endDistance ? .start : .end
        } else {
            dragTarget = .playhead
        }
        updateDrag(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { dragTarget = nil }

    private func updateDrag(at point: CGPoint) {
        let value = min(duration, max(0, TimeInterval(
            (point.x - inset) / max(1, bounds.width - inset * 2)) * duration))
        switch dragTarget {
        case .start:
            onStartChanged?(min(value, end - 0.1))
        case .end:
            onEndChanged?(max(value, start + 0.1))
        case .playhead:
            onSeek?(min(end, max(start, value)))
        case .segmentStart(let index):
            guard segments.indices.contains(index) else { return }
            onSegmentChanged?(index, min(value, segments[index].end - 0.1),
                              segments[index].end)
        case .segmentEnd(let index):
            guard segments.indices.contains(index) else { return }
            onSegmentChanged?(index, segments[index].start,
                              max(value, segments[index].start + 0.1))
        case .segmentMove(let index, let offset):
            guard segments.indices.contains(index) else { return }
            let length = segments[index].end - segments[index].start
            let newStart = min(max(0, value - offset), max(0, duration - length))
            onSegmentChanged?(index, newStart, newStart + length)
        case nil:
            break
        }
    }

    private func xPosition(for value: TimeInterval) -> CGFloat {
        inset + CGFloat(min(1, max(0, value / max(duration, 0.1))))
            * max(1, bounds.width - inset * 2)
    }
}

@MainActor
private final class NativeScreenshotVideoEffectCanvas: NSView {
    enum Mode { case none, redaction, text }
    var mode: Mode = .none { didSet { needsDisplay = true } }
    var videoAspect: CGFloat = 16 / 9 { didSet { needsDisplay = true } }
    var redaction: CGRect? { didSet { needsDisplay = true } }
    var text: String = "" { didSet { needsDisplay = true } }
    var isCutPreviewActive = false { didSet { needsDisplay = true } }
    var textPosition = CGPoint(x: 0.06, y: 0.12) { didSet { needsDisplay = true } }
    var onRedaction: ((CGRect?) -> Void)?
    var onTextPosition: ((CGPoint) -> Void)?
    private var dragOrigin: CGPoint?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        mode == .none ? nil : super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let imageRect = displayedVideoRect
        // The AVPlayerItem video composition renders the actual picture
        // effects. This canvas keeps only selection guides, so preview and
        // exported colors, blur, pixels and fades come from one renderer.
        if mode == .redaction, let redaction {
            let region = CGRect(x: imageRect.minX + redaction.minX * imageRect.width,
                                y: imageRect.minY + redaction.minY * imageRect.height,
                                width: redaction.width * imageRect.width,
                                height: redaction.height * imageRect.height)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: region)
            path.lineWidth = 2
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
        }
        if mode == .text {
            let center = CGPoint(x: imageRect.minX + textPosition.x * imageRect.width,
                                 y: imageRect.minY + textPosition.y * imageRect.height)
            NSColor.controlAccentColor.setStroke()
            let marker = NSBezierPath()
            marker.move(to: CGPoint(x: center.x - 8, y: center.y))
            marker.line(to: CGPoint(x: center.x + 8, y: center.y))
            marker.move(to: CGPoint(x: center.x, y: center.y - 8))
            marker.line(to: CGPoint(x: center.x, y: center.y + 8))
            marker.lineWidth = 2
            marker.stroke()
        }
        if isCutPreviewActive {
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(rect: imageRect).fill()
            let label = NativeScreenshotUserText.string("此段将在导出时删除", "This interval will be cut")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: imageRect.midX - size.width / 2,
                                                  y: imageRect.midY - size.height / 2),
                                      withAttributes: attributes)
        }
        if mode != .none {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: imageRect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = normalized(convert(event.locationInWindow, from: nil))
        switch mode {
        case .redaction:
            dragOrigin = point
            redaction = CGRect(origin: point, size: .zero)
        case .text:
            textPosition = point
            onTextPosition?(point)
            mode = .none
        case .none:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .redaction, let dragOrigin else { return }
        let point = normalized(convert(event.locationInWindow, from: nil))
        redaction = CGRect(x: min(dragOrigin.x, point.x),
                           y: min(dragOrigin.y, point.y),
                           width: abs(point.x - dragOrigin.x),
                           height: abs(point.y - dragOrigin.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .redaction else { return }
        defer { dragOrigin = nil; mode = .none }
        if let redaction, redaction.width >= 0.01 && redaction.height >= 0.01 {
            onRedaction?(redaction)
        } else {
            redaction = nil
            onRedaction?(nil)
        }
    }

    private var displayedVideoRect: CGRect {
        let aspect = max(0.1, videoAspect)
        if bounds.width / max(1, bounds.height) > aspect {
            let width = bounds.height * aspect
            return CGRect(x: (bounds.width - width) / 2, y: 0,
                          width: width, height: bounds.height)
        }
        let height = bounds.width / aspect
        return CGRect(x: 0, y: (bounds.height - height) / 2,
                      width: bounds.width, height: height)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = displayedVideoRect
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
                       y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height))))
    }
}

@MainActor
enum NativeScreenshotRecordingDeliveryService {
    static func deliver(_ videoURL: URL, action: String) {
        switch action {
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([videoURL])
        case "clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([videoURL as NSURL])
        default: NativeScreenshotVideoPreviewController.open(videoURL)
        }
    }
}

@MainActor
final class NativeScreenshotVideoPreviewController: NSObject, NSWindowDelegate,
    NSTextFieldDelegate {
    private static var windows: [UUID: NativeScreenshotVideoPreviewController] = [:]
    private let id = UUID()
    private let videoURL: URL
    private let window: NativeScreenshotVideoEditorWindow
    private let playerView: AVPlayerView
    private let effectCanvas = NativeScreenshotVideoEffectCanvas(frame: .zero)
    private let timeline = NativeScreenshotVideoTimeline(frame: .zero)
    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let startLabel = NSTextField(labelWithString: "00:00:00")
    private let endLabel = NSTextField(labelWithString: "00:00:00")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let qualityPicker = NSPopUpButton()
    private let outputScalePicker = NSPopUpButton()
    private let outputFPSPicker = NSPopUpButton()
    private let gifFPSPicker = NSPopUpButton()
    private let gifSizePicker = NSPopUpButton()
    private let previewSpeedPicker = NSPopUpButton()
    private let muteButton = NSButton()
    private let segmentPicker = NSPopUpButton()
    private var effectSegments: [NativeScreenshotVideoEffectSegment] = []
    private let zoomPicker = NSPopUpButton()
    private let freezeButton = NSButton()
    private let freezeDurationPicker = NSPopUpButton()
    private let redactButton = NSButton()
    private let redactionOptionsButton = NSButton()
    private let textField = NSTextField()
    private let textPlaceButton = NSButton()
    private let textOptionsButton = NSButton()
    private var redactionStyle = NativeScreenshotVideoRedactionStyle()
    private var textStyle = NativeScreenshotVideoTextStyle()
    private let mp4Button: NSButton
    private let gifButton: NSButton
    private let gifPreviewButton: NSButton
    private let cancelButton: NSButton
    private var duration: TimeInterval = 0
    private var freezeAt: TimeInterval?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var sourceFrameRate: Double = 30
    private var skippingCut = false
    private var previewCompositionUpdate: DispatchWorkItem?
    private var exportWorker: Task<URL, Error>?
    private var completionTask: Task<Void, Never>?
    private var gifPreviewWindow: NSWindow?
    private var gifPreviewURL: URL?
    private var closed = false

    static func open(_ videoURL: URL) {
        let controller = NativeScreenshotVideoPreviewController(videoURL: videoURL)
        windows[controller.id] = controller
        controller.show()
    }

    private init(videoURL: URL) {
        self.videoURL = videoURL
        window = NativeScreenshotVideoEditorWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        playerView = AVPlayerView(frame: CGRect(x: 20, y: 368, width: 760, height: 372))
        mp4Button = NSButton(title: NativeScreenshotUserText.string("导出 MP4", "Export MP4"),
                             target: nil, action: nil)
        gifButton = NSButton(title: NativeScreenshotUserText.string("导出 GIF", "Export GIF"),
                             target: nil, action: nil)
        gifPreviewButton = NSButton(title: NativeScreenshotUserText.string("预览 GIF", "Preview GIF"),
                                    target: nil, action: nil)
        cancelButton = NSButton(title: NativeScreenshotUserText.string("取消导出", "Cancel export"),
                                target: nil, action: nil)
        super.init()
        window.title = videoURL.lastPathComponent
        window.minSize = NSSize(width: 800, height: 650)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.onPlaybackKey = { [weak self] code in self?.handlePlaybackKey(code) }

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .floating
        let player = AVPlayer(url: videoURL)
        playerView.player = player
        container.addSubview(playerView)
        effectCanvas.frame = playerView.frame
        effectCanvas.autoresizingMask = [.width, .height]
        effectCanvas.onRedaction = { [weak self] _ in
            self?.redactButton.state = .off
            self?.schedulePreviewCompositionUpdate()
        }
        effectCanvas.onTextPosition = { [weak self] _ in
            self?.textPlaceButton.state = .off
            self?.schedulePreviewCompositionUpdate()
        }
        container.addSubview(effectCanvas)

        let addSegment = NSButton(title: NativeScreenshotUserText.string(
            "添加效果段…", "Add effect segment…"), target: self,
            action: #selector(addEffectSegment))
        addSegment.frame = CGRect(x: 20, y: 293, width: 125, height: 30)
        addSegment.bezelStyle = .rounded
        addSegment.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(addSegment)
        segmentPicker.addItem(withTitle: NativeScreenshotUserText.string(
            "无效果段", "No effect segments"))
        segmentPicker.frame = CGRect(x: 150, y: 293, width: 465, height: 30)
        segmentPicker.autoresizingMask = [.width, .maxYMargin]
        segmentPicker.target = self
        segmentPicker.action = #selector(selectEffectSegment)
        container.addSubview(segmentPicker)
        let removeSegment = NSButton(title: NativeScreenshotUserText.string(
            "移除效果段", "Remove segment"), target: self,
            action: #selector(removeEffectSegment))
        removeSegment.frame = CGRect(x: 624, y: 293, width: 156, height: 30)
        removeSegment.bezelStyle = .rounded
        removeSegment.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(removeSegment)

        freezeButton.title = NativeScreenshotUserText.string("定格当前帧", "Freeze frame")
        freezeButton.bezelStyle = .rounded
        freezeButton.setButtonType(.toggle)
        freezeButton.target = self
        freezeButton.action = #selector(toggleFreeze)
        freezeButton.frame = CGRect(x: 20, y: 254, width: 112, height: 30)
        freezeButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        freezeButton.isEnabled = false
        container.addSubview(freezeButton)
        freezeDurationPicker.addItems(withTitles: ["0.5 s", "1 s", "2 s"])
        freezeDurationPicker.selectItem(at: 1)
        freezeDurationPicker.frame = CGRect(x: 137, y: 254, width: 95, height: 30)
        freezeDurationPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        freezeDurationPicker.setAccessibilityLabel(NativeScreenshotUserText.string(
            "定格时长", "Freeze duration"))
        container.addSubview(freezeDurationPicker)
        zoomPicker.addItems(withTitles: ["1×", "1.25×", "1.5×", "2×"])
        zoomPicker.frame = CGRect(x: 237, y: 254, width: 99, height: 30)
        zoomPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        zoomPicker.target = self
        zoomPicker.action = #selector(zoomPreviewChanged)
        zoomPicker.setAccessibilityLabel(NativeScreenshotUserText.string(
            "导出画面缩放", "Export zoom"))
        container.addSubview(zoomPicker)
        redactButton.title = NativeScreenshotUserText.string("选择遮挡", "Redact area")
        redactButton.bezelStyle = .rounded
        redactButton.setButtonType(.toggle)
        redactButton.target = self
        redactButton.action = #selector(toggleRedaction)
        redactButton.frame = CGRect(x: 341, y: 254, width: 99, height: 30)
        redactButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(redactButton)
        textField.placeholderString = NativeScreenshotUserText.string("叠加文字", "Overlay text")
        textField.frame = CGRect(x: 445, y: 256, width: 195, height: 25)
        textField.autoresizingMask = [.maxXMargin, .maxYMargin]
        textField.target = self
        textField.action = #selector(textChanged)
        textField.delegate = self
        container.addSubview(textField)
        textPlaceButton.title = NativeScreenshotUserText.string("放置文字", "Place text")
        textPlaceButton.bezelStyle = .rounded
        textPlaceButton.setButtonType(.toggle)
        textPlaceButton.target = self
        textPlaceButton.action = #selector(toggleTextPlacement)
        textPlaceButton.frame = CGRect(x: 646, y: 254, width: 134, height: 30)
        textPlaceButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(textPlaceButton)
        redactionOptionsButton.title = NativeScreenshotUserText.string(
            "遮挡设置…", "Redaction options…")
        redactionOptionsButton.bezelStyle = .rounded
        redactionOptionsButton.target = self
        redactionOptionsButton.action = #selector(editRedactionStyle)
        redactionOptionsButton.frame = CGRect(x: 20, y: 331, width: 166, height: 30)
        redactionOptionsButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(redactionOptionsButton)
        textOptionsButton.title = NativeScreenshotUserText.string(
            "文字设置…", "Text options…")
        textOptionsButton.bezelStyle = .rounded
        textOptionsButton.target = self
        textOptionsButton.action = #selector(editTextStyle)
        textOptionsButton.frame = CGRect(x: 193, y: 331, width: 166, height: 30)
        textOptionsButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(textOptionsButton)

        timeline.frame = CGRect(x: 20, y: 198, width: 760, height: 53)
        timeline.autoresizingMask = [.width, .maxYMargin]
        timeline.setAccessibilityLabel(NativeScreenshotUserText.string(
            "剪辑时间轴，拖动两端调整片段，点击中间定位播放位置",
            "Editing timeline. Drag either end to trim or click inside to seek"))
        timeline.onStartChanged = { [weak self] value in
            self?.startSlider.doubleValue = value
            self?.startChanged()
        }
        timeline.onEndChanged = { [weak self] value in
            self?.endSlider.doubleValue = value
            self?.endChanged()
        }
        timeline.onSeek = { [weak self] value in self?.seek(to: value) }
        timeline.onSegmentChanged = { [weak self] index, start, end in
            guard let self, self.effectSegments.indices.contains(index) else { return }
            self.effectSegments[index].start = start
            self.effectSegments[index].end = end
            self.refreshEffectSegments()
            self.segmentPicker.selectItem(at: index)
        }
        container.addSubview(timeline)

        configureSlider(startSlider, action: #selector(startChanged), y: 167, in: container)
        configureSlider(endSlider, action: #selector(endChanged), y: 131, in: container)
        addLabel(NativeScreenshotUserText.string("起点", "Start"), x: 20, y: 170, in: container)
        addLabel(NativeScreenshotUserText.string("终点", "End"), x: 20, y: 134, in: container)
        for (label, y) in [(startLabel, CGFloat(170)), (endLabel, CGFloat(134))] {
            label.frame = CGRect(x: 660, y: y, width: 115, height: 20)
            label.alignment = .right
            label.autoresizingMask = [.minXMargin, .maxYMargin]
            container.addSubview(label)
        }
        qualityPicker.addItems(withTitles: [
            NativeScreenshotUserText.string("MP4 无损", "MP4 lossless"),
            NativeScreenshotUserText.string("MP4 标准", "MP4 standard"),
            NativeScreenshotUserText.string("MP4 高质量", "MP4 high quality")
        ])
        qualityPicker.toolTip = NativeScreenshotUserText.string(
            "无损模式不重新编码，剪切点可能对齐关键帧；编辑效果需要标准或高质量重新编码。",
            "Lossless mode avoids re-encoding and cuts may align to keyframes; edits require standard or high-quality encoding.")
        qualityPicker.frame = CGRect(x: 20, y: 94, width: 145, height: 30)
        qualityPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(qualityPicker)
        gifFPSPicker.addItems(withTitles: (5...30).map { "GIF \($0) FPS" })
        gifFPSPicker.selectItem(at: 10)
        gifFPSPicker.frame = CGRect(x: 171, y: 94, width: 112, height: 30)
        gifFPSPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        gifFPSPicker.setAccessibilityLabel(NativeScreenshotUserText.string(
            "GIF 帧率", "GIF frame rate"))
        container.addSubview(gifFPSPicker)
        gifSizePicker.addItems(withTitles: ["GIF 480 px", "GIF 720 px", "GIF 960 px"])
        gifSizePicker.selectItem(at: 2)
        gifSizePicker.frame = CGRect(x: 289, y: 94, width: 115, height: 30)
        gifSizePicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        gifSizePicker.setAccessibilityLabel(NativeScreenshotUserText.string(
            "GIF 最大边长", "GIF maximum dimension"))
        container.addSubview(gifSizePicker)
        previewSpeedPicker.addItems(withTitles: [
            NativeScreenshotUserText.string("速度 0.5×", "Speed 0.5×"),
            NativeScreenshotUserText.string("速度 1×", "Speed 1×"),
            NativeScreenshotUserText.string("速度 1.5×", "Speed 1.5×"),
            NativeScreenshotUserText.string("速度 2×", "Speed 2×")
        ])
        previewSpeedPicker.selectItem(at: 1)
        previewSpeedPicker.target = self
        previewSpeedPicker.action = #selector(previewSpeedChanged)
        previewSpeedPicker.frame = CGRect(x: 410, y: 94, width: 112, height: 30)
        previewSpeedPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        previewSpeedPicker.toolTip = NativeScreenshotUserText.string(
            "同时调整预览和导出片段的速度。",
            "Changes both preview playback and exported clip speed.")
        container.addSubview(previewSpeedPicker)
        outputScalePicker.addItems(withTitles: ["MP4 25%", "MP4 33%", "MP4 50%",
                                                    "MP4 75%", "MP4 100%"])
        outputScalePicker.selectItem(at: 4)
        outputScalePicker.frame = CGRect(x: 528, y: 94, width: 115, height: 30)
        outputScalePicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        outputScalePicker.setAccessibilityLabel(NativeScreenshotUserText.string(
            "MP4 输出比例", "MP4 output scale"))
        container.addSubview(outputScalePicker)
        outputFPSPicker.addItems(withTitles: [
            NativeScreenshotUserText.string("MP4 原帧率", "MP4 source FPS"),
            "MP4 15 FPS", "MP4 30 FPS", "MP4 60 FPS"])
        outputFPSPicker.selectItem(at: 0)
        outputFPSPicker.frame = CGRect(x: 649, y: 94, width: 131, height: 30)
        outputFPSPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        outputFPSPicker.setAccessibilityLabel(NativeScreenshotUserText.string(
            "MP4 输出帧率", "MP4 output frame rate"))
        container.addSubview(outputFPSPicker)
        muteButton.title = NativeScreenshotUserText.string("静音", "Mute")
        muteButton.setButtonType(.toggle)
        addButton(muteButton, symbol: "speaker.slash", x: 20,
                  action: #selector(toggleMute), in: container)
        addButton(mp4Button, symbol: "square.and.arrow.up", x: 187,
                  action: #selector(exportMP4), in: container)
        addButton(gifButton, symbol: "photo.stack", x: 313,
                  action: #selector(exportGIF), in: container)
        addButton(NSButton(title: NativeScreenshotUserText.string("复制原片", "Copy original"),
                           target: nil, action: nil), symbol: "doc.on.doc", x: 439,
                  action: #selector(copyVideo), in: container)
        addButton(NSButton(title: NativeScreenshotUserText.string("在访达显示", "Show in Finder"),
                           target: nil, action: nil), symbol: "folder", x: 565,
                  action: #selector(revealVideo), in: container)
        gifPreviewButton.bezelStyle = .rounded
        gifPreviewButton.frame = CGRect(x: 690, y: 58, width: 90, height: 32)
        gifPreviewButton.autoresizingMask = [.minXMargin, .maxYMargin]
        gifPreviewButton.target = self
        gifPreviewButton.action = #selector(previewGIF)
        gifPreviewButton.isEnabled = false
        container.addSubview(gifPreviewButton)

        progress.frame = CGRect(x: 20, y: 23, width: 490, height: 12)
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(progress)
        cancelButton.frame = CGRect(x: 530, y: 18, width: 120, height: 28)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelExport)
        cancelButton.isHidden = true
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(cancelButton)
        statusLabel.frame = CGRect(x: 20, y: 1, width: 760, height: 18)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(statusLabel)
        window.contentView = container

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.duration > 0, !self.closed else { return }
                self.timeline.playhead = min(self.duration, max(0, time.seconds))
                self.updateTimedPicturePreview(at: time.seconds)
                if let player = self.playerView.player,
                   player.rate != 0, !self.skippingCut,
                   let cut = self.effectSegments.first(where: {
                    if case .cut = $0.content { return $0.contains(time.seconds) }
                    return false
                }) {
                    self.skippingCut = true
                    player.seek(to: CMTime(seconds: min(self.endSlider.doubleValue, cut.end),
                                           preferredTimescale: 60_000),
                                toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.skippingCut = false
                            if finished && !self.closed { self.playerView.player?.play() }
                        }
                    }
                    return
                }
                if let player = self.playerView.player, player.rate != 0 {
                    let segmentRate = self.effectSegments.compactMap { segment -> Double? in
                        guard segment.contains(time.seconds),
                              case .speed(let speed) = segment.content else { return nil }
                        return speed
                    }.first ?? 1
                    let preferredRate = Float([0.5, 1, 1.5, 2][
                        self.previewSpeedPicker.indexOfSelectedItem] * segmentRate)
                    if abs(player.rate - preferredRate) > 0.01 {
                        player.rate = preferredRate
                    }
                }
                if time.seconds >= self.endSlider.doubleValue - 0.02 {
                    self.playerView.player?.pause()
                }
            }
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let length = try await AVURLAsset(url: videoURL).load(.duration).seconds
                guard !Task.isCancelled, !self.closed, length.isFinite, length > 0 else { return }
                self.duration = length
                self.startSlider.maxValue = length
                self.endSlider.maxValue = length
                self.endSlider.doubleValue = length
                self.timeline.duration = length
                self.timeline.end = length
                if let track = try? await AVURLAsset(url: videoURL)
                    .loadTracks(withMediaType: .video).first,
                   let natural = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let transformed = natural.applying(transform)
                    self.effectCanvas.videoAspect = abs(transformed.width)
                        / max(1, abs(transformed.height))
                    if let rate = try? await track.load(.nominalFrameRate),
                       rate.isFinite, rate > 0 {
                        self.sourceFrameRate = Double(rate)
                    }
                }
                self.updateLabels()
                self.mp4Button.isEnabled = true
                self.gifButton.isEnabled = true
                self.gifPreviewButton.isEnabled = true
                self.freezeButton.isEnabled = true
                self.generateTimelineThumbnails(duration: length)
                self.schedulePreviewCompositionUpdate()
            } catch {
                self.statusLabel.stringValue = NativeScreenshotUserText.string(
                    "无法读取视频时长：", "Unable to read movie duration: ") + error.localizedDescription
            }
        }
    }

    private func show() {
        NativeScreenshotWindowActivation.opened(id)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        playerView.player?.play()
    }

    private func configureSlider(_ slider: NSSlider, action: Selector, y: CGFloat, in view: NSView) {
        slider.frame = CGRect(x: 76, y: y, width: 573, height: 24)
        slider.autoresizingMask = [.width, .maxYMargin]
        slider.minValue = 0
        slider.maxValue = 1
        slider.isEnabled = false
        slider.target = self
        slider.action = action
        view.addSubview(slider)
    }

    private func addLabel(_ title: String, x: CGFloat, y: CGFloat, in view: NSView) {
        let label = NSTextField(labelWithString: title)
        label.frame = CGRect(x: x, y: y, width: 52, height: 20)
        label.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(label)
    }

    private func addButton(_ button: NSButton, symbol: String, x: CGFloat,
                           action: Selector, in view: NSView) {
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.frame = CGRect(x: x, y: 58, width: 118, height: 32)
        button.autoresizingMask = [.maxXMargin, .maxYMargin]
        button.target = self
        button.action = action
        if button === mp4Button || button === gifButton { button.isEnabled = false }
        view.addSubview(button)
    }

    @objc private func startChanged() {
        startSlider.doubleValue = max(0, min(startSlider.doubleValue, endSlider.doubleValue - 0.1))
        updateLabels()
        seek(to: startSlider.doubleValue)
        schedulePreviewCompositionUpdate()
    }

    @objc private func endChanged() {
        endSlider.doubleValue = min(duration, max(endSlider.doubleValue, startSlider.doubleValue + 0.1))
        updateLabels()
        seek(to: max(startSlider.doubleValue, endSlider.doubleValue - 0.2))
        schedulePreviewCompositionUpdate()
    }

    private func updateLabels() {
        startLabel.stringValue = Self.timeText(startSlider.doubleValue)
        endLabel.stringValue = Self.timeText(endSlider.doubleValue)
        timeline.start = startSlider.doubleValue
        timeline.end = endSlider.doubleValue
        if let freezeAt,
           (freezeAt < startSlider.doubleValue || freezeAt >= endSlider.doubleValue - 0.04) {
            self.freezeAt = nil
            freezeButton.state = .off
        }
        startSlider.isEnabled = true
        endSlider.isEnabled = true
    }

    private static func timeText(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func seek(to second: TimeInterval) {
        playerView.player?.pause()
        playerView.player?.seek(to: CMTime(seconds: second, preferredTimescale: 60_000),
                                toleranceBefore: .zero, toleranceAfter: .zero)
        timeline.playhead = second
        updateTimedPicturePreview(at: second)
    }

    private func updateTimedPicturePreview(at sourceSecond: TimeInterval) {
        let isCut = effectSegments.contains { segment in
            guard segment.contains(sourceSecond) else { return false }
            if case .cut = segment.content { return true }
            return false
        }
        effectCanvas.isCutPreviewActive = isCut
    }

    @objc private func zoomPreviewChanged() {
        schedulePreviewCompositionUpdate()
    }

    private func schedulePreviewCompositionUpdate() {
        previewCompositionUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in
            self?.updatePreviewComposition()
        }
        previewCompositionUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: update)
    }

    private func updatePreviewComposition() {
        guard !closed, let player = playerView.player,
              let item = player.currentItem, duration > 0,
              let selection = try? NativeScreenshotVideoSelection(
                start: startSlider.doubleValue, end: endSlider.doubleValue,
                duration: duration) else { return }
        var effects = selectedEffects(gif: false)
        effects.outputScale = 1
        effects.frameRateRequested = false
        effects.framesPerSecond = 30
        let hasPicture = effects.zoom > 1 || effects.redaction != nil
            || !effects.text.isEmpty || effects.segments.contains {
                switch $0.content {
                case .zoom, .redaction, .text, .styledRedaction, .styledText:
                    return true
                default: return false
                }
            }
        guard hasPicture else {
            item.videoComposition = nil
            return
        }
        let asset = AVURLAsset(url: videoURL)
        item.videoComposition = NativeScreenshotVideoSegmentExporter.previewComposition(
            asset: asset, effects: effects,
            sourceFrameRate: Float(sourceFrameRate), selection: selection)
        if player.rate == 0 {
            player.seek(to: player.currentTime(), toleranceBefore: .zero,
                        toleranceAfter: .zero)
        }
    }

    @objc private func previewSpeedChanged() {
        guard let player = playerView.player else { return }
        let selectedRate: Float = [0.5, 1, 1.5, 2][previewSpeedPicker.indexOfSelectedItem]
        let wasPlaying = player.rate != 0
        player.defaultRate = selectedRate
        if wasPlaying { player.rate = selectedRate }
    }

    @objc private func toggleMute() {
        playerView.player?.isMuted = muteButton.state == .on
    }

    private func handlePlaybackKey(_ code: UInt16) {
        guard let player = playerView.player, duration > 0 else { return }
        switch code {
        case 49:
            if player.rate != 0 { player.pause() }
            else {
                if player.currentTime().seconds >= endSlider.doubleValue - 0.02 {
                    player.seek(to: CMTime(seconds: startSlider.doubleValue,
                                           preferredTimescale: 60_000))
                }
                player.play()
            }
        case 123, 124:
            let increment = (code == 123 ? -1.0 : 1.0) / sourceFrameRate
            let current = player.currentTime().seconds
            seek(to: min(endSlider.doubleValue,
                         max(startSlider.doubleValue, current + increment)))
        default: break
        }
    }

    private func generateTimelineThumbnails(duration: TimeInterval) {
        thumbnailTask?.cancel()
        let url = videoURL
        thumbnailTask = Task.detached(priority: .utility) { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 128, height: 72)
            generator.requestedTimeToleranceBefore = .zero
            let count = 12
            var images: [NSImage] = []
            for index in 0..<count {
                guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
                let second = duration * (Double(index) + 0.5) / Double(count)
                guard let frame = try? generator.copyCGImage(
                    at: CMTime(seconds: second, preferredTimescale: 60_000),
                    actualTime: nil) else { continue }
                images.append(NSImage(cgImage: frame, size: NSSize(width: frame.width,
                                                                   height: frame.height)))
            }
            await MainActor.run {
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.timeline.thumbnails = images
            }
        }
    }

    @objc private func toggleFreeze() {
        guard duration > 0 else { freezeButton.state = .off; return }
        if freezeButton.state == .on {
            freezeAt = min(max(timeline.playhead, startSlider.doubleValue),
                           endSlider.doubleValue - 0.05)
            statusLabel.stringValue = NativeScreenshotUserText.string(
                "已在当前帧添加定格", "Freeze frame added at the playhead")
        } else {
            freezeAt = nil
            statusLabel.stringValue = ""
        }
    }

    @objc private func toggleRedaction() {
        textPlaceButton.state = .off
        effectCanvas.mode = redactButton.state == .on ? .redaction : .none
        if redactButton.state == .on {
            statusLabel.stringValue = NativeScreenshotUserText.string(
                "在视频画面上拖动，选择整段遮挡范围。",
                "Drag across the video to cover an area throughout the clip.")
        }
    }

    @objc private func toggleTextPlacement() {
        redactButton.state = .off
        effectCanvas.text = textField.stringValue
        effectCanvas.mode = textPlaceButton.state == .on ? .text : .none
        if textPlaceButton.state == .on {
            statusLabel.stringValue = NativeScreenshotUserText.string(
                "点击视频画面放置文字。", "Click the video to place the text.")
        }
    }

    @objc private func textChanged() {
        effectCanvas.text = textField.stringValue
        schedulePreviewCompositionUpdate()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === textField else { return }
        textChanged()
    }

    @objc private func editRedactionStyle() {
        let selectedIndex = segmentPicker.indexOfSelectedItem
        var initial = redactionStyle
        if effectSegments.indices.contains(selectedIndex) {
            switch effectSegments[selectedIndex].content {
            case .styledRedaction(_, let style): initial = style
            case .redaction: initial = .init()
            default: break
            }
        }
        let alert = NSAlert()
        alert.messageText = NativeScreenshotUserText.string(
            "遮挡样式", "Redaction style")
        alert.informativeText = NativeScreenshotUserText.string(
            "应用于选中的遮挡段；否则用于整段与新效果段。渐入渐出期间原画面会短暂可见。",
            "Applies to the selected redaction segment, or to the full clip and new segments. Fades briefly reveal the original picture.")
        alert.addButton(withTitle: NativeScreenshotUserText.string("应用", "Apply"))
        alert.addButton(withTitle: NativeScreenshotUserText.string("取消", "Cancel"))
        let form = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 154))
        let kind = NSPopUpButton(frame: CGRect(x: 150, y: 121, width: 195, height: 27))
        kind.addItems(withTitles: [
            NativeScreenshotUserText.string("纯色", "Solid"),
            NativeScreenshotUserText.string("马赛克", "Pixelate"),
            NativeScreenshotUserText.string("模糊", "Blur")])
        kind.selectItem(at: NativeScreenshotVideoRedactionStyle.Kind.allCases.firstIndex(
            of: initial.kind) ?? 0)
        let color = NSColorWell(frame: CGRect(x: 150, y: 86, width: 78, height: 27))
        color.color = Self.appKitColor(initial.color)
        let fadeIn = NSTextField(string: String(format: "%.2f", initial.fadeIn))
        fadeIn.frame = CGRect(x: 150, y: 53, width: 95, height: 24)
        let fadeOut = NSTextField(string: String(format: "%.2f", initial.fadeOut))
        fadeOut.frame = CGRect(x: 150, y: 19, width: 95, height: 24)
        for (title, y) in [
            (NativeScreenshotUserText.string("类型", "Type"), CGFloat(125)),
            (NativeScreenshotUserText.string("纯色颜色", "Solid color"), CGFloat(90)),
            (NativeScreenshotUserText.string("渐入秒数", "Fade in (s)"), CGFloat(56)),
            (NativeScreenshotUserText.string("渐出秒数", "Fade out (s)"), CGFloat(22))
        ] {
            let label = NSTextField(labelWithString: title)
            label.frame = CGRect(x: 0, y: y, width: 140, height: 20)
            form.addSubview(label)
        }
        [kind, color, fadeIn, fadeOut].forEach(form.addSubview)
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let start = Double(fadeIn.stringValue),
                  let end = Double(fadeOut.stringValue) else {
                self.showSegmentError(); return
            }
            var opaqueColor = Self.videoColor(color.color)
            opaqueColor.alpha = 1
            let style = NativeScreenshotVideoRedactionStyle(
                kind: NativeScreenshotVideoRedactionStyle.Kind.allCases[
                    max(0, min(kind.indexOfSelectedItem, 2))],
                color: opaqueColor,
                fadeIn: start, fadeOut: end)
            guard style.isValid else { self.showSegmentError(); return }
            self.redactionStyle = style
            if self.effectSegments.indices.contains(selectedIndex) {
                switch self.effectSegments[selectedIndex].content {
                case .redaction(let rect), .styledRedaction(let rect, _):
                    self.effectSegments[selectedIndex].content =
                        .styledRedaction(rect, style)
                    self.refreshEffectSegments()
                    self.segmentPicker.selectItem(at: selectedIndex)
                    return
                default: break
                }
            }
            self.schedulePreviewCompositionUpdate()
        }
    }

    @objc private func editTextStyle() {
        let selectedIndex = segmentPicker.indexOfSelectedItem
        var initial = textStyle
        var initialText = textField.stringValue
        if effectSegments.indices.contains(selectedIndex) {
            switch effectSegments[selectedIndex].content {
            case .styledText(let value, _, let style):
                initialText = value
                initial = style
            case .text(let value, _):
                initialText = value
                initial = .init()
            default: break
            }
        }
        let alert = NSAlert()
        alert.messageText = NativeScreenshotUserText.string("文字样式", "Text style")
        alert.informativeText = NativeScreenshotUserText.string(
            "字号按 1080p 高度换算；选中文字效果段时可同时修改其内容。",
            "Font size is relative to 1080p. A selected text segment can be edited here.")
        alert.addButton(withTitle: NativeScreenshotUserText.string("应用", "Apply"))
        alert.addButton(withTitle: NativeScreenshotUserText.string("取消", "Cancel"))
        let form = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 344))
        let value = NSTextField(string: initialText)
        value.frame = CGRect(x: 172, y: 309, width: 230, height: 24)
        let size = NSTextField(string: String(format: "%.0f", initial.fontSize))
        size.frame = CGRect(x: 172, y: 275, width: 90, height: 24)
        let bold = NSButton(checkboxWithTitle: NativeScreenshotUserText.string(
            "粗体", "Bold"), target: nil, action: nil)
        bold.frame = CGRect(x: 172, y: 242, width: 90, height: 24)
        bold.state = initial.bold ? .on : .off
        let italic = NSButton(checkboxWithTitle: NativeScreenshotUserText.string(
            "斜体", "Italic"), target: nil, action: nil)
        italic.frame = CGRect(x: 266, y: 242, width: 90, height: 24)
        italic.state = initial.italic ? .on : .off
        let foreground = NSColorWell(frame: CGRect(x: 172, y: 207, width: 78, height: 27))
        foreground.color = Self.appKitColor(initial.textColor)
        let background = NSPopUpButton(frame: CGRect(x: 172, y: 174, width: 230, height: 27))
        background.addItems(withTitles: [
            NativeScreenshotUserText.string("无", "None"),
            NativeScreenshotUserText.string("矩形", "Rectangle"),
            NativeScreenshotUserText.string("圆角", "Rounded")])
        background.selectItem(at: NativeScreenshotVideoTextStyle.Background.allCases.firstIndex(
            of: initial.background) ?? 2)
        let backgroundColor = NSColorWell(frame: CGRect(x: 172, y: 139, width: 78, height: 27))
        backgroundColor.color = Self.appKitColor(initial.backgroundColor)
        let alignment = NSPopUpButton(frame: CGRect(x: 172, y: 106, width: 230, height: 27))
        alignment.addItems(withTitles: [
            NativeScreenshotUserText.string("左对齐", "Left"),
            NativeScreenshotUserText.string("居中", "Center"),
            NativeScreenshotUserText.string("右对齐", "Right")])
        alignment.selectItem(at: NativeScreenshotVideoTextStyle.Alignment.allCases.firstIndex(
            of: initial.alignment) ?? 1)
        let width = NSTextField(string: String(format: "%.0f", initial.boxWidth * 100))
        width.frame = CGRect(x: 172, y: 75, width: 90, height: 24)
        let fadeIn = NSTextField(string: String(format: "%.2f", initial.fadeIn))
        fadeIn.frame = CGRect(x: 172, y: 43, width: 90, height: 24)
        let fadeOut = NSTextField(string: String(format: "%.2f", initial.fadeOut))
        fadeOut.frame = CGRect(x: 172, y: 11, width: 90, height: 24)
        for (title, y) in [
            (NativeScreenshotUserText.string("文字", "Text"), CGFloat(312)),
            (NativeScreenshotUserText.string("字号", "Font size"), CGFloat(278)),
            (NativeScreenshotUserText.string("字形", "Font traits"), CGFloat(245)),
            (NativeScreenshotUserText.string("文字颜色", "Text color"), CGFloat(210)),
            (NativeScreenshotUserText.string("背景形状", "Background shape"), CGFloat(177)),
            (NativeScreenshotUserText.string("背景颜色", "Background color"), CGFloat(142)),
            (NativeScreenshotUserText.string("对齐", "Alignment"), CGFloat(109)),
            (NativeScreenshotUserText.string("文字框宽度 %", "Box width %"), CGFloat(78)),
            (NativeScreenshotUserText.string("渐入秒数", "Fade in (s)"), CGFloat(46)),
            (NativeScreenshotUserText.string("渐出秒数", "Fade out (s)"), CGFloat(14))
        ] {
            let label = NSTextField(labelWithString: title)
            label.frame = CGRect(x: 0, y: y, width: 162, height: 20)
            form.addSubview(label)
        }
        [value, size, bold, italic, foreground, background, backgroundColor,
         alignment, width, fadeIn, fadeOut].forEach(form.addSubview)
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let fontSize = Double(size.stringValue),
                  let boxPercent = Double(width.stringValue),
                  let entrance = Double(fadeIn.stringValue),
                  let exit = Double(fadeOut.stringValue),
                  value.stringValue.count <= 120 else {
                self.showSegmentError(); return
            }
            let style = NativeScreenshotVideoTextStyle(
                fontSize: CGFloat(fontSize), bold: bold.state == .on,
                italic: italic.state == .on,
                textColor: Self.videoColor(foreground.color),
                background: NativeScreenshotVideoTextStyle.Background.allCases[
                    max(0, min(background.indexOfSelectedItem, 2))],
                backgroundColor: Self.videoColor(backgroundColor.color),
                alignment: NativeScreenshotVideoTextStyle.Alignment.allCases[
                    max(0, min(alignment.indexOfSelectedItem, 2))],
                boxWidth: CGFloat(boxPercent / 100),
                fadeIn: entrance, fadeOut: exit)
            guard style.isValid else { self.showSegmentError(); return }
            self.textStyle = style
            if self.effectSegments.indices.contains(selectedIndex) {
                switch self.effectSegments[selectedIndex].content {
                case .text(_, let position), .styledText(_, let position, _):
                    guard !value.stringValue.isEmpty else { self.showSegmentError(); return }
                    self.effectSegments[selectedIndex].content =
                        .styledText(value.stringValue, position, style)
                    self.refreshEffectSegments()
                    self.segmentPicker.selectItem(at: selectedIndex)
                    return
                default: break
                }
            }
            self.textField.stringValue = value.stringValue
            self.effectCanvas.text = value.stringValue
            self.schedulePreviewCompositionUpdate()
        }
    }

    private static func appKitColor(_ color: NativeScreenshotVideoColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green,
                blue: color.blue, alpha: color.alpha)
    }

    private static func videoColor(_ color: NSColor) -> NativeScreenshotVideoColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return .white
        }
        return NativeScreenshotVideoColor(
            red: rgb.redComponent, green: rgb.greenComponent,
            blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    @objc private func addEffectSegment() {
        guard duration > 0, effectSegments.count < 64 else { return }
        let alert = NSAlert()
        alert.messageText = NativeScreenshotUserText.string("添加效果段", "Add effect segment")
        alert.informativeText = NativeScreenshotUserText.string(
            "拖动时间轴底部的彩色端点可调整效果范围；缩放、遮挡和文字读取上方当前设置。",
            "Drag a colored segment edge on the timeline to change its range. Picture effects use the settings above.")
        alert.addButton(withTitle: NativeScreenshotUserText.string("添加", "Add"))
        alert.addButton(withTitle: NativeScreenshotUserText.string("取消", "Cancel"))
        let form = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 145))
        let kind = NSPopUpButton(frame: CGRect(x: 105, y: 108, width: 220, height: 28))
        kind.addItems(withTitles: [
            NativeScreenshotUserText.string("剪切片段", "Cut interval"),
            NativeScreenshotUserText.string("片段变速", "Segment speed"),
            NativeScreenshotUserText.string("缩放", "Zoom"),
            NativeScreenshotUserText.string("遮挡", "Redaction"),
            NativeScreenshotUserText.string("文字", "Text")])
        let startValue = min(max(0, timeline.playhead), max(0, duration - 0.1))
        let startField = NSTextField(string: String(format: "%.2f", startValue))
        startField.frame = CGRect(x: 105, y: 75, width: 220, height: 24)
        let endField = NSTextField(string: String(format: "%.2f",
            min(duration, startValue + 2)))
        endField.frame = CGRect(x: 105, y: 43, width: 220, height: 24)
        let speedPicker = NSPopUpButton(frame: CGRect(x: 105, y: 10, width: 220, height: 28))
        speedPicker.addItems(withTitles: ["0.25×", "0.5×", "1.5×", "2×", "4×"])
        speedPicker.selectItem(at: 2)
        for (title, y) in [
            (NativeScreenshotUserText.string("效果", "Effect"), CGFloat(112)),
            (NativeScreenshotUserText.string("开始秒数", "Start second"), CGFloat(78)),
            (NativeScreenshotUserText.string("结束秒数", "End second"), CGFloat(46)),
            (NativeScreenshotUserText.string("变速倍率", "Speed factor"), CGFloat(13))
        ] {
            let label = NSTextField(labelWithString: title)
            label.frame = CGRect(x: 0, y: y, width: 100, height: 22)
            form.addSubview(label)
        }
        form.addSubview(kind)
        form.addSubview(startField)
        form.addSubview(endField)
        form.addSubview(speedPicker)
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let start = Double(startField.stringValue),
                  let end = Double(endField.stringValue),
                  start.isFinite, end.isFinite, start >= 0,
                  end <= self.duration, end - start >= 0.1 else {
                self.showSegmentError()
                return
            }
            let content: NativeScreenshotVideoEffectSegment.Content
            switch kind.indexOfSelectedItem {
            case 0:
                guard self.freezeAt.map({ $0 < start || $0 >= end }) ?? true else {
                    self.showSegmentError(); return
                }
                content = .cut
            case 1:
                guard !self.effectSegments.contains(where: { segment in
                    if case .speed = segment.content {
                        return max(start, segment.start) < min(end, segment.end)
                    }
                    return false
                }) else { self.showSegmentError(); return }
                content = .speed([0.25, 0.5, 1.5, 2, 4][speedPicker.indexOfSelectedItem])
            case 2:
                let zoom = [1, 1.25, 1.5, 2][self.zoomPicker.indexOfSelectedItem]
                guard zoom > 1 else { self.showSegmentError(); return }
                content = .zoom(CGFloat(zoom))
                self.zoomPicker.selectItem(at: 0)
            case 3:
                guard let region = self.effectCanvas.redaction else {
                    self.showSegmentError(); return
                }
                content = .styledRedaction(region, self.redactionStyle)
                self.effectCanvas.redaction = nil
            default:
                let value = self.textField.stringValue
                guard !value.isEmpty, value.count <= 120 else {
                    self.showSegmentError(); return
                }
                content = .styledText(value, self.effectCanvas.textPosition,
                                      self.textStyle)
                self.textField.stringValue = ""
                self.effectCanvas.text = ""
            }
            self.effectSegments.append(.init(start: start, end: end, content: content))
            self.effectCanvas.mode = .none
            self.redactButton.state = .off
            self.textPlaceButton.state = .off
            self.refreshEffectSegments()
            self.segmentPicker.selectItem(at: self.effectSegments.count - 1)
        }
    }

    private func showSegmentError() {
        NSAlert(error: NativeScreenshotVideoExportError.invalidEffects)
            .beginSheetModal(for: window)
    }

    private func refreshEffectSegments() {
        timeline.segments = effectSegments
        updateTimedPicturePreview(at: timeline.playhead)
        schedulePreviewCompositionUpdate()
        segmentPicker.removeAllItems()
        guard !effectSegments.isEmpty else {
            segmentPicker.addItem(withTitle: NativeScreenshotUserText.string(
                "无效果段", "No effect segments"))
            return
        }
        for (index, segment) in effectSegments.enumerated() {
            let kind: String
            switch segment.content {
            case .cut: kind = NativeScreenshotUserText.string("剪切", "Cut")
            case .speed(let factor): kind = String(format: "%.2g×", factor)
            case .zoom: kind = NativeScreenshotUserText.string("缩放", "Zoom")
            case .redaction:
                kind = NativeScreenshotUserText.string("纯色遮挡", "Solid redaction")
            case .styledRedaction(_, let style):
                switch style.kind {
                case .solid: kind = NativeScreenshotUserText.string("纯色遮挡", "Solid redaction")
                case .pixelate: kind = NativeScreenshotUserText.string("马赛克", "Pixelate")
                case .blur: kind = NativeScreenshotUserText.string("模糊", "Blur")
                }
            case .text:
                kind = NativeScreenshotUserText.string("文字", "Text")
            case .styledText(_, _, let style):
                kind = NativeScreenshotUserText.string(
                    "文字 · \(Int(style.fontSize)) 点",
                    "Text · \(Int(style.fontSize)) pt")
            }
            segmentPicker.addItem(withTitle: "\(index + 1) · \(kind) "
                + Self.timeText(segment.start) + "–" + Self.timeText(segment.end))
        }
    }

    @objc private func selectEffectSegment() {
        guard effectSegments.indices.contains(segmentPicker.indexOfSelectedItem) else { return }
        seek(to: effectSegments[segmentPicker.indexOfSelectedItem].start)
    }

    @objc private func removeEffectSegment() {
        guard effectSegments.indices.contains(segmentPicker.indexOfSelectedItem) else { return }
        effectSegments.remove(at: segmentPicker.indexOfSelectedItem)
        refreshEffectSegments()
    }

    @objc private func copyVideo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([videoURL as NSURL])
    }

    @objc private func revealVideo() {
        NSWorkspace.shared.activateFileViewerSelecting([videoURL])
    }

    @objc private func exportMP4() { requestExport(gif: false) }
    @objc private func exportGIF() { requestExport(gif: true) }
    @objc private func previewGIF() { requestExport(gif: true, previewOnly: true) }

    private func requestExport(gif: Bool, previewOnly: Bool = false) {
        guard exportWorker == nil else { return }
        let selection: NativeScreenshotVideoSelection
        let effects: NativeScreenshotVideoEffects
        do {
            selection = try NativeScreenshotVideoSelection(
                start: startSlider.doubleValue, end: endSlider.doubleValue, duration: duration)
            effects = try selectedEffects(gif: gif).validated(for: selection)
            if gif {
                let outputDuration = try NativeScreenshotVideoSegmentExporter.expectedOutputDuration(
                    selection: selection, effects: effects)
                if outputDuration > 120 { throw NativeScreenshotVideoExportError.gifTooLong }
            }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }
        if previewOnly {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ClipyClone-GIF-Preview-\(UUID().uuidString).gif")
            startExport(to: destination, selection: selection, effects: effects,
                        gif: true, previewOnly: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent
            + (gif ? "-clip.gif" : "-clip.mp4")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.startExport(to: destination, selection: selection,
                              effects: effects, gif: gif)
        }
    }

    private func selectedEffects(gif: Bool) -> NativeScreenshotVideoEffects {
        effectCanvas.text = textField.stringValue
        return NativeScreenshotVideoEffects(
            speed: [0.5, 1, 1.5, 2][previewSpeedPicker.indexOfSelectedItem],
            muteAudio: gif ? freezeAt != nil : muteButton.state == .on,
            freezeAt: freezeAt,
            freezeDuration: [0.5, 1, 2][freezeDurationPicker.indexOfSelectedItem],
            zoom: [1, 1.25, 1.5, 2][zoomPicker.indexOfSelectedItem],
            redaction: effectCanvas.redaction,
            redactionStyle: redactionStyle,
            text: textField.stringValue,
            textPosition: effectCanvas.textPosition,
            textStyle: textStyle,
            outputScale: gif ? 1 : [0.25, 0.33, 0.5, 0.75, 1][outputScalePicker.indexOfSelectedItem],
            framesPerSecond: gif || outputFPSPicker.indexOfSelectedItem == 0
                ? 30 : [15, 30, 60][outputFPSPicker.indexOfSelectedItem - 1],
            frameRateRequested: !gif && outputFPSPicker.indexOfSelectedItem > 0,
            segments: effectSegments)
    }

    private func startExport(to destination: URL,
                             selection: NativeScreenshotVideoSelection,
                             effects: NativeScreenshotVideoEffects, gif: Bool,
                             previewOnly: Bool = false) {
        guard !closed, exportWorker == nil else { return }
        let source = videoURL
        let quality: NativeScreenshotVideoSegmentExporter.MP4Quality
        switch qualityPicker.indexOfSelectedItem {
        case 0 where effects.canPassthrough: quality = .lossless
        case 1: quality = .standard
        default: quality = .high
        }
        if !effects.canPassthrough && qualityPicker.indexOfSelectedItem == 0 {
            qualityPicker.selectItem(at: 2)
            statusLabel.stringValue = NativeScreenshotUserText.string(
                "编辑效果需重新编码，已改用高质量 MP4。",
                "Edits require encoding. Switched to high-quality MP4.")
        }
        let gifFPS = 5 + gifFPSPicker.indexOfSelectedItem
        let gifDimension = [480, 720, 960][gifSizePicker.indexOfSelectedItem]
        mp4Button.isEnabled = false
        gifButton.isEnabled = false
        gifPreviewButton.isEnabled = false
        progress.doubleValue = 0
        progress.isHidden = false
        cancelButton.isHidden = false
        statusLabel.stringValue = NativeScreenshotUserText.string("正在导出…", "Exporting…")
        let report: (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.progress.doubleValue = value
                self.statusLabel.stringValue = NativeScreenshotUserText.string("正在导出", "Exporting")
                    + String(format: " %.0f%%", value * 100)
            }
        }
        let worker = Task.detached(priority: .userInitiated) { () throws -> URL in
            if gif {
                try await NativeScreenshotVideoSegmentExporter.exportEditedGIF(
                    sourceURL: source, destinationURL: destination,
                    selection: selection, effects: effects, framesPerSecond: gifFPS,
                    maximumDimension: gifDimension, progress: report)
            } else {
                try await NativeScreenshotVideoSegmentExporter.exportMP4(
                    sourceURL: source, destinationURL: destination,
                    selection: selection, quality: quality,
                    effects: effects, progress: report)
            }
            return destination
        }
        exportWorker = worker
        completionTask = Task { [weak self] in
            let result = await worker.result
            guard let self, !self.closed else { return }
            self.exportWorker = nil
            self.completionTask = nil
            self.progress.isHidden = true
            self.cancelButton.isHidden = true
            self.mp4Button.isEnabled = true
            self.gifButton.isEnabled = true
            self.gifPreviewButton.isEnabled = true
            switch result {
            case .success(let url):
                if previewOnly {
                    self.statusLabel.stringValue = NativeScreenshotUserText.string(
                        "GIF 预览已生成", "GIF preview is ready")
                    self.showGIFPreview(at: url)
                } else {
                    self.statusLabel.stringValue = NativeScreenshotUserText.string("导出完成", "Export complete")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .failure(let error) where error is CancellationError:
                if previewOnly { try? FileManager.default.removeItem(at: destination) }
                self.statusLabel.stringValue = NativeScreenshotUserText.string("已取消导出", "Export cancelled")
            case .failure(let error):
                if previewOnly { try? FileManager.default.removeItem(at: destination) }
                self.statusLabel.stringValue = error.localizedDescription
                NSAlert(error: error).beginSheetModal(for: self.window, completionHandler: nil)
            }
        }
    }

    @objc private func cancelExport() { exportWorker?.cancel() }

    private func showGIFPreview(at url: URL) {
        closeGIFPreview()
        guard let image = NSImage(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            NSAlert(error: NativeScreenshotVideoExportError.unsupportedFormat)
                .beginSheetModal(for: window)
            return
        }
        let preview = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 420),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        preview.title = NativeScreenshotUserText.string("GIF 导出预览", "GIF export preview")
        preview.minSize = NSSize(width: 360, height: 240)
        preview.isReleasedWhenClosed = false
        preview.delegate = self
        let imageView = NSImageView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.image = image
        preview.contentView = imageView
        preview.center()
        gifPreviewWindow = preview
        gifPreviewURL = url
        preview.makeKeyAndOrderFront(nil)
    }

    private func closeGIFPreview() {
        let preview = gifPreviewWindow
        gifPreviewWindow = nil
        preview?.delegate = nil
        preview?.contentView = nil
        preview?.close()
        if let url = gifPreviewURL { try? FileManager.default.removeItem(at: url) }
        gifPreviewURL = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow,
           closingWindow === gifPreviewWindow {
            closeGIFPreview()
            return
        }
        closed = true
        loadTask?.cancel()
        thumbnailTask?.cancel()
        previewCompositionUpdate?.cancel()
        window.onPlaybackKey = nil
        exportWorker?.cancel()
        completionTask?.cancel()
        closeGIFPreview()
        if let player = playerView.player {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
        playerView.player = nil
        Self.windows.removeValue(forKey: id)
        NativeScreenshotWindowActivation.closed(id)
    }
}
