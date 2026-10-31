import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Standalone video editor window for trimming and exporting recorded videos.
final class VideoEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var editorView: VideoEditorView?
    private static var activeControllers: [VideoEditorWindowController] = []

    /// Open a video in the editor.
    /// - Parameters:
    ///   - url: File URL to the video.
    ///   - deleteOnClose: If true (default) the editor deletes the file when
    ///     the window closes — appropriate for temporary recordings. Pass
    ///     `false` when opening a user-owned file so we don't delete their
    ///     source.
    static func open(url: URL, deleteOnClose: Bool = true) {
        let controller = VideoEditorWindowController()
        controller.show(url: url, deleteOnClose: deleteOnClose)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func show(url: URL, deleteOnClose: Bool = true) {
        guard let screen = NSScreen.main else { return }

        // Size window to fit content, capped at 60% of screen
        let controlsH: CGFloat = 52 + 50 + 40 + 150
        let maxW = screen.frame.width * 0.6
        let maxH = screen.frame.height * 0.6
        var contentW: CGFloat = 800
        var contentH: CGFloat = 450

        // Get content dimensions — MP4 uses AVAsset track info
        if url.pathExtension.lowercased() != "gif" {
            let asset = AVAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let backingScale = screen.backingScaleFactor
                contentW = abs(size.width) / backingScale
                contentH = abs(size.height) / backingScale
            }
        }
        // GIF: keep defaults — AVFoundation can't read GIF dimensions reliably

        // Scale down to fit screen, maintaining aspect ratio
        let scale = min(1.0, min(maxW / contentW, (maxH - controlsH) / contentH))
        let winW = max(980, contentW * scale + 272)
        let winH = max(560, contentH * scale + controlsH)
        let winX = screen.frame.midX - winW / 2
        let winY = screen.frame.midY - winH / 2

        let win = EscapeClosingWindow(
            contentRect: NSRect(x: winX, y: winY, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // V3 (mac-video.html): unified 52pt header row drawn by VideoEditorView —
        // an empty unified toolbar centres the traffic lights in it.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.toolbar = NSToolbar(identifier: "ClipyVideoEditorTitlebar")
        win.toolbarStyle = .unified
        // Prefix with the source filename so multiple editor windows are
        // distinguishable in the Dock menu and Window menu.
        win.title = "\(url.deletingPathExtension().lastPathComponent) — \(L("macshot Video Editor"))"
        win.minSize = NSSize(width: 980, height: 600)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]

        let view = VideoEditorView(frame: NSRect(x: 0, y: 0, width: winW, height: winH),
                                    videoURL: url,
                                    deleteOnClose: deleteOnClose)
        win.contentView = view

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.editorView = view
    }

    func windowWillClose(_ notification: Notification) {
        editorView?.cleanup()
        editorView = nil
        let closingWindow = window
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            screenshotAppIntegration()?.returnFocusIfNeeded()
        }
    }
}

// MARK: - VideoEditorView

private final class VideoEditorView: NSView {

    private let videoURL: URL
    /// If true, the underlying file is deleted on close (recording tmp path).
    /// Set to false when opening a user-owned source file via "Open Video...".
    private let deleteOnClose: Bool
    private let isGIF: Bool
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    private var effectsOverlay: EffectsPreviewOverlayView?
    private var gifImageView: NSImageView?
    private var asset: AVAsset?
    private var duration: Double = 0

    // Timeline state
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    private var timelineRect: NSRect = .zero
    private var isDraggingStart: Bool = false
    private var isDraggingEnd: Bool = false
    private var isDraggingScrubber: Bool = false
    private var timeObserver: Any?
    private var gifPlaybackTimer: Timer?
    private var gifPlaybackTime: Double = 0
    private var gifIsPlaying: Bool = false

    // Timeline thumbnails
    private var thumbnailImages: [NSImage] = []
    private var thumbnailsGenerating: Bool = false
    private var lastThumbnailWidth: CGFloat = 0

    /// Pre-composited timeline thumbnail strip. Built once when thumbnails
    /// or the timeline width changes; reused on every draw so playback
    /// doesn't loop through N individual NSImage.draw(in:) calls 30 times
    /// per second. Nil → strip needs rebuilding (or no thumbnails yet).
    private var thumbnailStrip: NSImage?
    private var thumbnailStripWidth: CGFloat = 0

    /// Last drawn playhead x-position in view coords. Used by
    /// `invalidatePlayheadArea` to invalidate only the stripe spanning
    /// old→new so AppKit can clip the expensive thumbnail-strip redraw.
    private var lastDrawnPlayheadX: CGFloat?

    // Format toggle (MP4 vs GIF export)
    private var exportAsGIF: Bool = false
    private var formatToggleRect: NSRect = .zero
    private var formatMP4Rect: NSRect = .zero
    private var formatGIFRect: NSRect = .zero

    // Export dimensions
    private var originalWidth: Int = 0
    private var originalHeight: Int = 0
    private var exportScale: CGFloat = 1.0  // 1.0 = original, 0.5 = 50%, etc.
    private var dimensionsBtnRect: NSRect = .zero

    // Export quality (controls bitrate when re-encoding for MP4 export)
    private var exportQuality: VideoQuality = .high
    private var qualityBtnRect: NSRect = .zero

    // GIF export frame rate (5-30 fps), persisted across sessions
    private var gifExportFPS: Int = {
        let stored = UserDefaults.standard.integer(forKey: "gifExportFPS")
        return stored == 0 ? 15 : min(30, max(5, stored))
    }()
    private var gifFPSBtnRect: NSRect = .zero

    // Effects band (zoom + censor segments) lives in its own NSView, hosted
    // inside an NSScrollView so it can overflow vertically when many segments
    // stack onto separate rows. The parent editor observes mutations via the
    // band's delegate and rebuilds the video composition / preview overlay.
    private var effectsBand: EffectsBandView?
    private var effectsScrollView: NSScrollView?
    private var effectsBandHeightConstraint: NSLayoutConstraint?
    private var playerBottomConstraint: NSLayoutConstraint?
    private let inspectorWidth: CGFloat = 272
    private let effectToolbarHeight: CGFloat = 40
    private let transportHeight: CGFloat = 50
    /// V3 header row (title, subtitle, copy / Finder / save).
    private let headerHeight: CGFloat = 52
    /// Track-label gutter ("画面" / "效果") and right inset of the timeline.
    private let timelineLeft: CGFloat = 108
    private let timelineRight: CGFloat = 16
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    private let copyHeaderButton = EditorFooterButton()
    private let copyMenuButton = EditorFooterButton()
    private let finderHeaderButton = EditorFooterButton()
    #if !OFFLINE
    private let uploadHeaderButton = EditorFooterButton()
    #endif
    private let saveHeaderButton = EditorFooterButton()
    private var playButton: VideoTransportPlayButton?
    private var muteButton: NSButton?
    private var statusPillRect: NSRect = .zero
    private weak var zoomValueLabel: NSTextField?
    private var inspector: NSScrollView?
    private var inspectorStack: NSStackView?
    private var effectToolbar: NSStackView?
    private var transport: NSStackView?
    private var transportTime: NSTextField?

    // Convenience accessors so call sites don't have to guard the optional.
    private var zoomSegments: [VideoZoomSegment] { effectsBand?.zoomSegments ?? [] }
    private var censorSegments: [VideoCensorSegment] { effectsBand?.censorSegments ?? [] }
    private var cutSegments: [VideoCutSegment] { effectsBand?.cutSegments ?? [] }
    private var textSegments: [VideoTextSegment] { effectsBand?.textSegments ?? [] }
    private var selectedSegmentID: UUID? { effectsBand?.selectedSegmentID }

    // Cached rasterized text overlays. Keyed by segment id; the value carries
    // the spec used to produce the cached CGImage so we can invalidate when
    // any visible property changes. Lives on the editor (main actor) and is
    // snapshotted into the compositor instruction at composition-build time.
    private var textRasterCache: [UUID: (spec: VideoTextRasterizer.Spec, image: CGImage)] = [:]

    // Inline text-editor state for "Edit Text…". Lives on the editor view so
    // we can place a borderless NSTextView over the player at the same rect
    // the EffectsPreviewOverlayView is showing.
    private var inlineTextEditor: NSTextView?
    private var inlineTextEditorScrollView: NSScrollView?
    private var inlineTextEditingSegmentID: UUID?
    private var pausedForTextEdit: Bool = false

    // NSColorPanel binding state for the "Custom…" color menu action.
    fileprivate var textColorPickerSegmentID: UUID?
    fileprivate var textColorPickerIsBackground: Bool = false

    // Button rects
    private var playBtnRect: NSRect = .zero
    private var saveBtnRect: NSRect = .zero
    private var saveArrowRect: NSRect = .zero
    private var uploadBtnRect: NSRect = .zero
    private var copyBtnRect: NSRect = .zero
    private var copyArrowRect: NSRect = .zero
    private var muteBtnRect: NSRect = .zero
    private var finderBtnRect: NSRect = .zero
    private var isMuted: Bool = false
    private var savedURL: URL?
    private var statusMessage: String?
    private var statusIsError: Bool = false
    private var statusTimer: Timer?

    // Layout
    private let timelinePad: CGFloat = 20
    /// Row height inside the effects band, kept in sync with EffectsBandView.
    /// Also serves as a layout primitive for the scroll view's visible height.
    private let effectsRowStride: CGFloat = 22 + 2
    /// Number of rows visible without scrolling inside the effects scroll view.
    /// Beyond this the scroll view scrolls vertically.
    private let effectsVisibleRowCount: Int = 4

    // Vertical layout of the controls band (bottom-up):
    //   [buttons 12→40]          fixed 48pt
    //   [effects scroll view]    variable (rowCount × rowStride - 2, capped)
    //   [gap 8pt]                8
    //   [trim timeline]          36
    //   [time labels]            18
    //   [top pad]                12
    //
    // Time labels sit ABOVE the trim bar so they don't collide with the
    // effects band's "Click to add effects" hint that sits directly
    // above the bottom buttons row.
    private let buttonsAreaH: CGFloat = 12
    private let labelsRowH: CGFloat = 26
    private let trimBarH: CGFloat = 44
    private let topPadH: CGFloat = 0
    /// Gap between the effects scroll view (top) and the trim bar (bottom).
    /// Sized to fit the playhead circle which sits below the trim bar in
    /// this layout (circle is 8pt diameter with 2pt breathing room).
    private let scrollToLabelsGap: CGFloat = 12

    /// Total height of the controls band at the bottom of the editor,
    /// dynamic because the effects scroll view grows with row count.
    private var controlsH: CGFloat {
        return buttonsAreaH
             + effectsScrollViewHeight(forRowCount: currentEffectRowCount)
             + scrollToLabelsGap
             + trimBarH
             + labelsAboveTrimGap
             + labelsRowH
             + topPadH
    }

    /// Live row count; the delegate callback updates it and triggers layout.
    private var currentEffectRowCount: Int = 1

    init(frame: NSRect, videoURL: URL, deleteOnClose: Bool = true) {
        self.videoURL = videoURL
        self.deleteOnClose = deleteOnClose
        self.isGIF = videoURL.pathExtension.lowercased() == "gif"
        super.init(frame: frame)

        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)

        setupPlayer()
        buildInspector()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupPlayer() {
        if isGIF {
            setupGIFView()
            return
        }

        let asset = AVAsset(url: videoURL)
        self.asset = asset

        // AVAsset for a freshly-finalized recording can return an empty
        // `tracks` array from the synchronous accessor before the moov atom
        // has been parsed. Build everything (dimensions, duration, player,
        // effects-composition trackID) only after `.tracks` is loaded —
        // otherwise the live-preview compositor caches a stale trackID and
        // `sourceFrame(byTrackID:)` returns nil → effects silently no-op.
        Task {
            let videoTrack: AVAssetTrack? = await {
                if let tracks = try? await asset.load(.tracks) {
                    return tracks.first(where: { $0.mediaType == .video })
                }
                return asset.tracks(withMediaType: .video).first
            }()

            let seconds: Double
            if let videoTrack = videoTrack {
                seconds = CMTimeGetSeconds(videoTrack.timeRange.duration)
            } else if let dur = try? await asset.load(.duration) {
                seconds = CMTimeGetSeconds(dur)
            } else {
                seconds = 0
            }

            let pixelSize: CGSize? = videoTrack.map {
                $0.naturalSize.applying($0.preferredTransform)
            }

            await MainActor.run {
                if let size = pixelSize {
                    self.originalWidth = Int(abs(size.width))
                    self.originalHeight = Int(abs(size.height))
                }
                self.duration = max(seconds, 0.1)
                self.trimEnd = self.duration
                self.buildPlayerView()
                self.effectsBand?.duration = self.duration
                self.transportTime?.attributedStringValue = self.transportTimeString()
                self.refreshInspector()
            }
        }
    }

    private func setupGIFView() {
        guard let gifImage = NSImage(contentsOf: videoURL) else { return }
        // Estimate duration from GIF frame count and delay
        if let src = CGImageSourceCreateWithURL(videoURL as CFURL, nil) {
            let count = CGImageSourceGetCount(src)
            var totalDelay: Double = 0
            for i in 0..<count {
                if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any],
                   let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                   let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
                    totalDelay += delay
                }
            }
            duration = max(totalDelay, 0.1)
        } else {
            duration = 1.0
        }
        trimEnd = duration

        // Store original GIF dimensions
        if let src = CGImageSourceCreateWithURL(videoURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            originalWidth = img.width
            originalHeight = img.height
        }

        let iv = NSImageView()
        iv.image = gifImage
        iv.animates = true
        iv.imageScaling = .scaleProportionallyDown
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)

        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: topAnchor, constant: headerHeight + 14),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inspectorWidth + 16)),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(controlsH + effectToolbarHeight + transportHeight + 6)),
        ])
        gifImageView = iv
        gifIsPlaying = true
        gifPlaybackTime = trimStart
        gifPlaybackTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.gifIsPlaying else { return }
            self.gifPlaybackTime += 1.0/30.0
            if self.gifPlaybackTime >= self.trimEnd {
                self.gifPlaybackTime = self.trimStart
            }
            self.invalidatePlayheadArea()
        }
        needsDisplay = true
    }

    private func buildPlayerView() {
        // Use the same AVAsset instance the rest of the editor uses so that
        // track IDs our composition references line up with what AVPlayer is
        // decoding.
        let playerAsset = asset ?? AVAsset(url: videoURL)
        let item = AVPlayerItem(asset: playerAsset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = .none
        pv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pv)

        let playerBottomC = pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(controlsH + effectToolbarHeight + transportHeight + 6))
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: topAnchor, constant: headerHeight + 14),
            pv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inspectorWidth + 16)),
            playerBottomC,
        ])
        playerView = pv
        self.playerBottomConstraint = playerBottomC

        // Overlay for interactive effect editing — sits on top of the player
        // view and pins to the same edges so it tracks window resizes.
        let overlay = EffectsPreviewOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Video natural size (orientation-applied). Needed so the overlay can
        // compute the letterboxed video rect inside its bounds.
        if let track = playerAsset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            overlay.videoSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        overlay.onChange = { [weak self] newRect in
            self?.overlayRectChanged(newRect)
        }
        overlay.onTextEditRequested = { [weak self] viewRect in
            guard let self = self,
                  let id = self.selectedSegmentID,
                  self.textSegments.contains(where: { $0.id == id }) else { return }
            self.beginInlineTextEdit(segmentID: id, atViewRect: viewRect, hostView: overlay)
        }
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: pv.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: pv.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pv.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: pv.bottomAnchor),
        ])
        effectsOverlay = overlay

        // Effects band — inside a scroll view so many stacked rows don't push
        // the timeline off-screen. Height grows up to
        // `effectsVisibleRowCount` rows, beyond which the scroll view
        // scrolls.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        let band = EffectsBandView()
        band.translatesAutoresizingMaskIntoConstraints = false
        band.delegate = self
        scrollView.documentView = band
        addSubview(scrollView)

        let scrollHeight = effectsScrollViewHeight(forRowCount: 1)
        let heightC = scrollView.heightAnchor.constraint(equalToConstant: scrollHeight)
        heightC.priority = .required
        NSLayoutConstraint.activate([
            // Inset 4pt less than the trim timeline so effect-pill handles
            // that poke past the pill edge (at startTime=0 or
            // endTime=duration) still have room to render fully. The
            // band itself re-inserts a matching 4pt horizontalInset so
            // pills visually align with the thumbnails above.
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: timelineLeft - 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(timelineRight - 4)),
            // Scroll view sits directly above the buttons row (y=48 from parent bottom).
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsAreaH),
            heightC,
            // Document view (band) width matches the scroll view's visible
            // width; height is driven by intrinsicContentSize.
            band.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        self.effectsScrollView = scrollView
        self.effectsBand = band
        self.effectsBandHeightConstraint = heightC

        // Observe playback position
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self = self, !self.isDraggingScrubber else { return }
            // The player's clock may be the cut-stripped composition clock;
            // map it back to the source asset clock before comparing with
            // trim markers (which are in source time).
            let t = self.mapPreviewClockToSourceTime(CMTimeGetSeconds(time))
            if t >= self.trimEnd {
                self.player?.pause()
                let target = self.mapSourceTimeToPreviewClock(self.trimStart)
                self.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Narrow invalidation — just the playhead stripe. The rest of
            // the controls band is static during playback and AppKit's
            // dirty-rect clipping skips their fills. This drops per-frame
            // draw cost from ~30ms (60 thumbnail redraws) to <1ms.
            self.invalidatePlayheadArea()
        }

        generateThumbnails()
        needsDisplay = true
    }

    // MARK: - V3 palette (mac.css tokens; preview stage stays dark)

    fileprivate static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    fileprivate static let surface = dynamic(.white, NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1))
    fileprivate static let toolSurface = dynamic(NSColor(white: 0.985, alpha: 1), NSColor(srgbRed: 0.137, green: 0.137, blue: 0.153, alpha: 1))
    fileprivate static let line = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09))
    fileprivate static let fill = dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06))
    fileprivate static let stage = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1)

    // The inspector only edits the existing segment models; the timeline and
    // export pipeline remain their single owners.
    private func buildInspector() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let stack = VideoInspectorStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        scroll.documentView = stack
        addSubview(scroll)
        inspector = scroll
        inspectorStack = stack

        // Timeline toolbar: 添加 · 缩放 遮挡 文字 变速 定格 剪切 (mac-video.html .ttb).
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 2
        let addLabel = NSTextField(labelWithString: videoLabel("Add", "添加"))
        addLabel.font = .systemFont(ofSize: 11.5)
        addLabel.textColor = .tertiaryLabelColor
        toolbar.addArrangedSubview(addLabel)
        toolbar.setCustomSpacing(6, after: addLabel)
        for (index, item) in [("Add Zoom", "plus.magnifyingglass", L("Zoom")), ("Add Censor", "eye.slash", L("Censor")),
                              ("Add Text", "textformat", L("Text")), ("Add Speed", "forward", videoLabel("Speed", "变速")),
                              ("Add Freeze", "snowflake", videoLabel("Freeze", "定格")), ("Add Cut", "scissors", videoLabel("Cut", "剪切"))].enumerated() {
            let button = VideoToolbarButton(title: item.2, target: self, action: #selector(addEffectFromToolbar(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.0)
            button.toolTip = L(item.0)
            button.tag = index
            button.image = NSImage(systemSymbolName: item.1, accessibilityDescription: L(item.0))?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.imagePosition = .imageLeading
            button.isEnabled = !isGIF
            toolbar.addArrangedSubview(button)
        }
        addSubview(toolbar)
        effectToolbar = toolbar

        // Transport under the preview (mac-video.html .transport).
        let playback = NSStackView()
        playback.orientation = .horizontal
        playback.alignment = .centerY
        playback.spacing = 10
        func transportButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: "", target: self, action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.isBordered = false
            button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return button
        }
        let back = transportButton("backward.frame", videoLabel("Previous frame (←)", "上一帧（←）"), #selector(inspectorPreviousFrame))
        back.isEnabled = !isGIF
        let play = VideoTransportPlayButton(target: self, action: #selector(inspectorPlayPause))
        play.isPlaying = { [weak self] in
            guard let self else { return false }
            return self.isGIF ? self.gifIsPlaying : (self.player?.rate ?? 0) > 0
        }
        play.toolTip = videoLabel("Play / Pause (Space)", "播放 / 暂停（空格）")
        playButton = play
        let forward = transportButton("forward.frame", videoLabel("Next frame (→)", "下一帧（→）"), #selector(inspectorNextFrame))
        forward.isEnabled = !isGIF
        let time = NSTextField(labelWithString: "00:00.0 / 00:00.0")
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        time.textColor = .white
        transportTime = time
        let mute = transportButton("speaker.wave.2", L("Mute"), #selector(transportMute))
        mute.isEnabled = !isGIF
        muteButton = mute
        for view in [back, play, forward, time, mute] { playback.addArrangedSubview(view) }
        playback.setCustomSpacing(18, after: forward)
        playback.setCustomSpacing(18, after: time)
        addSubview(playback)
        transport = playback

        // Header: title / subtitle · [复制 | ⌄] · Finder · 保存.
        headerTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerSubtitle.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        headerSubtitle.textColor = .secondaryLabelColor
        addSubview(headerTitle)
        addSubview(headerSubtitle)
        copyHeaderButton.configure(title: L("Copy"), symbol: "doc.on.doc")
        copyHeaderButton.target = self
        copyHeaderButton.action = #selector(headerCopy)
        copyMenuButton.configure(title: "", symbol: "chevron.down")
        copyMenuButton.imagePosition = .imageOnly
        copyMenuButton.toolTip = L("Copy Path")
        copyMenuButton.target = self
        copyMenuButton.action = #selector(headerCopyMenu)
        finderHeaderButton.configure(title: "", symbol: "folder")
        finderHeaderButton.imagePosition = .imageOnly
        finderHeaderButton.toolTip = videoLabel("Show in Finder (available after saving)", "在 Finder 中显示（保存后可用）")
        finderHeaderButton.target = self
        finderHeaderButton.action = #selector(headerFinder)
        saveHeaderButton.configure(title: L("Save"), symbol: "arrow.down.to.line", primary: true)
        saveHeaderButton.target = self
        saveHeaderButton.action = #selector(headerSave)
        saveHeaderButton.onRightClick = { [weak self] _ in self?.saveVideoAs() }
        saveHeaderButton.toolTip = videoLabel("Save (right-click: Save As…)", "保存（右键：另存为…）")
        var headerButtons: [NSButton] = [copyHeaderButton, copyMenuButton, finderHeaderButton, saveHeaderButton]
        #if !OFFLINE
        uploadHeaderButton.configure(title: L("Upload"), symbol: "icloud.and.arrow.up")
        uploadHeaderButton.target = self
        uploadHeaderButton.action = #selector(headerUpload)
        headerButtons.append(uploadHeaderButton)
        #endif
        headerButtons.forEach { addSubview($0) }
        refreshInspector()
    }

    @objc private func transportMute() { toggleMute() }
    @objc private func headerCopy() { copyToClipboard() }
    @objc private func headerCopyMenu() {
        let menu = NSMenu()
        let pathItem = NSMenuItem(title: L("Copy Path"), action: #selector(copyPathAction), keyEquivalent: "")
        pathItem.target = self
        menu.addItem(pathItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: copyMenuButton.bounds.height + 4), in: copyMenuButton)
    }
    @objc private func headerFinder() { if let url = savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func headerSave() { saveVideo() }
    #if !OFFLINE
    @objc private func headerUpload() { uploadVideo() }
    #endif

    private func formatClock(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60, s = Int(total) % 60, d = Int((total - floor(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, d)
    }

    /// Output duration after trim, cuts, speed and freeze edits.
    private var outputDuration: Double {
        if cutSegments.isEmpty && speedSegments.isEmpty && freezeSegments.isEmpty { return trimEnd - trimStart }
        let kept = VideoCuts.keptRanges(trimStart: trimStart, trimEnd: trimEnd, cuts: cutSegments)
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: speedSegments, freezes: freezeSegments)
        return VideoSpeeds.totalCompositionDuration(pieces)
    }

    /// Header title/subtitle: "W × H · fps · total → output" (mac-video.html .tt .sub).
    private func refreshHeaderInfo() {
        headerTitle.stringValue = window?.title ?? ""
        var parts: [String] = []
        if originalWidth > 0 { parts.append("\(originalWidth) × \(originalHeight)") }
        if let fps = asset?.tracks(withMediaType: .video).first?.nominalFrameRate, fps > 0 { parts.append("\(Int(fps.rounded()))fps") }
        if duration > 0 { parts.append("\(formatClock(duration)) → \(formatClock(outputDuration))") }
        headerSubtitle.stringValue = parts.joined(separator: " · ")
        finderHeaderButton.isEnabled = savedURL != nil
        finderHeaderButton.alphaValue = savedURL != nil ? 1 : 0.45
        playButton?.needsDisplay = true
        muteButton?.image = NSImage(systemSymbolName: isMuted ? "speaker.slash" : "speaker.wave.2", accessibilityDescription: L("Mute"))?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHeaderInfo()
    }

    override func layout() {
        super.layout()
        let panelTop = controlsH + effectToolbarHeight
        let headerY = bounds.height - headerHeight
        inspector?.frame = NSRect(x: bounds.width - inspectorWidth + 0.5, y: panelTop,
                                  width: inspectorWidth - 0.5, height: max(0, headerY - panelTop))
        if let stack = inspectorStack {
            stack.frame = NSRect(x: 0, y: 0, width: inspectorWidth,
                                 height: max(inspector?.contentSize.height ?? 0, stack.fittingSize.height))
        }
        if let toolbar = effectToolbar {
            let size = toolbar.fittingSize
            toolbar.frame = NSRect(x: 10, y: controlsH + (effectToolbarHeight - size.height) / 2,
                                   width: size.width, height: size.height)
        }
        if let transport {
            let size = transport.fittingSize
            let mainW = bounds.width - inspectorWidth
            transport.frame = NSRect(x: (mainW - size.width) / 2, y: panelTop + (transportHeight - size.height) / 2,
                                     width: size.width, height: size.height)
        }
        transportTime?.attributedStringValue = transportTimeString()

        // Header row (traffic lights sit at the left of the same 52pt band).
        var x: CGFloat = 84
        if let zoom = window?.standardWindowButton(.zoomButton) {
            x = max(x, convert(zoom.convert(zoom.bounds, to: nil), from: nil).maxX + 16)
        }
        var right = bounds.width - 14
        func place(_ button: NSButton, gap: CGFloat = 8) {
            guard !button.isHidden else { return }
            right -= button.frame.width
            button.frame = NSRect(x: right, y: headerY + (headerHeight - 28) / 2, width: button.frame.width, height: 28)
            right -= gap
        }
        place(saveHeaderButton)
        #if !OFFLINE
        place(uploadHeaderButton)
        #endif
        finderHeaderButton.frame.size.width = 30
        place(finderHeaderButton)
        copyMenuButton.frame.size.width = 26
        place(copyMenuButton, gap: 0)
        place(copyHeaderButton)
        statusPillRect = .zero
        if let message = statusMessage {
            let width = ceil((message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 20
            statusPillRect = NSRect(x: right - width, y: headerY + (headerHeight - 28) / 2, width: width, height: 28)
            right = statusPillRect.minX - 8
        }
        headerTitle.sizeToFit(); headerSubtitle.sizeToFit()
        let titleW = max(0, min(headerTitle.frame.width, right - x - 8))
        headerTitle.frame = NSRect(x: x, y: headerY + 26, width: titleW, height: headerTitle.frame.height)
        headerSubtitle.frame = NSRect(x: x, y: headerY + 10, width: max(0, min(headerSubtitle.frame.width, right - x - 8)), height: headerSubtitle.frame.height)
    }

    private func transportTimeString() -> NSAttributedString {
        let text = NSMutableAttributedString(string: formatClock(currentPlaybackTime), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        text.append(NSAttributedString(string: "  /  \(formatClock(duration))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.45)]))
        return text
    }

    private func inspectorLabel(_ text: String, heading: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: heading ? 13 : 11.5, weight: heading ? .semibold : .regular)
        label.textColor = heading ? .labelColor : .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = inspectorWidth - 28
        return label
    }

    private func groupLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func videoLabel(_ english: String, _ chinese: String) -> String {
        ScreenshotLocalization.active["Zoom"] == nil ? english : chinese
    }

    private func inspectorPopup(_ titles: [String], selection: Int, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26), pullsDown: false)
        popup.addItems(withTitles: titles)
        if selection >= 0 && selection < titles.count { popup.selectItem(at: selection) }
        popup.target = self
        popup.action = action
        popup.font = .systemFont(ofSize: 12.5)
        return popup
    }

    /// "label · control · value" row (mac-video.html .ir).
    private func inspectorRow(_ title: String, _ control: NSView, value: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 62).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let value {
            let valueLabel = NSTextField(labelWithString: value)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.alignment = .right
            valueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
            row.addArrangedSubview(valueLabel)
        }
        row.widthAnchor.constraint(equalToConstant: inspectorWidth - 28).isActive = true
        return row
    }

    /// Wrapping chip group (mac-video.html .chs).
    private func chipGroup(_ titles: [String], selected: Int, action: Selector) -> NSView {
        let container = VideoChipGroup()
        for (index, title) in titles.enumerated() {
            let chip = VideoChipButton(title: title, target: self, action: action)
            chip.tag = index
            chip.isOn = index == selected
            container.addSubview(chip)
        }
        container.widthAnchor.constraint(equalToConstant: inspectorWidth - 28).isActive = true
        container.layoutChips(width: inspectorWidth - 28)
        container.heightAnchor.constraint(equalToConstant: container.frame.height).isActive = true
        return container
    }

    private func effectHeader(symbol: String, tint: NSColor, title: String, start: Double, end: Double) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let tile = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage())
        tile.contentTintColor = tint
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        tile.widthAnchor.constraint(equalToConstant: 32).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let range = NSTextField(labelWithString: "\(formatClock(start)) – \(formatClock(end))")
        range.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        range.textColor = .tertiaryLabelColor
        text.addArrangedSubview(name)
        text.addArrangedSubview(range)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let delete = NSButton(title: L("Delete"), target: self, action: #selector(inspectorDelete))
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Delete"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        delete.imagePosition = .imageOnly
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = L("Delete")
        delete.widthAnchor.constraint(equalToConstant: 28).isActive = true
        for view in [tile, text, spacer, delete] { row.addArrangedSubview(view) }
        row.widthAnchor.constraint(equalToConstant: inspectorWidth - 28).isActive = true
        return row
    }

    private func separatorView() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: inspectorWidth - 28).isActive = true
        return separator
    }

    private static let fadeValues: [Double] = [0, 0.15, 0.25, 0.35, 0.5, 1]

    private func refreshInspector() {
        guard let stack = inspectorStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let id = selectedSegmentID
        let zoomTint = NSColor.systemBlue, censorTint = NSColor.systemGray, textTint = NSColor.systemOrange
        let speedTint = NSColor.systemTeal, freezeTint = NSColor.systemPurple, cutTint = NSColor.systemRed
        if let id = id, let seg = zoomSegments.first(where: { $0.id == id }) {
            stack.addArrangedSubview(effectHeader(symbol: "plus.magnifyingglass", tint: zoomTint, title: L("Zoom"), start: seg.startTime, end: seg.endTime))
            let slider = NSSlider(value: Double(seg.zoomLevel), minValue: Double(VideoZoomSegment.minZoom), maxValue: Double(VideoZoomSegment.maxZoom), target: self, action: #selector(inspectorZoom(_:)))
            slider.controlSize = .small
            let zoomRow = inspectorRow(L("Zoom"), slider, value: String(format: "%.1f×", seg.zoomLevel))
            zoomValueLabel = (zoomRow as? NSStackView)?.arrangedSubviews.last as? NSTextField
            stack.addArrangedSubview(zoomRow)
            stack.addArrangedSubview(inspectorLabel("ⓘ " + videoLabel("Drag the frame on the preview to move and resize the region; press + / − to change the level while selected.", "在预览上拖动区域框调整位置与范围；选中时按 + / − 调整倍数")))
        } else if let id = id, let seg = censorSegments.first(where: { $0.id == id }) {
            stack.addArrangedSubview(effectHeader(symbol: "eye.slash", tint: censorTint, title: L("Censor"), start: seg.startTime, end: seg.endTime))
            let styles: [VideoCensorSegment.Style] = [.solid, .pixelate, .blur]
            let segmented = NSSegmentedControl(labels: [L("Solid"), L("Pixelate"), L("Blur")], trackingMode: .selectOne, target: self, action: #selector(inspectorCensorSegment(_:)))
            segmented.selectedSegment = styles.firstIndex(of: seg.style) ?? 0
            segmented.selectedSegmentBezelColor = .controlColor
            segmented.widthAnchor.constraint(equalToConstant: inspectorWidth - 28).isActive = true
            stack.addArrangedSubview(segmented)
        } else if let id = id, let seg = speedSegments.first(where: { $0.id == id }) {
            stack.addArrangedSubview(effectHeader(symbol: "forward", tint: speedTint, title: videoLabel("Speed", "变速"), start: seg.startTime, end: seg.endTime))
            stack.addArrangedSubview(groupLabel(videoLabel("Speed", "倍速")))
            stack.addArrangedSubview(chipGroup(VideoSpeedSegment.presetFactors.map { "\($0)×" }, selected: VideoSpeedSegment.presetFactors.firstIndex(of: seg.speedFactor) ?? -1, action: #selector(inspectorSpeedChip(_:))))
        } else if let id = id, let seg = freezeSegments.first(where: { $0.id == id }) {
            stack.addArrangedSubview(effectHeader(symbol: "snowflake", tint: freezeTint, title: videoLabel("Freeze", "定格"), start: seg.atTime, end: seg.atTime + seg.holdDuration))
            stack.addArrangedSubview(groupLabel(videoLabel("Hold", "定格时长")))
            stack.addArrangedSubview(chipGroup(VideoFreezeSegment.presetDurations.map { videoLabel("\($0) s", "\($0) 秒") }, selected: VideoFreezeSegment.presetDurations.firstIndex(of: seg.holdDuration) ?? -1, action: #selector(inspectorFreezeChip(_:))))
        } else if let id = id, let seg = textSegments.first(where: { $0.id == id }) {
            stack.addArrangedSubview(effectHeader(symbol: "textformat", tint: textTint, title: L("Text"), start: seg.startTime, end: seg.endTime))
            let edit = NSButton(title: L("Edit Text…"), target: self, action: #selector(inspectorEditText))
            edit.bezelStyle = .rounded
            edit.controlSize = .small
            stack.addArrangedSubview(edit)
            stack.addArrangedSubview(inspectorRow(L("Size"), inspectorPopup([L("Small"), L("Medium"), L("Large"), L("Huge")], selection: [CGFloat(32), 48, 72, 104].firstIndex(where: { abs($0 - seg.fontSize) < 0.5 }) ?? 1, action: #selector(inspectorTextSize(_:)))))
            let styleRow = NSStackView()
            styleRow.spacing = 12
            let bold = NSButton(checkboxWithTitle: L("Bold"), target: self, action: #selector(inspectorTextBold(_:)))
            bold.state = seg.bold ? .on : .off
            let italic = NSButton(checkboxWithTitle: L("Italic"), target: self, action: #selector(inspectorTextItalic(_:)))
            italic.state = seg.italic ? .on : .off
            styleRow.addArrangedSubview(bold); styleRow.addArrangedSubview(italic)
            stack.addArrangedSubview(inspectorRow(videoLabel("Style", "样式"), styleRow))
            stack.addArrangedSubview(inspectorRow(videoLabel("Align", "对齐"), inspectorPopup([L("Left"), L("Center"), L("Right")], selection: [VideoTextSegment.Alignment.left, .center, .right].firstIndex(of: seg.alignment) ?? 1, action: #selector(inspectorTextAlignment(_:)))))
            stack.addArrangedSubview(inspectorRow(videoLabel("Background", "背景"), inspectorPopup([L("None"), L("Solid"), L("Rounded")], selection: [VideoTextSegment.BackgroundStyle.none, .solid, .rounded].firstIndex(of: seg.bgStyle) ?? 0, action: #selector(inspectorTextBackground(_:)))))
        } else if let id = id, let seg = cutSegments.first(where: { $0.id == id }) {
            stack.addArrangedSubview(effectHeader(symbol: "scissors", tint: cutTint, title: videoLabel("Cut", "剪切"), start: seg.startTime, end: seg.endTime))
            stack.addArrangedSubview(inspectorLabel(videoLabel("This range is removed on export.", "导出时将移除此范围。")))
        } else {
            stack.addArrangedSubview(inspectorLabel(videoLabel("Select an effect", "选择特效"), heading: true))
            stack.addArrangedSubview(inspectorLabel(videoLabel("Select a timeline segment to edit its settings", "选择时间线片段以编辑设置")))
        }
        if let id = id {
            let fade = zoomSegments.first(where: { $0.id == id })?.fadeIn
                ?? censorSegments.first(where: { $0.id == id })?.fadeIn
                ?? textSegments.first(where: { $0.id == id })?.fadeIn
            if let fade = fade {
                stack.addArrangedSubview(groupLabel(videoLabel("Fade in and out", "淡入淡出")))
                let titles = Self.fadeValues.map { $0 == 0 ? L("None") : String(format: "%gs", $0) }
                stack.addArrangedSubview(chipGroup(titles, selected: Self.fadeValues.firstIndex(where: { abs($0 - fade) < 0.001 }) ?? -1, action: #selector(inspectorFadeChip(_:))))
            }
            let more = NSButton(title: videoLabel("More Settings…", "更多设置…"), target: self, action: #selector(inspectorMoreSettings))
            more.bezelStyle = .rounded
            more.controlSize = .small
            stack.addArrangedSubview(more)
        }
        stack.addArrangedSubview(separatorView())
        stack.addArrangedSubview(groupLabel(videoLabel("Export", "导出")))
        if !isGIF {
            let format = NSSegmentedControl(labels: ["MP4", "GIF"], trackingMode: .selectOne, target: self, action: #selector(inspectorFormatSegment(_:)))
            format.selectedSegment = exportAsGIF ? 1 : 0
            format.selectedSegmentBezelColor = .controlColor
            format.setWidth((inspectorWidth - 28) / 2 - 2, forSegment: 0)
            format.setWidth((inspectorWidth - 28) / 2 - 2, forSegment: 1)
            stack.addArrangedSubview(format)
        }
        let scales: [CGFloat] = [1.0, 0.75, 0.5, 0.33, 0.25]
        let sizeTitles = scales.map { scale -> String in
            let w = (Int(CGFloat(originalWidth) * scale) / 2) * 2, h = (Int(CGFloat(originalHeight) * scale) / 2) * 2
            if originalWidth == 0 { return "\(Int(scale * 100))%" }
            return scale >= 0.999 ? "\(originalWidth) × \(originalHeight) (\(videoLabel("Original", "原始")))" : "\(w) × \(h) (\(Int(scale * 100))%)"
        }
        stack.addArrangedSubview(inspectorRow(videoLabel("Size", "尺寸"), inspectorPopup(sizeTitles, selection: scales.firstIndex(where: { abs($0 - exportScale) < 0.01 }) ?? 0, action: #selector(inspectorScale(_:)))))
        if exportAsGIF || isGIF {
            stack.addArrangedSubview(inspectorRow(videoLabel("Frame rate", "帧率"), inspectorPopup((5...30).map { "\($0) fps" }, selection: gifExportFPS - 5, action: #selector(inspectorFPS(_:)))))
        } else {
            stack.addArrangedSubview(inspectorRow(videoLabel("Quality", "质量"), inspectorPopup([L("High"), L("Medium"), L("Low")], selection: exportQuality == .high ? 0 : exportQuality == .medium ? 1 : 2, action: #selector(inspectorQuality(_:)))))
        }
        let estimate = NSTextField(labelWithString: estimatedExportSizeText())
        estimate.font = .systemFont(ofSize: 12.5)
        estimate.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(inspectorRow(videoLabel("Est. size", "预计大小"), estimate))
        refreshHeaderInfo()
        needsLayout = true
    }

    /// Same estimate the former bottom bar showed (trim × scale² × quality, GIF ×3).
    private func estimatedExportSizeText() -> String {
        let sourceFileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        guard sourceFileSize > 0 else { return "—" }
        let fpsValue = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0
        let trimRatio = duration > 0 ? (trimEnd - trimStart) / duration : 1.0
        let scaleRatio = Double(exportScale * exportScale)
        let qualityRatio: Double = exportQuality == .low ? 0.33 : (exportQuality == .medium ? 0.62 : 1.0)
        let estimated: Int64
        if exportAsGIF {
            let gifFPSRatio = min(Float(gifExportFPS), fpsValue) / max(fpsValue, 1)
            estimated = Int64(Double(sourceFileSize) * trimRatio * scaleRatio * 3.0 * Double(gifFPSRatio))
        } else {
            estimated = Int64(Double(sourceFileSize) * trimRatio * scaleRatio * qualityRatio)
        }
        return "≈ " + ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
    }

    @objc private func inspectorCensorSegment(_ sender: NSSegmentedControl) { if let id = selectedSegmentID, let seg = censorSegments.first(where: { $0.id == id }) { seg.style = [VideoCensorSegment.Style.solid, .pixelate, .blur][sender.selectedSegment]; inspectorMutation() } }
    @objc private func inspectorSpeedChip(_ sender: NSButton) { if let id = selectedSegmentID, let seg = speedSegments.first(where: { $0.id == id }) { let factor = VideoSpeedSegment.presetFactors[sender.tag]; seg.endTime = min(duration, max(seg.endTime, seg.startTime + VideoSpeedSegment.minCompDuration * factor)); seg.speedFactor = factor; inspectorMutation(); refreshInspector() } }
    @objc private func inspectorFreezeChip(_ sender: NSButton) { if let id = selectedSegmentID, let seg = freezeSegments.first(where: { $0.id == id }) { seg.holdDuration = VideoFreezeSegment.presetDurations[sender.tag]; inspectorMutation(); refreshInspector() } }
    @objc private func inspectorFadeChip(_ sender: NSButton) { guard let id = selectedSegmentID else { return }; let value = Self.fadeValues[sender.tag]; if let seg = zoomSegments.first(where: { $0.id == id }) { seg.fadeIn = value; seg.fadeOut = value } else if let seg = censorSegments.first(where: { $0.id == id }) { seg.fadeIn = value; seg.fadeOut = value } else if let seg = textSegments.first(where: { $0.id == id }) { seg.fadeIn = value; seg.fadeOut = value }; inspectorMutation(); refreshInspector() }
    @objc private func inspectorFormatSegment(_ sender: NSSegmentedControl) { exportAsGIF = sender.selectedSegment == 1; savedURL = nil; refreshInspector(); needsDisplay = true }

    @objc private func addEffectFromToolbar(_ sender: NSButton) { effectsBand?.addEffect(sender.tag, at: currentPlaybackTime) }
    @objc private func inspectorPreviousFrame() { stepFrame(forward: false) }
    @objc private func inspectorNextFrame() { stepFrame(forward: true) }
    @objc private func inspectorPlayPause() { togglePlayPause() }
    @objc private func inspectorDelete() { if let id = selectedSegmentID { effectsBand?.removeSegment(id: id) } }
    @objc private func inspectorMoreSettings() { if let event = NSApp.currentEvent { effectsBand?.showSelectedSettings(event: event) } }
    @objc private func inspectorEditText() { if let id = selectedSegmentID, let band = effectsBand { effectsBandDidRequestTextEdit(band, segmentID: id) } }
    @objc private func inspectorZoom(_ sender: NSSlider) { if let id = selectedSegmentID, let seg = zoomSegments.first(where: { $0.id == id }) { seg.zoomLevel = CGFloat(sender.doubleValue); zoomValueLabel?.stringValue = String(format: "%.1f×", seg.zoomLevel); inspectorMutation() } }
    @objc private func inspectorCensor(_ sender: NSPopUpButton) { if let id = selectedSegmentID, let seg = censorSegments.first(where: { $0.id == id }) { seg.style = [VideoCensorSegment.Style.solid, .pixelate, .blur][sender.indexOfSelectedItem]; inspectorMutation() } }
    @objc private func inspectorSpeed(_ sender: NSPopUpButton) { if let id = selectedSegmentID, let seg = speedSegments.first(where: { $0.id == id }) { let factor = VideoSpeedSegment.presetFactors[sender.indexOfSelectedItem]; seg.endTime = min(duration, max(seg.endTime, seg.startTime + VideoSpeedSegment.minCompDuration * factor)); seg.speedFactor = factor; inspectorMutation() } }
    @objc private func inspectorFreeze(_ sender: NSPopUpButton) { if let id = selectedSegmentID, let seg = freezeSegments.first(where: { $0.id == id }) { seg.holdDuration = VideoFreezeSegment.presetDurations[sender.indexOfSelectedItem]; inspectorMutation() } }
    @objc private func inspectorTextSize(_ sender: NSPopUpButton) { if let id = selectedSegmentID, let seg = textSegments.first(where: { $0.id == id }) { seg.fontSize = [32, 48, 72, 104][sender.indexOfSelectedItem]; textRasterCache.removeValue(forKey: id); inspectorMutation() } }
    @objc private func inspectorTextBold(_ sender: NSButton) { if let id = selectedSegmentID, let seg = textSegments.first(where: { $0.id == id }) { seg.bold = sender.state == .on; textRasterCache.removeValue(forKey: id); inspectorMutation() } }
    @objc private func inspectorTextItalic(_ sender: NSButton) { if let id = selectedSegmentID, let seg = textSegments.first(where: { $0.id == id }) { seg.italic = sender.state == .on; textRasterCache.removeValue(forKey: id); inspectorMutation() } }
    @objc private func inspectorTextAlignment(_ sender: NSPopUpButton) { if let id = selectedSegmentID, let seg = textSegments.first(where: { $0.id == id }) { seg.alignment = [VideoTextSegment.Alignment.left, .center, .right][sender.indexOfSelectedItem]; textRasterCache.removeValue(forKey: id); inspectorMutation() } }
    @objc private func inspectorTextBackground(_ sender: NSPopUpButton) { if let id = selectedSegmentID, let seg = textSegments.first(where: { $0.id == id }) { seg.bgStyle = [VideoTextSegment.BackgroundStyle.none, .solid, .rounded][sender.indexOfSelectedItem]; textRasterCache.removeValue(forKey: id); inspectorMutation() } }
    @objc private func inspectorFade(_ sender: NSPopUpButton) { guard let id = selectedSegmentID else { return }; let value = [0.0, 0.15, 0.25, 0.35, 0.5, 1.0][sender.indexOfSelectedItem]; if let seg = zoomSegments.first(where: { $0.id == id }) { seg.fadeIn = value; seg.fadeOut = value } else if let seg = censorSegments.first(where: { $0.id == id }) { seg.fadeIn = value; seg.fadeOut = value } else if let seg = textSegments.first(where: { $0.id == id }) { seg.fadeIn = value; seg.fadeOut = value }; inspectorMutation() }
    @objc private func inspectorFormat(_ sender: NSPopUpButton) { exportAsGIF = sender.indexOfSelectedItem == 1; savedURL = nil; refreshInspector(); needsDisplay = true }
    @objc private func inspectorScale(_ sender: NSPopUpButton) { exportScale = [1.0, 0.75, 0.5, 0.33, 0.25][sender.indexOfSelectedItem]; savedURL = nil; refreshInspector(); needsDisplay = true }
    @objc private func inspectorFPS(_ sender: NSPopUpButton) { gifExportFPS = sender.indexOfSelectedItem + 5; UserDefaults.standard.set(gifExportFPS, forKey: "gifExportFPS"); savedURL = nil; needsDisplay = true }
    @objc private func inspectorQuality(_ sender: NSPopUpButton) { exportQuality = [VideoQuality.high, .medium, .low][sender.indexOfSelectedItem]; savedURL = nil; refreshInspector(); needsDisplay = true }
    private func inspectorMutation() { savedURL = nil; effectsBand?.refreshAfterParentEdit(); applyZoomTransformForCurrentTime(); needsDisplay = true }

    private func generateThumbnails() {
        guard let asset = asset, !thumbnailsGenerating else { return }
        let tlW = bounds.width - timelineLeft - timelineRight
        guard tlW > 0 else { return }
        lastThumbnailWidth = tlW
        thumbnailsGenerating = true

        let thumbH: CGFloat = 30
        let thumbW: CGFloat = thumbH * 16 / 9
        let count = max(1, Int(ceil(tlW / thumbW)))
        let dur = duration

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbW * 2, height: thumbH * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var times: [NSValue] = []
        for i in 0..<count {
            let t = dur * Double(i) / Double(count)
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
        }

        var images: [NSImage] = Array(repeating: NSImage(), count: count)
        var idx = 0
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] _, cgImage, _, _, _ in
            if let cg = cgImage {
                let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
                images[idx] = img
            }
            idx += 1
            if idx >= count {
                DispatchQueue.main.async {
                    self?.thumbnailImages = images
                    self?.thumbnailStrip = nil           // force rebuild in drawTimeline
                    self?.thumbnailsGenerating = false
                    self?.needsDisplay = true
                }
            }
        }
    }

    /// Build (or rebuild) the pre-composited thumbnail strip cache. Cheap
    /// to call on every draw — returns immediately if the cache is already
    /// valid for `width`. Called from drawTimeline before the strip is
    /// drawn.
    private func rebuildThumbnailStripIfNeeded(width: CGFloat, height: CGFloat) {
        guard !thumbnailImages.isEmpty, width > 0, height > 0 else { return }
        if thumbnailStrip != nil, abs(thumbnailStripWidth - width) < 0.5 { return }

        let size = NSSize(width: width, height: height)
        let strip = NSImage(size: size)
        strip.lockFocus()
        let count = thumbnailImages.count
        for (i, img) in thumbnailImages.enumerated() {
            let x0 = floor(CGFloat(i) * width / CGFloat(count))
            let x1 = ceil(CGFloat(i + 1) * width / CGFloat(count))
            let r = NSRect(x: x0, y: 0, width: x1 - x0, height: height)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        strip.unlockFocus()
        thumbnailStrip = strip
        thumbnailStripWidth = width
    }

    func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        player?.pause()
        player = nil
        playerView?.player = nil
        gifPlaybackTimer?.invalidate()
        gifPlaybackTimer = nil
        // Delete only if the file was a temporary recording we own. User-
        // opened files must never be deleted — that would be data loss.
        if deleteOnClose {
            try? FileManager.default.removeItem(at: videoURL)
        }
        // Drop the large media-backed fields explicitly. The view tree is
        // released shortly after cleanup() (windowWillClose nils editorView),
        // but naming these releases makes intent obvious and protects against
        // a future "keep editorView alive for re-open" change that would
        // otherwise pin tens of MB (thumbnailStrip alone can be a large image).
        thumbnailImages = []
        thumbnailStrip = nil
        thumbnailStripWidth = 0
        asset = nil
        textRasterCache.removeAll(keepingCapacity: false)
        effectsOverlay = nil
    }

    private var currentPlaybackTime: Double {
        if isGIF {
            return gifPlaybackTime
        } else {
            // Always report in source-asset time so the playhead, thumbnails
            // and trim UI agree regardless of whether the preview is
            // composition-backed (cuts present) or not.
            return mapPreviewClockToSourceTime(CMTimeGetSeconds(player?.currentTime() ?? .zero))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let panelH = controlsH + effectToolbarHeight
        let headerY = bounds.height - headerHeight
        // Header row and timeline panel follow the window theme; the preview
        // column stays dark because the video is document content.
        Self.toolSurface.setFill()
        NSRect(x: 0, y: headerY, width: bounds.width, height: headerHeight).fill()
        Self.stage.setFill()
        NSRect(x: 0, y: panelH, width: bounds.width - inspectorWidth, height: max(0, headerY - panelH)).fill()
        Self.surface.setFill()
        NSRect(x: bounds.width - inspectorWidth, y: panelH, width: inspectorWidth, height: max(0, headerY - panelH)).fill()
        NSRect(x: 0, y: 0, width: bounds.width, height: panelH).fill()
        Self.line.setFill()
        NSRect(x: 0, y: headerY, width: bounds.width, height: 0.5).fill()
        NSRect(x: 0, y: panelH - 0.5, width: bounds.width, height: 0.5).fill()
        NSRect(x: 0, y: controlsH, width: bounds.width, height: 0.5).fill()
        NSRect(x: bounds.width - inspectorWidth, y: panelH, width: 0.5, height: max(0, headerY - panelH)).fill()
        NSRect(x: 96, y: 0, width: 0.5, height: controlsH).fill()
        if let message = statusMessage, statusPillRect.width > 0 { drawStatus(message) }

        guard duration > 0 else { return }

        // Timeline toolbar info: 入点 · 出点 · 共.
        let info = "\(videoLabel("In", "入点")) \(formatClock(trimStart)) · \(videoLabel("Out", "出点")) \(formatClock(trimEnd)) · \(videoLabel("Total", "共")) \(formatClock(duration))" as NSString
        let infoAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let infoSize = info.size(withAttributes: infoAttrs)
        info.draw(at: NSPoint(x: bounds.width - 14 - infoSize.width, y: controlsH + (effectToolbarHeight - infoSize.height) / 2), withAttributes: infoAttrs)

        drawTimeline()
        drawLaneLabels()
        drawTimeLabels()
    }

    /// Track gutter labels (mac-video.html .lanes).
    private func drawLaneLabels() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        func lane(_ symbol: String, _ title: String, centerY: CGFloat) {
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
                let tinted = NSImage(size: icon.size, flipped: false) { r in icon.draw(in: r); NSColor.tertiaryLabelColor.setFill(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: NSRect(x: 12, y: centerY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            }
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: 32, y: centerY - size.height / 2), withAttributes: attrs)
        }
        lane("film", videoLabel("Video", "画面"), centerY: timelineRect.midY)
        let bandTop = buttonsAreaH + effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        lane("sparkles", videoLabel("Effects", "效果"), centerY: bandTop - 15)
    }

    private func drawTimeline() {
        let tlX = timelineLeft
        let tlW = bounds.width - timelineLeft - timelineRight
        // Trim timeline bottom sits above the time-labels row, which sits
        // above the effects scroll view. All three adjust upward as the
        // scroll view grows to show more rows.
        let tlH: CGFloat = trimBarH
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        // Trim bar sits directly above the effects scroll view (with just
        // the `scrollToLabelsGap` for breathing room). Time labels now sit
        // ABOVE the trim bar — see `timeLabelY`.
        let tlY: CGFloat = buttonsAreaH + scrollH + scrollToLabelsGap
        timelineRect = NSRect(x: tlX, y: tlY, width: tlW, height: tlH)

        // Regenerate thumbnails if width changed significantly
        if abs(tlW - lastThumbnailWidth) > 40 && !thumbnailsGenerating && asset != nil {
            generateThumbnails()
        }
        // Invalidate the cached strip if width changed even slightly so the
        // resampled strip stays aligned with the timeline.
        if abs(thumbnailStripWidth - tlW) > 0.5 { thumbnailStrip = nil }
        rebuildThumbnailStripIfNeeded(width: tlW, height: tlH)

        // Track background with rounded clip
        let trackPath = NSBezierPath(roundedRect: timelineRect, xRadius: 6, yRadius: 6)
        NSColor.black.setFill()
        trackPath.fill()

        // Blit the pre-composited thumbnail strip in one draw call. Drawing
        // each thumbnail individually per frame was ~100ms/s during
        // playback; caching brings it to <5ms/s with the same visual.
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        if let strip = thumbnailStrip {
            strip.draw(in: NSRect(x: tlX, y: tlY, width: tlW, height: tlH),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Dim untrimmed regions
        let startX = tlX + CGFloat(trimStart / duration) * tlW
        let endX = tlX + CGFloat(trimEnd / duration) * tlW
        // Outside the trim window: dark hatched veil (mac-video.html .trim .out).
        func veil(_ rect: NSRect) {
            guard rect.width > 0 else { return }
            NSColor.black.withAlphaComponent(0.55).setFill()
            rect.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            NSColor.black.withAlphaComponent(0.14).setStroke()
            let hatch = NSBezierPath()
            hatch.lineWidth = 4
            var hx = rect.minX - rect.height
            while hx < rect.maxX + rect.height {
                hatch.move(to: NSPoint(x: hx, y: rect.maxY)); hatch.line(to: NSPoint(x: hx + rect.height, y: rect.minY))
                hx += 12
            }
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        veil(NSRect(x: tlX, y: tlY, width: max(0, startX - tlX), height: tlH))
        veil(NSRect(x: endX, y: tlY, width: max(0, tlX + tlW - endX), height: tlH))

        // Subtle teal tint for speed ranges — just enough to signal them on
        // the trim bar. The full pill lives on the effects band below.
        for speed in speedSegments where speed.endTime > speed.startTime {
            let sx0 = tlX + CGFloat(max(0, min(duration, speed.startTime)) / duration) * tlW
            let sx1 = tlX + CGFloat(max(0, min(duration, speed.endTime)) / duration) * tlW
            let rect = NSRect(x: sx0, y: tlY, width: max(1, sx1 - sx0), height: tlH)
            NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.50, alpha: 0.28).setFill()
            rect.fill()
        }

        // Draw striped cut overlays inside the trim region — they signal
        // ranges that will be removed on export. Clipped by the track path so
        // overlays never leak past the rounded edges.
        for cut in cutSegments where cut.endTime > cut.startTime {
            let cx0 = tlX + CGFloat(max(0, min(duration, cut.startTime)) / duration) * tlW
            let cx1 = tlX + CGFloat(max(0, min(duration, cut.endTime)) / duration) * tlW
            let cutRect = NSRect(x: cx0, y: tlY, width: max(1, cx1 - cx0), height: tlH)
            // Dark-red tint over the thumbnails.
            NSColor(calibratedRed: 0.50, green: 0.05, blue: 0.08, alpha: 0.55).setFill()
            cutRect.fill()
            // Diagonal hatching.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: cutRect).addClip()
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let stripes = NSBezierPath()
            stripes.lineWidth = 1
            let step: CGFloat = 6
            var x = cutRect.minX - cutRect.height
            while x < cutRect.maxX + cutRect.height {
                stripes.move(to: NSPoint(x: x, y: cutRect.minY))
                stripes.line(to: NSPoint(x: x + cutRect.height, y: cutRect.maxY))
                x += step
            }
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Trim border highlight
        NSGraphicsContext.restoreGraphicsState()

        // Trim window: yellow frame with 9pt side grips (mac-video.html .trim .win2).
        let trimYellow = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        let trimRect = NSRect(x: startX, y: tlY, width: max(18, endX - startX), height: tlH)
        let outer = NSBezierPath(roundedRect: trimRect, xRadius: 6, yRadius: 6)
        let inner = NSBezierPath(roundedRect: trimRect.insetBy(dx: 9, dy: 2), xRadius: 2, yRadius: 2)
        outer.append(inner.reversed)
        trimYellow.setFill()
        outer.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        for gripX in [trimRect.minX + 4.5, trimRect.maxX - 4.5] {
            let grip = NSBezierPath()
            grip.lineWidth = 1.5
            grip.move(to: NSPoint(x: gripX, y: trimRect.midY - 6)); grip.line(to: NSPoint(x: gripX, y: trimRect.midY + 6))
            grip.stroke()
        }

        // Playhead — line spans the full trim timeline. Circle sits BELOW
        // the trim bar in the gap between it and the effects scroll view.
        // (Previously the circle sat above, but the time-labels row lives
        // there now — a circle at x = timelinePad would collide with the
        // current-time label at t = 0.)
        if player != nil || isGIF {
            let currentTime = currentPlaybackTime
            let playheadX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentTime / duration) * tlW))
            // Remember the last drawn position so `invalidatePlayheadArea`
            // can clip invalidation to just the old + new stripe instead
            // of marking the whole view dirty.
            lastDrawnPlayheadX = playheadX

            // Red playhead through ruler + filmstrip with a pentagon head
            // (mac-video.html .phd). The effects band is a sibling scroll view.
            let rulerTop = tlY + tlH + labelsRowH
            NSColor.systemRed.setFill()
            NSRect(x: playheadX - 1, y: tlY - 6, width: 2, height: rulerTop - (tlY - 6) - 4).fill()
            let head = NSBezierPath()
            let headTop = rulerTop - 4
            head.move(to: NSPoint(x: playheadX - 6, y: headTop))
            head.line(to: NSPoint(x: playheadX + 6, y: headTop))
            head.line(to: NSPoint(x: playheadX + 6, y: headTop - 6.6))
            head.line(to: NSPoint(x: playheadX, y: headTop - 12))
            head.line(to: NSPoint(x: playheadX - 6, y: headTop - 6.6))
            head.close()
            head.fill()
        }
    }

    /// Mark only the stripe containing the old and new playhead positions
    /// + the left current-time label area as dirty. Lets AppKit clip the
    /// draw so the expensive button-rendering (SF Symbols, NSImage blits)
    /// at the bottom of the controls area stays out of the per-frame path.
    ///
    /// Used in place of `self.needsDisplay = true` from the 30Hz playback
    /// observers. Other mutations (trim drag, segment edits, window
    /// resize) still use `needsDisplay = true` for full redraws.
    private func invalidatePlayheadArea() {
        transportTime?.attributedStringValue = transportTimeString()
        playButton?.needsDisplay = true
        let tlX = timelineLeft
        let tlW = bounds.width - timelineLeft - timelineRight
        let newX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentPlaybackTime / max(duration, 0.0001)) * tlW))
        let oldX = lastDrawnPlayheadX ?? newX

        // Y-range that actually needs to redraw when the playhead moves:
        // from the playhead circle (just below the trim bar) up through
        // the time-labels row. Explicitly excludes the bottom buttons
        // (y=0→buttonsAreaH) so SF-Symbol rendering stays off the 30Hz
        // path — that was eating ~1s/10s on the main thread.
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        let tlY = buttonsAreaH + scrollH + scrollToLabelsGap
        let playheadBandMinY = tlY - 8                                               // below trim bar
        let playheadBandMaxY = tlY + trimBarH + labelsAboveTrimGap + labelsRowH + 2  // through label row

        // 1) The playhead stripe (line + circle + trim bar content around it).
        //    Generous padding so the 8pt circle and 2pt line land fully inside.
        let pad: CGFloat = 12
        let stripeMinX = min(oldX, newX) - pad
        let stripeMaxX = max(oldX, newX) + pad
        setNeedsDisplay(NSRect(x: stripeMinX, y: playheadBandMinY,
                                width: stripeMaxX - stripeMinX,
                                height: playheadBandMaxY - playheadBandMinY))

        // 2) The left time label (shows current playback time, which changes
        //    every frame). Same vertical band — not the full controls height.
        setNeedsDisplay(NSRect(x: 0, y: playheadBandMinY,
                                width: tlX + 100,
                                height: playheadBandMaxY - playheadBandMinY))
    }

    private func drawHandleGrip(in rect: NSRect) {
        ToolbarLayout.iconColor.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let midY = rect.midY
        for dy in stride(from: -3 as CGFloat, through: 3, by: 3) {
            path.move(to: NSPoint(x: rect.midX - 2, y: midY + dy))
            path.line(to: NSPoint(x: rect.midX + 2, y: midY + dy))
        }
        path.stroke()
    }

    private func drawButtons() {
        let btnH: CGFloat = 28
        let btnY: CGFloat = 12
        let gap: CGFloat = 8
        let iconBtnW: CGFloat = 34
        let labelBtnW: CGFloat = 100

        // Pre-compute right group width so left content knows where to stop
        let copyArrowW: CGFloat = 20
        let saveArrowW: CGFloat = 20
        let rightGroupW = (labelBtnW + copyArrowW) + gap + iconBtnW + gap + labelBtnW + gap + (labelBtnW + saveArrowW)
        let maxLeftX = bounds.width - timelinePad - rightGroupW - 12  // 12pt breathing room

        // Left group: play, mute
        var x: CGFloat = timelinePad

        let isPlaying = isGIF ? gifIsPlaying : (player?.rate ?? 0 > 0)
        playBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: playBtnRect, symbol: isPlaying ? "pause.fill" : "play.fill", accent: true)
        x += iconBtnW + gap

        muteBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: muteBtnRect, symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accent: false, active: isMuted)
        x += iconBtnW + gap

        // Format toggle + file info
        if !isGIF {
            // MP4 | GIF segmented toggle
            let segW: CGFloat = 88
            let segH: CGFloat = 22
            let segY = btnY + (btnH - segH) / 2
            formatToggleRect = NSRect(x: x + 4, y: segY, width: segW, height: segH)
            let halfW = segW / 2
            formatMP4Rect = NSRect(x: formatToggleRect.minX, y: segY, width: halfW, height: segH)
            formatGIFRect = NSRect(x: formatToggleRect.minX + halfW, y: segY, width: halfW, height: segH)

            // Background
            ToolbarLayout.iconColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: formatToggleRect, xRadius: 5, yRadius: 5).fill()

            // Selected segment highlight
            let selRect = exportAsGIF ? formatGIFRect : formatMP4Rect
            ToolbarLayout.accentColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: selRect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()

            // Labels
            let selAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ToolbarLayout.iconColor,
            ]
            let unselAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
            ]
            let mp4Str = "MP4" as NSString
            let gifStr = "GIF" as NSString
            let mp4Size = mp4Str.size(withAttributes: selAttrs)
            let gifSize = gifStr.size(withAttributes: selAttrs)
            mp4Str.draw(at: NSPoint(x: formatMP4Rect.midX - mp4Size.width / 2, y: formatMP4Rect.midY - mp4Size.height / 2),
                        withAttributes: exportAsGIF ? unselAttrs : selAttrs)
            gifStr.draw(at: NSPoint(x: formatGIFRect.midX - gifSize.width / 2, y: formatGIFRect.midY - gifSize.height / 2),
                        withAttributes: exportAsGIF ? selAttrs : unselAttrs)
            x += segW + 12
        }

        do {
            let infoAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.4),
            ]
            let sourceFileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sourceFileSize), countStyle: .file)
            let fpsValue = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0
            let fpsStr = fpsValue > 0 ? "\(Int(fpsValue.rounded()))fps" : ""
            let infoStr = "\(sizeStr)  ·  \(fpsStr)" as NSString
            let infoSize = infoStr.size(withAttributes: infoAttrs)
            if x + infoSize.width < maxLeftX {
                infoStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - infoSize.height) / 2), withAttributes: infoAttrs)
                x += infoSize.width + 12
            }

            // Dimensions dropdown button
            dimensionsBtnRect = .zero
            if originalWidth > 0 && x < maxLeftX {
                let exportW = Int(CGFloat(originalWidth) * exportScale)
                let exportH = Int(CGFloat(originalHeight) * exportScale)
                let dimLabel: String
                if exportScale >= 0.999 {
                    dimLabel = "\(originalWidth)×\(originalHeight)"
                } else {
                    let pct = Int((exportScale * 100).rounded())
                    dimLabel = "\(exportW)×\(exportH) (\(pct)%)"
                }
                let dimAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(exportScale < 0.999 ? 0.7 : 0.4),
                ]
                let dimStr = "  ·  \(dimLabel) ▼" as NSString
                let dimSize = dimStr.size(withAttributes: dimAttrs)
                let dimBtnW = dimSize.width + 8
                if x + dimBtnW < maxLeftX {
                    dimensionsBtnRect = NSRect(x: x, y: btnY, width: dimBtnW, height: btnH)
                    dimStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - dimSize.height) / 2), withAttributes: dimAttrs)
                    x += dimBtnW
                }
            }

            // Quality dropdown (only meaningful when exporting as MP4)
            qualityBtnRect = .zero
            if !exportAsGIF && x < maxLeftX {
                let qualAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(exportQuality != .high ? 0.7 : 0.4),
                ]
                let qualStr = "  ·  \(exportQuality.displayName) ▼" as NSString
                let qualSize = qualStr.size(withAttributes: qualAttrs)
                let qualBtnW = qualSize.width + 8
                if x + qualBtnW < maxLeftX {
                    qualityBtnRect = NSRect(x: x, y: btnY, width: qualBtnW, height: btnH)
                    qualStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - qualSize.height) / 2), withAttributes: qualAttrs)
                    x += qualBtnW
                }
            }

            // GIF frame rate dropdown (only meaningful when exporting as GIF)
            gifFPSBtnRect = .zero
            if exportAsGIF && x < maxLeftX {
                let fpsAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(gifExportFPS != 15 ? 0.7 : 0.4),
                ]
                let fpsStr = "  ·  \(gifExportFPS) fps ▼" as NSString
                let fpsSize = fpsStr.size(withAttributes: fpsAttrs)
                let fpsBtnW = fpsSize.width + 8
                if x + fpsBtnW < maxLeftX {
                    gifFPSBtnRect = NSRect(x: x, y: btnY, width: fpsBtnW, height: btnH)
                    fpsStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - fpsSize.height) / 2), withAttributes: fpsAttrs)
                    x += fpsBtnW
                }
            }

            // Estimated export size — show when trim, scale, quality, or format change would affect output
            let trimRatio = duration > 0 ? (trimEnd - trimStart) / duration : 1.0
            let scaleRatio = exportScale * exportScale  // pixels scale quadratically
            // Quality multiplier on output bitrate (low ~0.33, medium ~0.62, high ~1.0)
            let qualityRatio: Double = {
                switch exportQuality {
                case .low:    return 0.33
                case .medium: return 0.62
                case .high:   return 1.0
                }
            }()
            let willChange = trimRatio < 0.99 || scaleRatio < 0.99 || qualityRatio < 0.99 || exportAsGIF
            if willChange && sourceFileSize > 0 && x < maxLeftX {
                let estimated: Int64
                if exportAsGIF {
                    let gifFPSRatio = min(15.0, fpsValue) / max(fpsValue, 1.0)
                    estimated = Int64(Double(sourceFileSize) * trimRatio * scaleRatio * 3.0 * Double(gifFPSRatio))
                } else {
                    estimated = Int64(Double(sourceFileSize) * trimRatio * scaleRatio * qualityRatio)
                }
                let estStr = "  ·  ~\(ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file))" as NSString
                let estAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.35),
                ]
                let estSize = estStr.size(withAttributes: estAttrs)
                if x + estSize.width + 8 < maxLeftX {
                    estStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - estSize.height) / 2), withAttributes: estAttrs)
                }
            }
        }

        // Right group: save, upload, finder, copy
        x = bounds.width - timelinePad
        let fullCopyW = labelBtnW + copyArrowW
        x -= fullCopyW
        let fullCopyRect = NSRect(x: x, y: btnY, width: fullCopyW, height: btnH)
        copyBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        copyArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: copyArrowW, height: btnH)

        // Draw combined background
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullCopyRect, xRadius: 6, yRadius: 6).fill()

        do {
            let iconSize: CGFloat = 12
            let copyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.85),
            ]
            let copyLabel = L("Copy") as NSString
            let copyLabelSize = copyLabel.size(withAttributes: copyAttrs)
            let totalCopyW = iconSize + 4 + copyLabelSize.width
            let copyStartX = copyBtnRect.midX - totalCopyW / 2
            if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    ToolbarLayout.iconColor.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: copyStartX, y: copyBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            copyLabel.draw(at: NSPoint(x: copyStartX + iconSize + 4, y: copyBtnRect.midY - copyLabelSize.height / 2), withAttributes: copyAttrs)
        }

        // Separator line
        ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
        let copySep = NSBezierPath()
        copySep.move(to: NSPoint(x: copyArrowRect.minX, y: copyArrowRect.minY + 4))
        copySep.line(to: NSPoint(x: copyArrowRect.minX, y: copyArrowRect.maxY - 4))
        copySep.lineWidth = 1
        copySep.stroke()

        // Chevron
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { r in
                chevron.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: copyArrowRect.midX - chevron.size.width / 2, y: copyArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }

        x -= gap + iconBtnW
        finderBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: finderBtnRect, symbol: "folder", accent: false, dimmed: savedURL == nil)
        #if !OFFLINE
        x -= gap + labelBtnW
        let uploadProvider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        let canUpload = (uploadProvider == "gdrive" && GoogleDriveUploader.shared.isSignedIn) || (uploadProvider == "s3" && S3Uploader.shared.isConfigured)
        uploadBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        drawLabelButton(rect: uploadBtnRect, symbol: "icloud.and.arrow.up", label: L("Upload"), dimmed: !canUpload)
        #endif
        let arrowW: CGFloat = 20
        x -= gap + labelBtnW + arrowW
        let fullSaveW = labelBtnW + arrowW
        let fullSaveRect = NSRect(x: x, y: btnY, width: fullSaveW, height: btnH)
        saveBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        saveArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: arrowW, height: btnH)

        // Draw combined background
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullSaveRect, xRadius: 6, yRadius: 6).fill()

        // Draw save icon + label
        do {
            let iconSize: CGFloat = 12
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.85),
            ]
            let saveLabel = L("Save") as NSString
            let labelSize = saveLabel.size(withAttributes: attrs)
            let totalW = iconSize + 4 + labelSize.width
            let startX = saveBtnRect.midX - totalW / 2
            if let img = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    ToolbarLayout.iconColor.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: startX, y: saveBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            saveLabel.draw(at: NSPoint(x: startX + iconSize + 4, y: saveBtnRect.midY - labelSize.height / 2), withAttributes: attrs)
        }

        // Draw separator line
        ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: saveArrowRect.minX, y: saveArrowRect.minY + 4))
        sep.line(to: NSPoint(x: saveArrowRect.minX, y: saveArrowRect.maxY - 4))
        sep.lineWidth = 1
        sep.stroke()

        // Draw chevron in arrow portion
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { r in
                chevron.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: saveArrowRect.midX - chevron.size.width / 2, y: saveArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }
    }

    private func drawIconButton(rect: NSRect, symbol: String, accent: Bool, active: Bool = false, dimmed: Bool = false) {
        let bg = accent ? ToolbarLayout.accentColor : (active ? ToolbarLayout.accentColor.withAlphaComponent(0.4) : ToolbarLayout.iconColor.withAlphaComponent(dimmed ? 0.04 : 0.1))
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 1.0
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            let imgRect = NSRect(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2,
                                  width: img.size.width, height: img.size.height)
            tinted.draw(in: imgRect)
        }
    }

    private func drawLabelButton(rect: NSRect, symbol: String, label: String, dimmed: Bool = false) {
        let bg = ToolbarLayout.iconColor.withAlphaComponent(dimmed ? 0.04 : 0.1)
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 0.85
        let iconSize: CGFloat = 12
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(alpha),
        ]
        let str = label as NSString
        let textSize = str.size(withAttributes: attrs)
        let iconGap: CGFloat = 8
        let totalW = iconSize + iconGap + textSize.width
        let startX = rect.midX - totalW / 2

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: startX, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        str.draw(at: NSPoint(x: startX + iconSize + iconGap, y: rect.midY - textSize.height / 2), withAttributes: attrs)
    }

    /// Time labels sit ABOVE the trim bar (AppKit y=up), so the status
    /// banner "Copied to clipboard!" and the left/right time readouts
    /// don't collide with the effects band's cursor-follow "+" hint or
    /// the "Click to add effects" empty-state that sits just above the
    /// bottom buttons.
    /// Extra vertical gap between the trim bar top and the time labels,
    /// purely for visual breathing room. Without it the labels hug the
    /// top edge of the trim rectangle and look cramped.
    private let labelsAboveTrimGap: CGFloat = 0

    private var timeLabelY: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        ]
        let sampleHeight = ("0" as NSString).size(withAttributes: attrs).height
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        // Bottom of the labels row sits slightly above the top of the
        // trim bar — `labelsAboveTrimGap` gives the text a little
        // breathing room so it doesn't look pasted onto the bar.
        let labelsRowBottom = buttonsAreaH + scrollH + scrollToLabelsGap + trimBarH + labelsAboveTrimGap
        return labelsRowBottom + (labelsRowH - sampleHeight) / 2
    }

    /// Ruler above the filmstrip (mac-video.html .ruler): ticks + mm:ss labels.
    private func drawTimeLabels() {
        guard duration > 0 else { return }
        let rulerY = timelineRect.maxY
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { CGFloat($0 / duration) * timelineRect.width >= 64 } ?? 600
        var t: Double = 0
        while t <= duration + 0.0001 {
            let x = timelineRect.minX + CGFloat(t / duration) * timelineRect.width
            Self.line.setFill()
            NSRect(x: x, y: rulerY + 10, width: 0.5, height: 12).fill()
            let label = step < 1 ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
            let size = (label as NSString).size(withAttributes: attrs)
            if x + 4 + size.width <= bounds.width - 2 {
                (label as NSString).draw(at: NSPoint(x: x + 4, y: rulerY + 10 + (12 - size.height) / 2), withAttributes: attrs)
            }
            t += step
        }
    }

    private func drawStatus(_ message: String) {
        // Header status pill (mac-video.html .stat).
        Self.fill.setFill()
        NSBezierPath(roundedRect: statusPillRect, xRadius: 7, yRadius: 7).fill()
        let color: NSColor = statusIsError ? .systemRed : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: NSPoint(x: statusPillRect.midX - size.width / 2, y: statusPillRect.midY - size.height / 2), withAttributes: attrs)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - floor(seconds)) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }

    // MARK: - Mouse

    // MARK: - Effects preview overlay

    /// Full sync: update the overlay's selection AND seek the preview to a
    /// time that makes editing intuitive. Call only when selection changes,
    /// not during a drag (seeking mid-drag stutters the decoder).
    private func updateEffectsOverlay() {
        refreshOverlaySelection()
        // Seek only on selection change, based on the newly-selected segment.
        if let id = selectedSegmentID {
            if let seg = zoomSegments.first(where: { $0.id == id }) {
                seekPreview(to: max(0, seg.startTime - 0.05))
            } else if let seg = censorSegments.first(where: { $0.id == id }) {
                seekPreview(to: (seg.startTime + seg.endTime) / 2)
            } else if let seg = textSegments.first(where: { $0.id == id }) {
                seekPreview(to: (seg.startTime + seg.endTime) / 2)
            }
        }
    }

    /// Light sync: update the overlay's displayed rect + kind without seeking.
    /// Safe to call during an active drag or when a segment's properties
    /// change without the selection itself moving.
    private func refreshOverlaySelection() {
        guard let overlay = effectsOverlay else { return }
        if let id = selectedSegmentID {
            if let seg = zoomSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .zoom, rect: rectForZoom(seg))
                return
            }
            if let seg = censorSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .censor(seg.style), rect: seg.rect)
                return
            }
            if let seg = textSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .text, rect: seg.rect)
                return
            }
        }
        overlay.selection = nil
    }

    private func seekPreview(to t: Double) {
        guard let player = player else { return }
        if player.rate > 0 { player.pause() }
        let target = mapSourceTimeToPreviewClock(t)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Translate a source-asset time to the current player item's clock.
    /// When preview is composition-backed (cuts present) this collapses the
    /// cut ranges; otherwise it's a pass-through.
    fileprivate func mapSourceTimeToPreviewClock(_ sourceTime: Double) -> Double {
        guard previewUsesComposition else { return sourceTime }
        return previewSourceTimeToComp(sourceTime, against: player?.currentItem?.asset ?? asset ?? AVAsset(url: videoURL))
    }

    /// Inverse of `mapSourceTimeToPreviewClock`. Callers that read the
    /// current player time but want it in source-asset terms (e.g. to draw
    /// the playhead) should go through this.
    fileprivate func mapPreviewClockToSourceTime(_ previewTime: Double) -> Double {
        guard previewUsesComposition else { return previewTime }
        return previewCompTimeToSource(previewTime)
    }

    /// Representation of a zoom segment as a normalized rect. Shape is always
    /// a square of side 1/zoomLevel, centered on segment.center. Used only
    /// for display in the overlay — the underlying model still uses
    /// (center, zoomLevel) as its source of truth.
    private func rectForZoom(_ seg: VideoZoomSegment) -> CGRect {
        let side = 1.0 / max(seg.zoomLevel, 0.0001)
        let x = seg.center.x - side / 2
        let y = seg.center.y - side / 2
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Called when the overlay view reports a new normalized rect.
    /// Dispatches based on the currently-selected segment type.
    private func overlayRectChanged(_ rect: CGRect) {
        guard let id = selectedSegmentID else { return }
        savedURL = nil
        if let seg = zoomSegments.first(where: { $0.id == id }) {
            // Derive zoom level from rect size, clamp to model's range. Use
            // the longer side so the entire rect fits inside the zoom window.
            let side = max(rect.width, rect.height, 0.0001)
            let desiredZoom = 1.0 / side
            seg.zoomLevel = max(VideoZoomSegment.minZoom,
                                 min(VideoZoomSegment.maxZoom, desiredZoom))
            // Center on the rect midpoint
            seg.center = CGPoint(x: rect.midX, y: rect.midY)
        } else if let seg = censorSegments.first(where: { $0.id == id }) {
            seg.rect = VideoCensorSegment.clampedRect(rect)
        } else if let seg = textSegments.first(where: { $0.id == id }) {
            seg.rect = VideoTextSegment.clampedRect(rect)
            // Rect resize changes pixel size → invalidate raster cache for
            // this segment so the next composition rebuild re-rasterizes
            // at the new size. Drop only this entry; keep other texts cached.
            textRasterCache.removeValue(forKey: id)
        }
        applyZoomTransformForCurrentTime()
        effectsBand?.refreshAfterParentEdit()
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Trim handles (higher priority than zoom segments)
        let handleHitW: CGFloat = 16
        let startX = timelineRect.minX + CGFloat(trimStart / duration) * timelineRect.width
        let endX = timelineRect.minX + CGFloat(trimEnd / duration) * timelineRect.width

        if abs(point.x - startX) < handleHitW && abs(point.y - timelineRect.midY) < 25 {
            isDraggingStart = true; return
        }
        if abs(point.x - endX) < handleHitW && abs(point.y - timelineRect.midY) < 25 {
            isDraggingEnd = true; return
        }

        // Scrub timeline
        if timelineRect.insetBy(dx: 0, dy: -10).contains(point) {
            // Clicking the trim bar deselects any effect segment
            effectsBand?.clearSelection()
            isDraggingScrubber = true
            scrubTo(point: point)
            return
        }

        // Clicking outside the timeline also deselects
        effectsBand?.clearSelection()

        // Format toggle
        if formatMP4Rect.contains(point) && exportAsGIF {
            exportAsGIF = false; savedURL = nil; refreshInspector(); needsDisplay = true; return
        }
        if formatGIFRect.contains(point) && !exportAsGIF {
            exportAsGIF = true; savedURL = nil; refreshInspector(); needsDisplay = true; return
        }

        // Dimensions dropdown
        if dimensionsBtnRect.contains(point) && originalWidth > 0 {
            showDimensionsMenu(); return
        }

        // Quality dropdown
        if qualityBtnRect.contains(point) {
            showQualityMenu(); return
        }

        // GIF frame rate dropdown
        if gifFPSBtnRect.contains(point) && exportAsGIF {
            showGIFFPSMenu(); return
        }

        // Buttons
        if playBtnRect.contains(point) { togglePlayPause(); return }
        if muteBtnRect.contains(point) { toggleMute(); return }
        if saveArrowRect.contains(point) { showSaveMenu(); return }
        if saveBtnRect.contains(point) { saveVideo(); return }
        #if !OFFLINE
        if uploadBtnRect.contains(point) { uploadVideo(); return }
        #endif
        if finderBtnRect.contains(point) {
            if let url = savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        if copyArrowRect.contains(point) { showCopyMenu(); return }
        if copyBtnRect.contains(point) { copyToClipboard(); return }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDraggingStart {
            let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
            trimStart = min(t, trimEnd - 0.1)
            let target = mapSourceTimeToPreviewClock(trimStart)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingEnd {
            let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
            trimEnd = max(t, trimStart + 0.1)
            let target = mapSourceTimeToPreviewClock(trimEnd)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingScrubber {
            scrubTo(point: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingStart = false
        isDraggingEnd = false
        isDraggingScrubber = false
    }

    private func scrubTo(point: NSPoint) {
        let t = max(trimStart, min(trimEnd, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
        let target = mapSourceTimeToPreviewClock(t)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - Actions

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        refreshHeaderInfo()
        needsDisplay = true
    }

    private func togglePlayPause() {
        if isGIF {
            gifIsPlaying.toggle()
            gifImageView?.animates = gifIsPlaying
            if gifIsPlaying {
                gifPlaybackTime = trimStart
            }
            needsDisplay = true
            return
        }
        guard let player = player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            let current = mapPreviewClockToSourceTime(CMTimeGetSeconds(player.currentTime()))
            if current < trimStart || current >= trimEnd - 0.1 {
                let target = mapSourceTimeToPreviewClock(trimStart)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }
            player.play()
        }
        playButton?.needsDisplay = true
        needsDisplay = true
    }

    private func showStatus(_ msg: String, isError: Bool = false, persist: Bool = false) {
        statusMessage = msg
        statusIsError = isError
        needsLayout = true
        statusTimer?.invalidate()
        if !persist {
            statusTimer = Timer.scheduledTimer(withTimeInterval: isError ? 6 : 3, repeats: false) { [weak self] _ in
                self?.statusMessage = nil
                self?.needsLayout = true
                self?.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    private func copyToClipboard() {
        // If GIF mode is selected but no GIF has been saved yet, convert to a temp GIF first
        if exportAsGIF && !isGIF && !(savedURL?.pathExtension.lowercased() == "gif") {
            showStatus(L("Converting to GIF…"))
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
            convertToGIF(destURL: tmpURL) { [weak self] success in
                guard let self = self, success else { return }
                self.copyGIFData(from: tmpURL)
            }
            return
        }

        // Trim, zoom/censor/text, cuts, speed, mute etc. exist only in the
        // export pipeline — copying the raw source URL would silently discard
        // them (#193). savedURL is reset to nil on every edit, so it being nil
        // with pending edits means the source file is stale.
        if savedURL == nil && hasPendingEdits {
            showStatus(L("Exporting..."))
            exportEditedTemp { [weak self] url in
                guard let self = self else { return }
                guard let url = url else {
                    self.showStatus(L("Export failed"), isError: true)
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
                self.showStatus(L("Copied to clipboard!"))
            }
            return
        }

        let url = savedURL ?? videoURL
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if isGIF || url.pathExtension.lowercased() == "gif" {
            copyGIFData(from: url)
        } else {
            pasteboard.writeObjects([url as NSURL])
            showStatus(L("Copied to clipboard!"))
        }
    }

    /// True when the timeline differs from the source file on disk — the same
    /// conditions saveToDestination uses to decide whether an export is needed.
    private var hasPendingEdits: Bool {
        let needsTrim = trimStart > 0.01 || (duration - trimEnd) > 0.01
        let needsScale = exportScale < 0.999
        let needsRecompress = exportQuality != .high
        let needsEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        return needsTrim || isMuted || needsScale || needsRecompress || needsEffects
            || !cutSegments.isEmpty || !speedSegments.isEmpty || !freezeSegments.isEmpty
    }

    /// Export the edited timeline to a temp file using the same pipeline
    /// selection as saveToDestination, calling completion on the main thread.
    private func exportEditedTemp(completion: @escaping (URL?) -> Void) {
        guard let asset = asset else { completion(nil); return }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(videoURL.pathExtension)")
        let timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                    end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        // reencodeExport can complete from its background queue on early
        // exits — always hop to main before touching pasteboard/UI.
        let done: (Bool) -> Void = { success in
            DispatchQueue.main.async {
                if !success { try? FileManager.default.removeItem(at: tmpURL) }
                completion(success ? tmpURL : nil)
            }
        }
        if exportQuality != .high {
            reencodeExport(asset: asset, timeRange: timeRange, outputURL: tmpURL, completion: done)
        } else {
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
                done(false)
                return
            }
            Task {
                await session.export()
                await MainActor.run { done(session.status == .completed) }
            }
        }
    }

    private func copyGIFData(from url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? Data(contentsOf: url) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        }
        showStatus(L("Copied to clipboard!"))
    }

    private func showCopyMenu() {
        let menu = NSMenu()
        let pathItem = NSMenuItem(title: L("Copy Path"), action: #selector(copyPathAction), keyEquivalent: "")
        pathItem.target = self
        menu.addItem(pathItem)
        let pos = NSPoint(x: copyArrowRect.minX, y: copyArrowRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func copyPathAction() {
        let url = savedURL ?? videoURL
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showStatus(L("Path copied!"))
    }

    private func exportSession(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) -> AVAssetExportSession? {
        let needsScale = exportScale < 0.999
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        // Freezes force the custom compositor on — AVAssetExportSession fails
        // on the extreme scaleTimeRange a freeze bakes into the composition
        // track (1/600s source slice stretched to ~1s = 600× scale).
        let hasFreeze = !freezeSegments.isEmpty

        guard let processed = buildProcessedComposition(
            srcAsset: asset,
            trimStartSec: CMTimeGetSeconds(timeRange.start),
            trimEndSec: CMTimeGetSeconds(timeRange.end),
            includeAudio: !isMuted
        ) else { return nil }

        guard let session = AVAssetExportSession(asset: processed.composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        session.outputURL = outputURL
        session.outputFileType = .mp4

        if needsScale || hasEffects || hasFreeze {
            guard let srcVideoTrack = asset.tracks(withMediaType: .video).first else { return session }
            let naturalSize = srcVideoTrack.naturalSize.applying(srcVideoTrack.preferredTransform)
            let (scaledW, scaledH) = VideoEncodingSettings.evenDimensions(
                width: abs(naturalSize.width) * exportScale,
                height: abs(naturalSize.height) * exportScale
            )
            let renderSize = CGSize(width: scaledW, height: scaledH)
            if hasEffects || hasFreeze {
                session.videoComposition = buildEffectsVideoComposition(
                    for: processed.composition,
                    videoTrack: processed.videoTrack,
                    renderSize: renderSize,
                    timeMap: processed.timeMap,
                    timeRangeDuration: processed.duration
                )
            } else {
                // Scale-only: no custom compositor needed, use a plain layer
                // instruction with a single transform.
                session.videoComposition = buildScaleOnlyComposition(
                    videoTrack: processed.videoTrack,
                    renderSize: renderSize,
                    totalDuration: processed.duration
                )
            }
        }

        return session
    }

    private func saveVideo() {
        if exportAsGIF && !isGIF {
            // GIF mode: need Save As panel since extension changes
            saveVideoAs()
            return
        }
        guard let dirURL = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() else {
            saveVideoAs()
            return
        }
        let ext = exportAsGIF ? "gif" : videoURL.pathExtension
        let name = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        let destURL = dirURL.appendingPathComponent(name)
        if exportAsGIF && !isGIF {
            convertToGIF(destURL: destURL)
        } else {
            saveToDestination(destURL, dirURL: dirURL)
        }
    }

    private func saveVideoAs() {
        let panel = NSSavePanel()
        let saveAsGIF = exportAsGIF && !isGIF
        panel.allowedContentTypes = saveAsGIF ? [.gif] : (isGIF ? [.gif] : [.mpeg4Movie])
        let ext = saveAsGIF ? "gif" : videoURL.pathExtension
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.level = .statusBar + 3
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            if saveAsGIF {
                self.convertToGIF(destURL: url)
            } else {
                self.saveToDestination(url, dirURL: nil)
            }
        }
    }

    private func showSaveMenu() {
        saveVideoAs()
    }

    private func showDimensionsMenu() {
        let menu = NSMenu()
        let w = originalWidth, h = originalHeight

        // Original (100%)
        let origItem = NSMenuItem(title: "\(w) × \(h)  (Original)", action: #selector(dimensionSelected(_:)), keyEquivalent: "")
        origItem.target = self
        origItem.tag = 100
        origItem.state = exportScale >= 0.999 ? .on : .off
        menu.addItem(origItem)

        menu.addItem(NSMenuItem.separator())

        // Preset percentages — only include if the result is at least 128px wide
        let presets: [(Int, String)] = [(75, "75%"), (50, "50%"), (33, "33%"), (25, "25%")]
        for (pct, label) in presets {
            let scaledW = w * pct / 100
            let scaledH = h * pct / 100
            guard scaledW >= 128 else { continue }
            // Round to even for codec compatibility
            let evenW = (scaledW / 2) * 2
            let evenH = (scaledH / 2) * 2
            let item = NSMenuItem(title: "\(evenW) × \(evenH)  (\(label))", action: #selector(dimensionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            item.state = abs(exportScale - CGFloat(pct) / 100.0) < 0.01 ? .on : .off
            menu.addItem(item)
        }

        let pos = NSPoint(x: dimensionsBtnRect.minX, y: dimensionsBtnRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func dimensionSelected(_ sender: NSMenuItem) {
        exportScale = CGFloat(sender.tag) / 100.0
        savedURL = nil
        refreshInspector()
        needsDisplay = true
    }

    private func showQualityMenu() {
        let menu = NSMenu()
        let options: [(VideoQuality, String)] = [
            (.high,   L("High")),
            (.medium, L("Medium")),
            (.low,    L("Low")),
        ]
        for (q, label) in options {
            let item = NSMenuItem(title: label, action: #selector(qualitySelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q.rawValue
            item.state = (q == exportQuality) ? .on : .off
            menu.addItem(item)
        }
        let pos = NSPoint(x: qualityBtnRect.minX, y: qualityBtnRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    private func showGIFFPSMenu() {
        let menu = NSMenu()
        for fps in 5...30 {
            let item = NSMenuItem(title: "\(fps) fps", action: #selector(gifFPSSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = fps
            item.state = (fps == gifExportFPS) ? .on : .off
            menu.addItem(item)
        }
        let pos = NSPoint(x: gifFPSBtnRect.minX, y: gifFPSBtnRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func gifFPSSelected(_ sender: NSMenuItem) {
        gifExportFPS = min(30, max(5, sender.tag))
        UserDefaults.standard.set(gifExportFPS, forKey: "gifExportFPS")
        savedURL = nil
        refreshInspector()
        needsDisplay = true
    }

    @objc private func qualitySelected(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let q = VideoQuality(rawValue: raw) {
            exportQuality = q
            savedURL = nil
            refreshInspector()
            needsDisplay = true
        }
    }

    private func convertToGIF(destURL: URL, completion: ((Bool) -> Void)? = nil) {
        guard let asset = asset else { completion?(false); return }
        showStatus(L("Processing GIF…"), persist: true)

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)
        // User-selected GIF frame rate (5-30), capped at the source frame rate
        // so playback speed stays true to real time.
        let sourceNominalFPS = asset.tracks(withMediaType: .video).first.map { Int($0.nominalFrameRate.rounded()) } ?? 30
        let gifFPS = min(max(5, min(30, gifExportFPS)), max(5, sourceNominalFPS))
        let scale = exportScale
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty

        // Build the effects-composition pipeline on the main thread before jumping
        // to background so the video composition builder sees our current state.
        var readerAsset: AVAsset = asset
        var readerVideoTrackOpt: AVAssetTrack? = asset.tracks(withMediaType: .video).first
        var readerTimeRange: CMTimeRange = timeRange
        var readerVideoComposition: AVMutableVideoComposition?
        var readerOutW = 0
        var readerOutH = 0
        if hasEffects, let vt = readerVideoTrackOpt {
            if let processed = buildProcessedComposition(
                srcAsset: asset,
                trimStartSec: CMTimeGetSeconds(timeRange.start),
                trimEndSec: CMTimeGetSeconds(timeRange.end),
                // GIF has no audio — skip the audio comp tracks entirely.
                includeAudio: false
            ) {
                let natSize = vt.naturalSize.applying(vt.preferredTransform)
                let (outW, outH) = VideoEncodingSettings.evenDimensions(
                    width: abs(natSize.width) * scale,
                    height: abs(natSize.height) * scale
                )
                readerOutW = outW
                readerOutH = outH
                readerAsset = processed.composition
                readerVideoTrackOpt = processed.videoTrack
                readerTimeRange = CMTimeRange(start: .zero, duration: processed.composition.duration)
                readerVideoComposition = buildEffectsVideoComposition(
                    for: processed.composition,
                    videoTrack: processed.videoTrack,
                    renderSize: CGSize(width: outW, height: outH),
                    timeMap: processed.timeMap,
                    timeRangeDuration: processed.duration
                )
            }
        }

        // .userInitiated instead of .background: on Apple Silicon, background QoS
        // is confined to efficiency cores and heavily throttled, making GIF
        // conversion many times slower than the hardware allows. The MP4 export
        // path already uses .userInitiated; UI stays responsive either way since
        // the work is off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let reader = try AVAssetReader(asset: readerAsset)
                guard let videoTrack = readerVideoTrackOpt else {
                    DispatchQueue.main.async {
                        self?.showStatus(L("No video track found"), isError: true)
                        completion?(false)
                    }
                    return
                }

                let readerOutput: AVAssetReaderOutput
                if let comp = readerVideoComposition {
                    let cOut = AVAssetReaderVideoCompositionOutput(
                        videoTracks: [videoTrack],
                        videoSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferWidthKey as String: readerOutW,
                            kCVPixelBufferHeightKey as String: readerOutH,
                        ]
                    )
                    cOut.videoComposition = comp
                    cOut.alwaysCopiesSampleData = false
                    readerOutput = cOut
                } else {
                    var outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    if scale < 0.999 {
                        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
                        let w = Int(abs(natSize.width) * scale) / 2 * 2
                        let h = Int(abs(natSize.height) * scale) / 2 * 2
                        outputSettings[kCVPixelBufferWidthKey as String] = w
                        outputSettings[kCVPixelBufferHeightKey as String] = h
                    }
                    let tOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                    tOut.alwaysCopiesSampleData = false
                    readerOutput = tOut
                }
                reader.timeRange = readerTimeRange
                reader.add(readerOutput)

                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
                let sourceFPS = Int(videoTrack.nominalFrameRate.rounded())
                let durationSec = CMTimeGetSeconds(readerTimeRange.duration)
                let estimatedFrames = max(1, Int(durationSec * Double(sourceFPS)))

                if let gifskiBinary = GifskiExporter.locateBinary() {
                    // Parallel all-core encoder; streams frames via disk instead
                    // of holding every frame in memory (ImageIO keeps all frames
                    // until finalize and crashes on long recordings).
                    try GifskiExporter.export(
                        binary: gifskiBinary,
                        reader: reader,
                        readerOutput: readerOutput,
                        fps: gifFPS,
                        sourceFPS: max(sourceFPS, gifFPS),
                        estimatedFrames: estimatedFrames,
                        to: tmpURL
                    ) { fraction in
                        let pct = Int(fraction * 100)
                        DispatchQueue.main.async {
                            self?.showStatus(String(format: L("Processing GIF…") + " %d%%", pct), persist: true)
                        }
                    }
                } else {
                    let encoder = GIFEncoder(url: tmpURL, fps: gifFPS, sourceFPS: max(sourceFPS, gifFPS))
                    reader.startReading()
                    var framesRead = 0
                    var lastReportedPct = -1

                    while reader.status == .reading {
                        autoreleasepool {
                            if let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                                encoder.addFrame(pixelBuffer)
                                framesRead += 1
                            }
                        }
                        // Update progress on main thread (reading = 0–50%, finalize = 50–100%)
                        let pct = min(50, framesRead * 50 / estimatedFrames)
                        if pct != lastReportedPct {
                            lastReportedPct = pct
                            DispatchQueue.main.async {
                                self?.showStatus(String(format: L("Processing GIF…") + " %d%%", pct), persist: true)
                            }
                        }
                    }

                    DispatchQueue.main.async {
                        self?.showStatus(L("Processing GIF…") + " 50%", persist: true)
                    }
                    encoder.finish()
                    DispatchQueue.main.async {
                        self?.showStatus(L("Processing GIF…") + " 100%", persist: true)
                    }
                }

                // Move to destination
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: tmpURL, to: destURL)

                DispatchQueue.main.async {
                    self?.savedURL = destURL
                    self?.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                    self?.needsDisplay = true
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showStatus(L("GIF conversion failed"), isError: true)
                    completion?(false)
                }
            }
        }
    }

    private func saveToDestination(_ destURL: URL, dirURL: URL?) {
        let needsRecompress = exportQuality != .high
        let needsExport = hasPendingEdits

        if !needsExport {
            // No processing needed — copy source to destination.
            // CRITICAL: if the destination IS the source (e.g. user opened a file
            // via "Open Video..." and saved over it with no edits), deleting the
            // destination first would destroy the source and the copy would then
            // fail — losing the user's video. In that case there's nothing to do.
            if destURL.standardizedFileURL == videoURL.standardizedFileURL {
                savedURL = destURL
                if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                needsDisplay = true
                return
            }
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: videoURL, to: destURL)
                savedURL = destURL
                if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                needsDisplay = true
            } catch {
                if dirURL != nil {
                    // Bookmarked directory failed — fall back to Save As
                    saveVideoAs()
                } else {
                    showStatus(L("Save failed"), isError: true)
                }
            }
            return
        }

        guard let asset = asset else { return }
        showStatus(L("Exporting..."))

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(videoURL.pathExtension)")
        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        let onCompletion: (Bool) -> Void = { [weak self] success in
            guard let self = self else { return }
            if success {
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: destURL)
                    self.savedURL = destURL
                    if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                    self.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                    self.needsDisplay = true
                } catch {
                    self.showStatus(L("Save failed"), isError: true)
                }
            } else {
                self.showStatus(L("Export failed"), isError: true)
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        if needsRecompress {
            reencodeExport(asset: asset, timeRange: timeRange, outputURL: tmpURL, completion: onCompletion)
        } else {
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
                showStatus(L("Export failed"), isError: true)
                return
            }
            Task {
                await session.export()
                await MainActor.run { onCompletion(session.status == .completed) }
            }
        }
    }

    /// Re-encode pipeline with explicit bitrate control via AVAssetReader/Writer.
    /// Used when the user selects a non-High quality preset so the bitrate
    /// actually takes effect (AVAssetExportSession presets hardcode bitrate).
    private func reencodeExport(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL, completion: @escaping (Bool) -> Void) {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(false)
            return
        }

        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let srcW = abs(natSize.width)
        let srcH = abs(natSize.height)
        let (outW, outH) = VideoEncodingSettings.evenDimensions(width: srcW * exportScale, height: srcH * exportScale)
        let srcFPS = Int(videoTrack.nominalFrameRate.rounded())
        let fps = max(srcFPS, 1)

        let includeAudio = !isMuted
        let srcAudioTracks = asset.tracks(withMediaType: .audio)
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        let hasCuts = !cutSegments.isEmpty
        let hasSpeed = !speedSegments.isEmpty
        let hasFreeze = !freezeSegments.isEmpty

        // When effects OR cuts OR speed OR freeze exist we must route
        // through a composition so cuts skip frames, speed/freeze scale
        // the clock, and the compositor applies zoom + censor. Otherwise
        // we read raw scaled frames directly from the source track and
        // pull audio straight from the original asset.
        //
        // Freezes additionally require the custom compositor: the reader's
        // native handling of extreme scaleTimeRange (1/600s slice → 1s)
        // doesn't reliably duplicate frames across the stretched window,
        // so we drive frame generation via the compositor's time map.
        let readerAsset: AVAsset
        let readerVideoTrack: AVAssetTrack
        let readerAudioTracks: [AVAssetTrack]
        let readerTimeRange: CMTimeRange
        let readerComposition: AVMutableVideoComposition?
        if hasEffects || hasCuts || hasSpeed || hasFreeze {
            guard let processed = buildProcessedComposition(
                srcAsset: asset,
                trimStartSec: CMTimeGetSeconds(timeRange.start),
                trimEndSec: CMTimeGetSeconds(timeRange.end),
                includeAudio: includeAudio
            ) else {
                completion(false); return
            }
            readerAsset = processed.composition
            readerVideoTrack = processed.videoTrack
            readerAudioTracks = processed.audioTracks
            readerTimeRange = CMTimeRange(start: .zero, duration: processed.composition.duration)
            if hasEffects || hasFreeze {
                readerComposition = buildEffectsVideoComposition(
                    for: processed.composition,
                    videoTrack: processed.videoTrack,
                    renderSize: CGSize(width: outW, height: outH),
                    timeMap: processed.timeMap,
                    timeRangeDuration: processed.duration
                )
            } else {
                readerComposition = nil
            }
        } else {
            readerAsset = asset
            readerVideoTrack = videoTrack
            readerAudioTracks = srcAudioTracks
            readerTimeRange = timeRange
            readerComposition = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(false); return }
            do {
                try? FileManager.default.removeItem(at: outputURL)
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let videoSettings = VideoEncodingSettings.outputSettings(
                    width: outW, height: outH, fps: fps,
                    codec: .h264, quality: self.exportQuality
                )
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = false
                // Orientation: the video composition path already produces upright
                // render-size frames, so don't re-apply preferredTransform.
                if readerComposition == nil {
                    videoInput.transform = videoTrack.preferredTransform
                }
                guard writer.canAdd(videoInput) else { completion(false); return }
                writer.add(videoInput)

                let reader = try AVAssetReader(asset: readerAsset)
                reader.timeRange = readerTimeRange

                // Video output: either composition output (zoom path) or direct
                // track output (scale-only path).
                let videoOutput: AVAssetReaderOutput
                if let comp = readerComposition {
                    let cOut = AVAssetReaderVideoCompositionOutput(
                        videoTracks: [readerVideoTrack],
                        videoSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        ]
                    )
                    cOut.videoComposition = comp
                    cOut.alwaysCopiesSampleData = false
                    videoOutput = cOut
                } else {
                    var readerOutputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ]
                    if self.exportScale < 0.999 {
                        readerOutputSettings[kCVPixelBufferWidthKey as String] = outW
                        readerOutputSettings[kCVPixelBufferHeightKey as String] = outH
                    }
                    let tOut = AVAssetReaderTrackOutput(track: readerVideoTrack, outputSettings: readerOutputSettings)
                    tOut.alwaysCopiesSampleData = false
                    videoOutput = tOut
                }
                guard reader.canAdd(videoOutput) else { completion(false); return }
                reader.add(videoOutput)

                var audioInputs: [AVAssetWriterInput] = []
                var audioOutputs: [AVAssetReaderTrackOutput] = []
                if includeAudio {
                    for track in readerAudioTracks {
                        let audioSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48000,
                            AVNumberOfChannelsKey: 2,
                            AVEncoderBitRateKey: 128_000,
                        ]
                        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                        input.expectsMediaDataInRealTime = false
                        if writer.canAdd(input) { writer.add(input); audioInputs.append(input) }

                        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false,
                        ])
                        output.alwaysCopiesSampleData = false
                        if reader.canAdd(output) { reader.add(output); audioOutputs.append(output) }
                    }
                }

                guard reader.startReading() else { completion(false); return }
                guard writer.startWriting() else { completion(false); return }
                writer.startSession(atSourceTime: .zero)

                let group = DispatchGroup()
                let videoQueue = DispatchQueue(label: "macshot.export.video")
                let audioQueue = DispatchQueue(label: "macshot.export.audio")

                // Pump video
                group.enter()
                videoInput.requestMediaDataWhenReady(on: videoQueue) {
                    while videoInput.isReadyForMoreMediaData {
                        guard reader.status == .reading,
                              let sample = videoOutput.copyNextSampleBuffer() else {
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                        // Shift PTS so the output starts at t=0
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let shifted = CMTimeSubtract(pts, readerTimeRange.start)
                        if let retimed = sample.retimed(presentationTime: shifted) {
                            if !videoInput.append(retimed) {
                                videoInput.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }

                // Pump audio (each track independently)
                for (input, output) in zip(audioInputs, audioOutputs) {
                    group.enter()
                    input.requestMediaDataWhenReady(on: audioQueue) {
                        while input.isReadyForMoreMediaData {
                            guard reader.status == .reading,
                                  let sample = output.copyNextSampleBuffer() else {
                                input.markAsFinished()
                                group.leave()
                                return
                            }
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            let shifted = CMTimeSubtract(pts, readerTimeRange.start)
                            if let retimed = sample.retimed(presentationTime: shifted) {
                                if !input.append(retimed) {
                                    input.markAsFinished()
                                    group.leave()
                                    return
                                }
                            }
                        }
                    }
                }

                group.notify(queue: .global(qos: .userInitiated)) {
                    writer.finishWriting {
                        let ok = (writer.status == .completed) && (reader.status != .failed)
                        DispatchQueue.main.async { completion(ok) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    #if !OFFLINE
    private func uploadVideo() {
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"

        if provider == "gdrive" && !GoogleDriveUploader.shared.isSignedIn {
            showStatus(L("Sign in to Google Drive in Settings"), isError: true)
            return
        }
        if provider == "s3" && !S3Uploader.shared.isConfigured {
            showStatus(L("Configure S3 in Settings"), isError: true)
            return
        }
        if provider != "gdrive" && provider != "s3" {
            showStatus(L("Video upload requires Google Drive or S3"), isError: true)
            return
        }

        let providerLabel = provider == "s3" ? "S3" : "Drive"
        showStatus(String(format: L("Uploading to %@... %d%%"), providerLabel, 0))

        let progressHandler: (Double) -> Void = { [weak self] fraction in
            self?.showStatus(String(format: L("Uploading to %@... %d%%"), providerLabel, Int(fraction * 100)))
        }

        let completionHandler: (Result<String, Error>) -> Void = { [weak self] result in
            switch result {
            case .success(let link):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                self?.showStatus(L("Uploaded! Link copied."))
            case .failure(let error):
                self?.showStatus(String(format: L("Upload failed: %@"), error.localizedDescription), isError: true)
            }
        }

        let uploadFileURL: (URL, Bool) -> Void = { fileURL, isTemp in
            let wrappedCompletion: (Result<String, Error>) -> Void = { result in
                if isTemp { try? FileManager.default.removeItem(at: fileURL) }
                completionHandler(result)
            }
            if provider == "s3" {
                S3Uploader.shared.onProgress = progressHandler
                S3Uploader.shared.uploadVideo(url: fileURL, completion: wrappedCompletion)
            } else {
                GoogleDriveUploader.shared.onProgress = progressHandler
                GoogleDriveUploader.shared.uploadVideo(url: fileURL, completion: wrappedCompletion)
            }
        }

        let needsTrim = trimStart > 0.01 || (duration - trimEnd) > 0.01
        let needsEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        let needsCuts = !cutSegments.isEmpty
        let needsSpeed = !speedSegments.isEmpty
        let needsFreeze = !freezeSegments.isEmpty
        let needsExport = needsTrim || isMuted || needsEffects || needsCuts || needsSpeed || needsFreeze

        if !needsExport {
            uploadFileURL(videoURL, false)
        } else {
            guard let asset = asset else { return }
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).mp4")

            let timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                        end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
                showStatus(L("Export failed"), isError: true)
                return
            }

            Task {
                await session.export()
                await MainActor.run {
                    guard session.status == .completed else {
                        self.showStatus(L("Export failed"), isError: true)
                        return
                    }
                    uploadFileURL(tmpURL, true)
                }
            }
        }
    }
    #endif

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space
            togglePlayPause()
        case 123: // Left arrow — step back one frame
            stepFrame(forward: false)
        case 124: // Right arrow — step forward one frame
            stepFrame(forward: true)
        default:
            // Segment-related keys (Delete, +/-) are handled by EffectsBandView
            // when it's first responder; fall through here.
            super.keyDown(with: event)
        }
    }


    /// Rebuild the AVPlayerItem's videoComposition so live playback reflects
    /// the current zoom + censor segments. Also used when editing segments
    /// during playback — AVPlayer picks up composition changes on the next frame.
    ///
    /// Preview strategy:
    ///   - No cuts, no speed: play directly off the original asset. Segment
    ///     times align with the asset clock, so the time-map is a pass-through.
    ///   - Cuts or speed present: play off a composition whose video+audio
    ///     tracks contain the kept/re-timed ranges, so cuts skip and speed
    ///     scales the clock naturally.
    ///
    /// **Flicker avoidance:** swapping the player item causes a black flash
    /// while AVPlayer re-initializes its rendering pipeline, so we only do
    /// it when the cut/speed *topology* changes. Rect/style edits on zoom
    /// or censor segments just refresh `videoComposition` on the current
    /// item — cheap and flicker-free.
    fileprivate func applyZoomTransformForCurrentTime() {
        guard let player = player, let asset = asset else { return }

        let hasCuts = !cutSegments.isEmpty
        let hasSpeed = !speedSegments.isEmpty
        let hasFreeze = !freezeSegments.isEmpty
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        let needsComposition = hasCuts || hasSpeed || hasFreeze
        // Fingerprint of the full timeline topology (cuts + speeds +
        // freezes). When unchanged we can keep the existing composition-
        // backed player item and only refresh its videoComposition.
        let topoFingerprint = timelineTopologyFingerprint()

        // Fast path: nothing to apply. Fall back to the original asset with
        // no videoComposition.
        if !needsComposition && !hasEffects {
            if previewUsesComposition {
                swapPreviewPlayerItem(asset: asset, videoComposition: nil)
                previewUsesComposition = false
                previewCompositionTopoFingerprint = ""
            } else {
                player.currentItem?.videoComposition = nil
            }
            return
        }

        // Cuts/speed absent: stay on the original asset and only attach the
        // effects composition — much cheaper than rebuilding the player item.
        if !needsComposition {
            if previewUsesComposition {
                swapPreviewPlayerItem(asset: asset, videoComposition: nil)
                previewUsesComposition = false
                previewCompositionTopoFingerprint = ""
            }
            player.currentItem?.videoComposition = buildEffectsVideoComposition(
                for: asset,
                videoTrack: asset.tracks(withMediaType: .video).first,
                renderSize: nil,
                timeMap: singleShiftTimeMap(shift: 0, duration: CMTimeGetSeconds(asset.duration)),
                timeRangeDuration: CMTimeGetSeconds(asset.duration)
            )
            return
        }

        // Timeline topology unchanged: reuse the existing item and refresh
        // only the effects composition. Avoids the black flash on rect edits.
        if previewUsesComposition,
           previewCompositionTopoFingerprint == topoFingerprint,
           let currentItem = player.currentItem,
           let compAsset = currentItem.asset as? AVMutableComposition,
           let cvt = compAsset.tracks(withMediaType: .video).first {
            if hasEffects {
                // Rebuild the time-map from current state so the compositor
                // still has accurate comp→source mapping even after trim
                // edits (topology fingerprint is invariant to trim).
                let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: duration, cuts: cutSegments)
                let pieces = VideoSpeeds.pieces(keptRanges: kept,
                                                  speeds: speedSegments,
                                                  freezes: freezeSegments)
                currentItem.videoComposition = buildEffectsVideoComposition(
                    for: compAsset,
                    videoTrack: cvt,
                    renderSize: nil,
                    timeMap: piecesToTimeMap(pieces: pieces),
                    timeRangeDuration: CMTimeGetSeconds(compAsset.duration)
                )
            } else {
                currentItem.videoComposition = nil
            }
            return
        }

        // Topology changed (cuts/speed added/removed/resized). Rebuild the
        // composition-backed player item. Preview uses the *full* asset
        // duration — not just the trim range — so scrubbing the trim bars
        // still works against source-asset time.
        guard let processed = buildProcessedComposition(
            srcAsset: asset,
            trimStartSec: 0,
            trimEndSec: duration,
            includeAudio: true
        ) else { return }

        var videoComp: AVMutableVideoComposition?
        if hasEffects {
            videoComp = buildEffectsVideoComposition(
                for: processed.composition,
                videoTrack: processed.videoTrack,
                renderSize: nil,
                timeMap: processed.timeMap,
                timeRangeDuration: processed.duration
            )
        }
        swapPreviewPlayerItem(asset: processed.composition, videoComposition: videoComp)
        previewUsesComposition = true
        previewCompositionTopoFingerprint = topoFingerprint
    }

    /// Snapshot of the cut+speed topology used to build `player.currentItem`
    /// when that item is a composition. Compared against the current
    /// fingerprint to decide whether a player-item swap is needed.
    private var previewCompositionTopoFingerprint = ""

    /// Replace the player's current item with a new one backed by `asset`,
    /// preserving playback position and rate. Preview seeks target the source
    /// asset clock, so we map the current time through the cut-aware time
    /// map before resuming.
    private func swapPreviewPlayerItem(asset: AVAsset, videoComposition: AVMutableVideoComposition?) {
        guard let player = player else { return }
        let wasPlaying = player.rate != 0
        let prevRate = player.rate
        let prevSourceTime: Double = {
            if let current = player.currentItem {
                let t = CMTimeGetSeconds(current.currentTime())
                return previewUsesComposition ? previewCompTimeToSource(t) : t
            }
            return trimStart
        }()

        let newItem = AVPlayerItem(asset: asset)
        newItem.videoComposition = videoComposition
        player.replaceCurrentItem(with: newItem)

        // Map source time → target item's clock. The comp item's clock is
        // "kept-ranges concatenated from 0". Outside of preview-comp mode
        // (straight asset), source == comp time.
        let targetT: Double
        if videoComposition != nil || asset is AVMutableComposition {
            targetT = previewSourceTimeToComp(prevSourceTime, against: asset)
        } else {
            targetT = prevSourceTime
        }
        player.seek(to: CMTime(seconds: targetT, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.rate = prevRate }
    }

    /// Convert a preview composition-clock time to source-asset time using
    /// the current cuts, speeds and freezes.
    ///
    /// Formula: for the piece covering `compTime`,
    ///     `sourceTime = piece.srcStart + (compTime - piece.compStart) * factor`.
    /// Freeze pieces have a tiny source slice and a factor close to zero,
    /// so the result stays inside `[srcStart, srcStart + slice]` throughout
    /// the hold — perfect for mapping the playhead back to "the frame
    /// that's frozen."
    private func previewCompTimeToSource(_ compTime: Double) -> Double {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: duration, cuts: cutSegments)
        let pieces = VideoSpeeds.pieces(keptRanges: kept,
                                          speeds: speedSegments,
                                          freezes: freezeSegments)
        var cursor: Double = 0
        for piece in pieces {
            let compDur = piece.compositionDuration
            let compEnd = cursor + compDur
            if compTime >= cursor && compTime < compEnd {
                return piece.srcStart + (compTime - cursor) * piece.factor
            }
            cursor = compEnd
        }
        // Past the end — clamp to the last piece's source end.
        if let last = pieces.last {
            return last.srcEnd
        }
        return compTime
    }

    /// Inverse of `previewCompTimeToSource`. Clamps to the nearest piece
    /// when `sourceTime` falls inside a cut (no piece covers it). For
    /// freeze pieces the mapping is ambiguous — any compTime inside the
    /// hold maps to the same sourceTime. We pick the start of the hold
    /// when the caller asks for that exact frame, which gives seek /
    /// scrub behaviour that feels natural.
    private func previewSourceTimeToComp(_ sourceTime: Double, against asset: AVAsset) -> Double {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: duration, cuts: cutSegments)
        let pieces = VideoSpeeds.pieces(keptRanges: kept,
                                          speeds: speedSegments,
                                          freezes: freezeSegments)
        var cursor: Double = 0
        for piece in pieces {
            if sourceTime < piece.srcStart {
                return cursor
            }
            if sourceTime <= piece.srcEnd {
                let within = sourceTime - piece.srcStart
                // Inverse of sourceTime = srcStart + compDelta * factor.
                let compDelta = piece.factor > 0 ? within / piece.factor : 0
                return cursor + compDelta
            }
            cursor += piece.compositionDuration
        }
        return cursor
    }

    /// True when the player's current item is a cut-stripped composition
    /// (so its clock no longer matches the source asset).
    private var previewUsesComposition = false

    /// Build an `AVMutableVideoComposition` driven by `EffectsVideoCompositor`.
    /// The compositor renders zoom + censor segments per frame via Core Image,
    /// so motion is smooth and blur/pixelate can coexist with zoom in a single
    /// pass.
    ///
    /// - Parameters:
    ///   - asset: Asset whose tracks are referenced (may be a composition).
    ///   - videoTrack: Specific track to instrument. Must belong to `asset`.
    ///     If nil, picks the first video track.
    ///   - renderSize: Output size. Pass nil to use the video track's natural
    ///     (orientation-applied) size.
    ///   - timeShift: Seconds to subtract from segment times to put them on
    ///     the composition's clock. Export sets this to `trimStart`.
    ///   - timeRangeDuration: Total composition length in seconds (composition
    ///     clock). Used for the instruction timeRange.
    /// Simple composition for the scale-only export path (no zoom, no censor).
    /// Applies preferredTransform + uniform scale via setTransform — cheap, no
    /// custom compositor cost.
    private func buildScaleOnlyComposition(videoTrack: AVAssetTrack, renderSize: CGSize, totalDuration: Double) -> AVMutableVideoComposition {
        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let scaleX = renderSize.width / abs(natSize.width)
        let scaleY = renderSize.height / abs(natSize.height)
        let transform = videoTrack.preferredTransform
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: totalDuration, preferredTimescale: 600))
        instruction.backgroundColor = NSColor.black.cgColor

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        let fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        return composition
    }

    /// Build an AVMutableVideoComposition backed by the custom effects
    /// compositor.
    ///
    /// - Parameters:
    ///   - asset: the asset (often an AVMutableComposition) whose track we
    ///     read. Its track IDs must match `videoTrack`.
    ///   - videoTrack: the specific track to read from.
    ///   - renderSize: nil means "use natural-size rendering."
    ///   - timeMap: composition-time → source-asset-time mapping. Callers
    ///     without cuts pass a single entry spanning the whole composition.
    ///   - timeRangeDuration: total length (in composition time) of the
    ///     instruction's timeRange.
    private func buildEffectsVideoComposition(for asset: AVAsset, videoTrack: AVAssetTrack?, renderSize: CGSize?, timeMap: [EffectsCompositionInstruction.TimeMapEntry], timeRangeDuration: Double) -> AVMutableVideoComposition? {
        let track = videoTrack ?? asset.tracks(withMediaType: .video).first
        guard let videoTrack = track else { return nil }
        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let naturalW = abs(natSize.width)
        let naturalH = abs(natSize.height)
        let renderW = renderSize?.width ?? naturalW
        let renderH = renderSize?.height ?? naturalH

        // Skip composition entirely when there's nothing to render — callers
        // should already guard on this, but being explicit avoids shipping a
        // custom compositor through the pipeline unnecessarily.
        //
        // Freezes also force the compositor on: their time-map entries scale
        // a 1/600s source slice to holdDuration seconds (factor ≈ 1/600),
        // which AVAssetExportSession can't handle via bare scaleTimeRange.
        // Routing through our compositor lets the time-map resolve comp time
        // back to source time frame-by-frame, producing a clean frame hold.
        guard !zoomSegments.isEmpty || !censorSegments.isEmpty || !freezeSegments.isEmpty || !textSegments.isEmpty else {
            return nil
        }

        // Bake orientation + scale into one transform. The compositor applies
        // it to the raw source buffer to produce a render-space CIImage.
        let scaleX = renderW / naturalW
        let scaleY = renderH / naturalH
        let baseTransform = videoTrack.preferredTransform
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Snapshot segments *by value* into plain arrays. The compositor runs
        // on background queues; we must not share main-actor state with it.
        let zoomSnapshot = zoomSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        let censorSnapshot = censorSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        // Build text snapshots: rasterize each visible text segment at its
        // render-pixel size, reusing cached images when the spec is
        // unchanged. The cache stays on the main actor; we hand the
        // background-safe `TextSnapshot` (CIImage + scalars) to the
        // compositor instruction.
        let textSnapshots = buildTextSnapshots(renderSize: CGSize(width: renderW, height: renderH),
                                                 naturalSize: CGSize(width: naturalW, height: naturalH))

        let instruction = EffectsCompositionInstruction(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: timeRangeDuration, preferredTimescale: 600)
            ),
            videoTrackID: videoTrack.trackID,
            naturalSize: CGSize(width: naturalW, height: naturalH),
            renderSize: CGSize(width: renderW, height: renderH),
            baseTransform: baseTransform,
            timeMap: timeMap,
            zoomSegments: zoomSnapshot,
            censorSegments: censorSnapshot,
            textSnapshots: textSnapshots
        )

        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsVideoCompositor.self
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: renderW, height: renderH)
        let fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        return composition
    }

    /// Convenience: build a single-entry time map from a scalar shift. All
    /// existing non-cut, non-speed callers use this — factor 1 means the
    /// piece plays at real time.
    private func singleShiftTimeMap(shift: Double, duration: Double) -> [EffectsCompositionInstruction.TimeMapEntry] {
        return [.init(compStart: 0, compEnd: duration, sourceStart: shift, factor: 1.0)]
    }

    /// Map composition-time → source-asset-time for the standard export path
    /// (trim + cuts + speed). `compositionDuration` is the composition's
    /// actual duration (after all three).
    private func timeMapForExport(compositionDuration: Double) -> [EffectsCompositionInstruction.TimeMapEntry] {
        let kept = VideoCuts.keptRanges(
            trimStart: trimStart,
            trimEnd: trimEnd,
            cuts: cutSegments
        )
        let pieces = VideoSpeeds.pieces(keptRanges: kept,
                                          speeds: speedSegments,
                                          freezes: freezeSegments)
        let entries = piecesToTimeMap(pieces: pieces)
        if entries.isEmpty {
            // Fall back to a passthrough single-entry map (should not happen
            // when the caller already has a non-zero composition duration).
            return singleShiftTimeMap(shift: trimStart, duration: compositionDuration)
        }
        return entries
    }

    /// Convert a list of pieces (kept ranges split by speed) into the
    /// compositor's `TimeMapEntry` array. Pieces are laid out contiguously
    /// on the composition clock in input order.
    private func piecesToTimeMap(pieces: [VideoSpeeds.Piece]) -> [EffectsCompositionInstruction.TimeMapEntry] {
        var entries: [EffectsCompositionInstruction.TimeMapEntry] = []
        var cursor: Double = 0
        for piece in pieces {
            let compDur = piece.compositionDuration
            guard compDur > 0 else { continue }
            entries.append(
                EffectsCompositionInstruction.TimeMapEntry(
                    compStart: cursor,
                    compEnd: cursor + compDur,
                    sourceStart: piece.srcStart,
                    factor: piece.factor
                )
            )
            cursor += compDur
        }
        return entries
    }

    /// The full set of speed segments currently owned by the effects band.
    /// Mirror of `cutSegments` / `zoomSegments` but for speed.
    private var speedSegments: [VideoSpeedSegment] { effectsBand?.speedSegments ?? [] }

    /// Freeze segments — point-in-time pauses. See `VideoFreezeSegment`.
    private var freezeSegments: [VideoFreezeSegment] { effectsBand?.freezeSegments ?? [] }

    /// Result of `buildProcessedComposition` — the composition plus the
    /// matching time-map and the video/audio comp tracks so callers can
    /// route a custom compositor at them.
    fileprivate struct ProcessedComposition {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack
        let audioTracks: [AVMutableCompositionTrack]
        let timeMap: [EffectsCompositionInstruction.TimeMapEntry]
        /// Composition-clock duration (after cuts + speed).
        let duration: Double
    }

    /// Build an AVMutableComposition that bakes in the current trim range,
    /// cut list and speed list. Audio tracks mirror the video so A/V stays
    /// in sync across cuts and speed changes.
    ///
    /// - Parameters:
    ///   - srcAsset: Original source asset (for its video/audio tracks).
    ///   - trimStartSec / trimEndSec: Effective trim range in source time.
    ///   - includeAudio: When false, no audio tracks are created.
    ///
    /// Returns nil if the source has no video track or the resulting
    /// composition would be empty.
    fileprivate func buildProcessedComposition(srcAsset: AVAsset,
                                                trimStartSec: Double,
                                                trimEndSec: Double,
                                                includeAudio: Bool) -> ProcessedComposition? {
        guard let srcVideoTrack = srcAsset.tracks(withMediaType: .video).first else { return nil }
        let comp = AVMutableComposition()
        guard let cvt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let srcAudio = srcAsset.tracks(withMediaType: .audio)
        var compAudio: [AVMutableCompositionTrack] = []
        if includeAudio {
            for _ in srcAudio {
                if let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    compAudio.append(a)
                }
            }
        }

        let kept = VideoCuts.keptRanges(
            trimStart: trimStartSec,
            trimEnd: trimEndSec,
            cuts: cutSegments
        )
        let pieces = VideoSpeeds.pieces(keptRanges: kept,
                                          speeds: speedSegments,
                                          freezes: freezeSegments)
        guard !pieces.isEmpty else { return nil }

        var cursor = CMTime.zero
        for piece in pieces {
            let srcRange = CMTimeRange(
                start: CMTime(seconds: piece.srcStart, preferredTimescale: 600),
                end: CMTime(seconds: piece.srcEnd, preferredTimescale: 600)
            )
            let compDur = CMTime(seconds: piece.compositionDuration, preferredTimescale: 600)
            let insertStart = cursor

            // Video — insert the source range, then (for non-1x pieces)
            // scale it to the piece's target composition duration. This
            // covers both speed and freeze: a freeze is just a very
            // tight slice scaled up a lot.
            try? cvt.insertTimeRange(srcRange, of: srcVideoTrack, at: insertStart)

            // Audio — mirror the video insert EXCEPT on freezes. A
            // freeze scaled up from a 1/600s slice would produce a
            // ~2-sample-long chirp stretched over a second — awful.
            // Skipping audio leaves a silent gap, which is what users
            // expect when a frame is paused.
            if piece.kind != .freeze {
                for (src, dst) in zip(srcAudio, compAudio) {
                    try? dst.insertTimeRange(srcRange, of: src, at: insertStart)
                }
            }

            // Apply time scaling after the inserts. `factor == 1` is a
            // no-op at the math level but we skip the call to dodge any
            // float-precision drift AVFoundation might introduce.
            if piece.factor != 1.0 {
                let inserted = CMTimeRange(start: insertStart, duration: srcRange.duration)
                cvt.scaleTimeRange(inserted, toDuration: compDur)
                if piece.kind != .freeze {
                    for dst in compAudio {
                        dst.scaleTimeRange(inserted, toDuration: compDur)
                    }
                }
            }
            cursor = CMTimeAdd(cursor, compDur)
        }

        return ProcessedComposition(
            composition: comp,
            videoTrack: cvt,
            audioTracks: compAudio,
            timeMap: piecesToTimeMap(pieces: pieces),
            duration: CMTimeGetSeconds(comp.duration)
        )
    }

    /// Fingerprint of the current cut+speed+freeze topology — used by the
    /// preview path to decide whether a player-item swap is needed.
    /// Changes to zoom/censor *rects* don't affect this, so those edits
    /// stay cheap.
    fileprivate func timelineTopologyFingerprint() -> String {
        let cuts = cutSegments
            .map { String(format: "c:%.4f-%.4f", $0.startTime, $0.endTime) }
            .sorted()
        let speeds = speedSegments
            .map { String(format: "s:%.4f-%.4f@%.3f", $0.startTime, $0.endTime, $0.speedFactor) }
            .sorted()
        let freezes = freezeSegments
            .map { String(format: "f:%.4f@%.3f", $0.atTime, $0.holdDuration) }
            .sorted()
        return (cuts + speeds + freezes).joined(separator: "|")
    }

    private func stepFrame(forward: Bool) {
        guard let player = player else { return }
        // Pause if playing
        if player.rate > 0 { player.pause(); needsDisplay = true }

        let fps = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30
        let frameDuration = 1.0 / Double(fps)
        let currentSource = mapPreviewClockToSourceTime(CMTimeGetSeconds(player.currentTime()))
        let targetSource = forward
            ? min(currentSource + frameDuration, trimEnd)
            : max(currentSource - frameDuration, trimStart)
        let target = mapSourceTimeToPreviewClock(targetSource)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - EffectsBandView integration

    /// Compute the scroll view's visible height for a given row count,
    /// capped at `effectsVisibleRowCount` rows so the editor window doesn't
    /// grow beyond a sensible limit. Matches `EffectsBandView.intrinsicContentSize`
    /// including its top/bottom padding so resize handles stay visible.
    fileprivate func effectsScrollViewHeight(forRowCount rows: Int) -> CGFloat {
        let visible = max(1, min(effectsVisibleRowCount, rows))
        // (visible × stride − gap) + 2× vertical inset (matches EffectsBandView.verticalInset = 4)
        return CGFloat(visible) * effectsRowStride - 2 + 8
    }

    // MARK: - Text segment rasterization (cached)

    /// Build per-segment text snapshots used by the compositor. Each visible
    /// text segment is rasterized once at its rect's pixel size; subsequent
    /// builds reuse the cached image when the spec hasn't changed.
    ///
    /// Performance: rasterization is a CGContext draw with a single
    /// NSAttributedString — sub-millisecond at typical sizes. It runs only
    /// when the spec changes (text typed, color/size/bg edited, rect
    /// resized, or render-size changed). Per-frame rendering then composites
    /// the cached CIImage with one transform + one composite.
    fileprivate func buildTextSnapshots(renderSize: CGSize,
                                          naturalSize: CGSize)
        -> [EffectsCompositionInstruction.TextSnapshot]
    {
        guard renderSize.width > 0, renderSize.height > 0 else { return [] }
        var snapshots: [EffectsCompositionInstruction.TextSnapshot] = []
        snapshots.reserveCapacity(textSegments.count)

        // Track which segment ids we still need so we can drop stale entries
        // (e.g. a segment was deleted) at the end.
        var liveIDs = Set<UUID>()

        for seg in textSegments where seg.endTime > seg.startTime {
            if seg.id == inlineTextEditingSegmentID {
                liveIDs.insert(seg.id)
                continue
            }
            // Pixel size of the segment's rect at the render resolution.
            // The rasterizer uses this to size the canvas; the per-frame
            // composite scales it 1:1 into render-space.
            let pxW = max(2, Int((seg.rect.width * renderSize.width).rounded()))
            let pxH = max(2, Int((seg.rect.height * renderSize.height).rounded()))
            let spec = VideoTextRasterizer.spec(for: seg,
                                                  pixelWidth: pxW,
                                                  pixelHeight: pxH,
                                                  renderHeight: Int(renderSize.height.rounded()))

            let cgImage: CGImage
            if let cached = textRasterCache[seg.id], cached.spec == spec {
                cgImage = cached.image
            } else {
                guard let rendered = VideoTextRasterizer.render(spec) else { continue }
                cgImage = rendered
                textRasterCache[seg.id] = (spec, rendered)
            }
            liveIDs.insert(seg.id)

            let ci = CIImage(cgImage: cgImage)
            snapshots.append(.init(id: seg.id,
                                    startTime: seg.startTime,
                                    endTime: seg.endTime,
                                    rect: seg.rect,
                                    fadeIn: seg.fadeIn,
                                    fadeOut: seg.fadeOut,
                                    image: ci))
        }

        // Evict cache entries for segments that no longer exist. Keeps the
        // dictionary's footprint bounded in long editing sessions.
        for key in Array(textRasterCache.keys) where !liveIDs.contains(key) {
            textRasterCache.removeValue(forKey: key)
        }

        return snapshots
    }

    // MARK: - Inline text editing

    /// Pop a borderless NSTextView at `viewRect` (in `hostView` coordinates)
    /// so the user can type the segment's contents in place. Player pauses
    /// while editing so the user isn't fighting against playback.
    fileprivate func beginInlineTextEdit(segmentID: UUID,
                                          atViewRect viewRect: NSRect,
                                          hostView: NSView) {
        guard let seg = textSegments.first(where: { $0.id == segmentID }) else { return }
        // Cancel any prior edit first.
        cancelInlineTextEdit(commit: false)

        // Pause playback during editing so AVPlayer doesn't drive the rect
        // out from under the text field.
        if let player = player, player.rate > 0 {
            player.pause()
            pausedForTextEdit = true
        }

        // Convert host-view coords to our (editor view's) coords so we can
        // place the field as a sibling of the player view.
        let frame = hostView.convert(viewRect, to: self)

        let displayedVideoHeight = frame.height / max(seg.rect.height, 0.0001)
        var editorFontSize = max(8, seg.fontSize * displayedVideoHeight / 1080)
        editorFontSize = min(editorFontSize, max(8, frame.height * 0.78))

        let font = inlineTextFont(for: seg, size: editorFontSize)
        let textColor = nsColor(seg.textColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsTextAlignment(for: seg.alignment)
        paragraph.lineBreakMode = .byTruncatingTail

        // Borderless scrollable text view sized to the segment rect. We use
        // NSTextView (not NSTextField) so multiline edits and large fonts
        // render predictably.
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = inlineTextBackgroundColor(for: seg)?.cgColor
        scroll.layer?.cornerRadius = inlineTextBackgroundRadius(for: seg, frame: frame)
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1.0).cgColor
        scroll.layer?.borderWidth = 1.5
        scroll.autoresizingMask = []
        scroll.contentView.drawsBackground = false

        let tv = InlineVideoTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.horizontalTextInset = max(2, editorFontSize * 0.18)
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = textColor
        tv.alignment = paragraph.alignment
        tv.defaultParagraphStyle = paragraph
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        tv.insertionPointColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1.0)
        tv.string = seg.text
        if let storage = tv.textStorage, storage.length > 0 {
            storage.addAttributes(tv.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        tv.centerTextVertically()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.delegate = self

        scroll.documentView = tv
        addSubview(scroll)

        inlineTextEditor = tv
        inlineTextEditorScrollView = scroll
        inlineTextEditingSegmentID = segmentID
        applyZoomTransformForCurrentTime()
        window?.makeFirstResponder(tv)
    }

    fileprivate func commitInlineTextEdit() {
        guard let id = inlineTextEditingSegmentID,
              let tv = inlineTextEditor,
              let seg = textSegments.first(where: { $0.id == id }) else {
            cancelInlineTextEdit(commit: false)
            return
        }
        let newText = tv.string
        let changed = newText != seg.text
        if changed {
            seg.text = newText
            // Drop the cache for this segment so the next composition
            // rebuild re-rasterizes with the new text.
            textRasterCache.removeValue(forKey: id)
            savedURL = nil
        }
        cancelInlineTextEdit(commit: false)
        if changed {
            effectsBand?.refreshAfterParentEdit()
        }
    }

    fileprivate func cancelInlineTextEdit(commit: Bool) {
        if commit {
            commitInlineTextEdit()
            return
        }
        let wasEditing = inlineTextEditingSegmentID != nil
        inlineTextEditorScrollView?.removeFromSuperview()
        inlineTextEditor = nil
        inlineTextEditorScrollView = nil
        inlineTextEditingSegmentID = nil
        if pausedForTextEdit {
            pausedForTextEdit = false
        }
        window?.makeFirstResponder(self)
        if wasEditing {
            applyZoomTransformForCurrentTime()
        }
        needsDisplay = true
    }

    private func nsColor(_ rgba: VideoTextSegment.RGBA) -> NSColor {
        NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    private func nsTextAlignment(for alignment: VideoTextSegment.Alignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private func inlineTextFont(for seg: VideoTextSegment, size: CGFloat) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if seg.bold { traits.insert(.bold) }
        if seg.italic { traits.insert(.italic) }

        let base = NSFont.systemFont(ofSize: size, weight: seg.bold ? .bold : .regular)
        if !traits.isEmpty {
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
            if let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
        }
        return base
    }

    private func inlineTextBackgroundColor(for seg: VideoTextSegment) -> NSColor? {
        switch seg.bgStyle {
        case .none:
            return nil
        case .solid, .rounded:
            return nsColor(seg.bgColor)
        }
    }

    private func inlineTextBackgroundRadius(for seg: VideoTextSegment, frame: NSRect) -> CGFloat {
        switch seg.bgStyle {
        case .none, .solid:
            return 0
        case .rounded:
            let shortSide = min(frame.width, frame.height)
            return min(shortSide * 0.25, frame.height * 0.30)
        }
    }

    // MARK: - Custom color picker

    /// Open NSColorPanel and bind it to the given segment's text or bg
    /// color field. The panel stays modal-less so the user can keep
    /// editing other things; we observe `colorDidChange` notifications
    /// while it's relevant and unbind on close.
    fileprivate func presentTextColorPicker(segmentID: UUID, isBackground: Bool) {
        guard textSegments.contains(where: { $0.id == segmentID }) else { return }
        textColorPickerSegmentID = segmentID
        textColorPickerIsBackground = isBackground
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        if let seg = textSegments.first(where: { $0.id == segmentID }) {
            let rgba = isBackground ? seg.bgColor : seg.textColor
            panel.color = NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        }
        // Hook up the action target. Reuse a single observer per editor.
        panel.setTarget(self)
        panel.setAction(#selector(textColorPanelDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func textColorPanelDidChange(_ sender: NSColorPanel) {
        guard let id = textColorPickerSegmentID,
              let seg = textSegments.first(where: { $0.id == id }) else { return }
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let rgba = VideoTextSegment.RGBA(
            r: Double(c.redComponent),
            g: Double(c.greenComponent),
            b: Double(c.blueComponent),
            a: Double(c.alphaComponent))
        if textColorPickerIsBackground {
            seg.bgColor = rgba
        } else {
            seg.textColor = rgba
        }
        textRasterCache.removeValue(forKey: id)
        savedURL = nil
        applyZoomTransformForCurrentTime()
        effectsBand?.refreshAfterParentEdit()
    }
}

extension VideoEditorView: EffectsBandViewDelegate {
    func effectsBandDidMutate(_ view: EffectsBandView) {
        savedURL = nil
        applyZoomTransformForCurrentTime()
        refreshHeaderInfo()
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, didSelectSegment segmentID: UUID?) {
        updateEffectsOverlay()
        refreshInspector()
    }

    func effectsBand(_ view: EffectsBandView, didChangeRowCount rowCount: Int) {
        currentEffectRowCount = rowCount
        let newScrollH = effectsScrollViewHeight(forRowCount: rowCount)
        effectsBandHeightConstraint?.animator().constant = newScrollH
        // Player view also shrinks so the whole controls band (including the
        // trim timeline) has room to grow upward.
        playerBottomConstraint?.animator().constant = -(controlsH + effectToolbarHeight + transportHeight + 6)
        needsLayout = true
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, showStatus message: String, isError: Bool) {
        showStatus(message, isError: isError)
    }

    func effectsBandDidRequestTextEdit(_ view: EffectsBandView, segmentID: UUID) {
        // Reposition the overlay first so the rect we read is accurate for
        // the current selection state.
        updateEffectsOverlay()
        guard let overlay = effectsOverlay,
              let seg = textSegments.first(where: { $0.id == segmentID }) else { return }
        let viewRect = overlay.viewRectFromNormalized(seg.rect)
        beginInlineTextEdit(segmentID: segmentID, atViewRect: viewRect, hostView: overlay)
    }

    func effectsBandDidRequestTextColorPick(_ view: EffectsBandView,
                                              segmentID: UUID,
                                              isBackground: Bool) {
        presentTextColorPicker(segmentID: segmentID, isBackground: isBackground)
    }
}

extension VideoEditorView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return commits, Escape cancels. Allow Shift+Return for newlines so
        // multi-line text labels stay possible without leaving the editor.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineTextEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineTextEdit(commit: false)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        // Re-rasterize on every keystroke would burn CPU; instead, cache
        // invalidation happens at commit time. The user sees the new text
        // appear in the inline NSTextView itself while typing — the rasterized
        // overlay just stays at its previous content until commit.
    }

    func textDidEndEditing(_ notification: Notification) {
        // Lost focus → commit. Matches Finder rename behavior.
        commitInlineTextEdit()
    }
}

private final class InlineVideoTextView: NSTextView {
    var horizontalTextInset: CGFloat = 0 {
        didSet { centerTextVertically() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerTextVertically()
    }

    override func didChangeText() {
        super.didChangeText()
        centerTextVertically()
    }

    func centerTextVertically() {
        guard let container = textContainer, let manager = layoutManager else {
            textContainerInset = NSSize(width: horizontalTextInset, height: 0)
            return
        }
        manager.ensureLayout(for: container)
        let usedHeight = manager.usedRect(for: container).height
        let verticalInset = max(0, floor((bounds.height - usedHeight) / 2))
        textContainerInset = NSSize(width: horizontalTextInset, height: verticalInset)
    }
}

private extension CMSampleBuffer {
    /// Returns a copy with a new presentation timestamp. Duration is preserved.
    func retimed(presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(self),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: self,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }
}

// MARK: - V3 video editor controls

/// Flipped so inspector content starts at the top of its scroll view.
private final class VideoInspectorStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// Timeline toolbar action (`.ttb .a`): borderless icon + label with hover fill.
private final class VideoToolbarButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?
    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 12.5)
        contentTintColor = .secondaryLabelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 18, height: 28)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            VideoEditorView.fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// White 40pt round play / pause button (`.transport .play`).
private final class VideoTransportPlayButton: NSButton {
    var isPlaying: (() -> Bool)?
    convenience init(target: AnyObject?, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(isHighlighted ? 0.8 : 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let name = (isPlaying?() ?? false) ? "pause.fill" : "play.fill"
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r); NSColor(white: 0.07, alpha: 1).setFill(); r.fill(using: .sourceAtop); return true
        }
        let dx: CGFloat = name == "play.fill" ? 1.5 : 0
        tinted.draw(in: NSRect(x: bounds.midX - symbol.size.width / 2 + dx, y: bounds.midY - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Inspector choice chip (`.chs span`, `.on` = selected).
private final class VideoChipButton: NSButton {
    var isOn = false { didSet { needsDisplay = true } }
    private let chipFont = NSFont.systemFont(ofSize: 12)
    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        let width = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 20
        frame.size = NSSize(width: width, height: 26)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if isOn {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); path.fill()
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 1; path.stroke()
        } else {
            VideoEditorView.fill.setFill(); path.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: isOn ? NSFont.systemFont(ofSize: 12, weight: .semibold) : chipFont,
            .foregroundColor: isOn ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

private final class VideoChipGroup: NSView {
    override var isFlipped: Bool { true }
    func layoutChips(width: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0
        for chip in subviews {
            if x + chip.frame.width > width, x > 0 { x = 0; y += 32 }
            chip.frame.origin = NSPoint(x: x, y: y)
            x += chip.frame.width + 6
        }
        frame.size = NSSize(width: width, height: y + 26)
    }
}
