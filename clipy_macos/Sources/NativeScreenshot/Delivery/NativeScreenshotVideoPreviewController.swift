import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

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
final class NativeScreenshotVideoPreviewController: NSObject, NSWindowDelegate {
    private static var windows: [UUID: NativeScreenshotVideoPreviewController] = [:]
    private let id = UUID()
    private let videoURL: URL
    private let window: NSWindow
    private let playerView: AVPlayerView
    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let startLabel = NSTextField(labelWithString: "00:00:00")
    private let endLabel = NSTextField(labelWithString: "00:00:00")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let qualityPicker = NSPopUpButton()
    private let mp4Button: NSButton
    private let gifButton: NSButton
    private let cancelButton: NSButton
    private var duration: TimeInterval = 0
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var exportWorker: Task<URL, Error>?
    private var completionTask: Task<Void, Never>?
    private var closed = false

    static func open(_ videoURL: URL) {
        let controller = NativeScreenshotVideoPreviewController(videoURL: videoURL)
        windows[controller.id] = controller
        controller.show()
    }

    private init(videoURL: URL) {
        self.videoURL = videoURL
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        playerView = AVPlayerView(frame: CGRect(x: 20, y: 180, width: 760, height: 450))
        mp4Button = NSButton(title: NativeScreenshotUserText.string("导出 MP4", "Export MP4"),
                             target: nil, action: nil)
        gifButton = NSButton(title: NativeScreenshotUserText.string("导出 GIF", "Export GIF"),
                             target: nil, action: nil)
        cancelButton = NSButton(title: NativeScreenshotUserText.string("取消导出", "Cancel export"),
                                target: nil, action: nil)
        super.init()
        window.title = videoURL.lastPathComponent
        window.minSize = NSSize(width: 680, height: 480)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .floating
        let player = AVPlayer(url: videoURL)
        playerView.player = player
        container.addSubview(playerView)

        configureSlider(startSlider, action: #selector(startChanged), y: 141, in: container)
        configureSlider(endSlider, action: #selector(endChanged), y: 105, in: container)
        addLabel(NativeScreenshotUserText.string("起点", "Start"), x: 20, y: 144, in: container)
        addLabel(NativeScreenshotUserText.string("终点", "End"), x: 20, y: 108, in: container)
        for (label, y) in [(startLabel, CGFloat(144)), (endLabel, CGFloat(108))] {
            label.frame = CGRect(x: 660, y: y, width: 115, height: 20)
            label.alignment = .right
            label.autoresizingMask = [.minXMargin, .maxYMargin]
            container.addSubview(label)
        }
        qualityPicker.addItems(withTitles: [
            NativeScreenshotUserText.string("无损 MP4", "Lossless MP4"),
            NativeScreenshotUserText.string("标准 MP4", "Standard MP4")
        ])
        qualityPicker.toolTip = NativeScreenshotUserText.string(
            "无损模式不重新编码，剪切点可能对齐关键帧；标准模式重新编码以精确裁剪。",
            "Lossless mode avoids re-encoding and cuts may align to keyframes; standard mode re-encodes for precise cuts.")
        qualityPicker.frame = CGRect(x: 20, y: 61, width: 158, height: 30)
        qualityPicker.autoresizingMask = [.maxXMargin, .maxYMargin]
        container.addSubview(qualityPicker)
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
                self.updateLabels()
                self.mp4Button.isEnabled = true
                self.gifButton.isEnabled = true
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
    }

    @objc private func endChanged() {
        endSlider.doubleValue = min(duration, max(endSlider.doubleValue, startSlider.doubleValue + 0.1))
        updateLabels()
        seek(to: max(startSlider.doubleValue, endSlider.doubleValue - 0.2))
    }

    private func updateLabels() {
        startLabel.stringValue = Self.timeText(startSlider.doubleValue)
        endLabel.stringValue = Self.timeText(endSlider.doubleValue)
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

    private func requestExport(gif: Bool) {
        guard exportWorker == nil else { return }
        let selection: NativeScreenshotVideoSelection
        do {
            selection = try NativeScreenshotVideoSelection(
                start: startSlider.doubleValue, end: endSlider.doubleValue, duration: duration)
            if gif && selection.duration > 120 { throw NativeScreenshotVideoExportError.gifTooLong }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent
            + (gif ? "-clip.gif" : "-clip.mp4")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.startExport(to: destination, selection: selection, gif: gif)
        }
    }

    private func startExport(to destination: URL, selection: NativeScreenshotVideoSelection, gif: Bool) {
        guard !closed, exportWorker == nil else { return }
        let source = videoURL
        let quality: NativeScreenshotVideoSegmentExporter.MP4Quality =
            qualityPicker.indexOfSelectedItem == 0 ? .lossless : .standard
        mp4Button.isEnabled = false
        gifButton.isEnabled = false
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
                try NativeScreenshotVideoSegmentExporter.exportGIF(
                    sourceURL: source, destinationURL: destination,
                    selection: selection, progress: report)
            } else {
                try await NativeScreenshotVideoSegmentExporter.exportMP4(
                    sourceURL: source, destinationURL: destination,
                    selection: selection, quality: quality, progress: report)
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
            switch result {
            case .success(let url):
                self.statusLabel.stringValue = NativeScreenshotUserText.string("导出完成", "Export complete")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error) where error is CancellationError:
                self.statusLabel.stringValue = NativeScreenshotUserText.string("已取消导出", "Export cancelled")
            case .failure(let error):
                self.statusLabel.stringValue = error.localizedDescription
                NSAlert(error: error).beginSheetModal(for: self.window, completionHandler: nil)
            }
        }
    }

    @objc private func cancelExport() { exportWorker?.cancel() }

    func windowWillClose(_ notification: Notification) {
        closed = true
        loadTask?.cancel()
        exportWorker?.cancel()
        completionTask?.cancel()
        if let player = playerView.player {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
        playerView.player = nil
        Self.windows.removeValue(forKey: id)
        NativeScreenshotWindowActivation.closed(id)
    }
}
