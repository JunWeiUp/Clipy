import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// Application boundary for the independently implemented capture flow.
/// One temporary capture, long screenshot or recording session may be active.
@MainActor
final class NativeScreenshotCoordinator {
    static let shared = NativeScreenshotCoordinator()

    private var overlay: NativeScreenshotOverlayController?
    private var detachedEditor: NativeScreenshotEditorController?
    private var scrollSession: NativeScreenshotScrollingCaptureSession?
    private var scrollHUD: NativeScreenshotLongCaptureHUD?
    private var scrollPollTask: Task<Void, Never>?
    private var scrollCompletionID: UUID?
    private var recorder: NativeScreenshotRecorder?
    private var recordingHUD: NativeScreenshotRecordingHUD?
    private var recordingSessionID: UUID?
    private var recordingStarted = false

    private init() {}

    func startCapture(mode: NativeScreenshotSelectionMode, fromMenu: Bool = false) {
        guard overlay == nil, scrollSession == nil, recordingSessionID == nil else { return }
        let callbacks = NativeScreenshotOverlayCallbacks(
            onConfirm: { [weak self] image in self?.finishOverlay(); self?.deliver(image) },
            onCancel: { [weak self] in self?.finishOverlay() },
            onRecordingRequested: { [weak self] rect in
                self?.finishOverlay()
                Task { @MainActor [weak self] in await self?.startRecording(region: rect) }
            },
            onScrollingRequested: { [weak self] rect in
                self?.finishOverlay()
                Task { @MainActor [weak self] in await self?.startScrolling(region: rect) }
            },
            onOCRRequested: { [weak self] image in
                self?.finishOverlay()
                self?.showRecognition(for: image)
            },
            onQRCodeRequested: { [weak self] image in
                self?.finishOverlay()
                self?.showRecognition(for: image)
            },
            onAutoRedactRequested: { [weak self] image in
                self?.finishOverlay()
                self?.showRecognition(for: image)
            },
            onPinRequested: { [weak self] image in
                self?.finishOverlay()
                self?.deliver(image, action: .pin)
            },
            onSaveRequested: { [weak self] image in
                self?.finishOverlay()
                self?.deliver(image, action: .saveAs)
            },
            onQuickCapture: { [weak self] image, mode in
                self?.finishOverlay()
                self?.deliverQuick(image, mode: mode)
            },
            onError: { [weak self] error in
                self?.finishOverlay()
                self?.showCaptureError(error)
            }
        )
        let controller = NativeScreenshotOverlayController(mode: mode, callbacks: callbacks)
        overlay = controller
        Task { await controller.start() }
    }

    func openEditor(image: NSImage) {
        do {
            let cg = try NativeScreenshotImageProcessor.cgImage(from: image)
            openEditor(NativeScreenshotCapturedImage(
                image: cg,
                sourceRect: CGRect(origin: .zero, size: image.size),
                pixelsPerPoint: 1
            ))
        } catch {
            showError(error)
        }
    }

    func cancelActiveSession() {
        overlay?.cancel()
        overlay = nil
        cancelScrolling()
        Task { await cancelRecording() }
        detachedEditor?.close()
        detachedEditor = nil
        NativeScreenshotThumbnailPresenter.shared.dismissAll()
    }

    private func finishOverlay() { overlay = nil }

    private func openEditor(_ image: NativeScreenshotCapturedImage) {
        detachedEditor?.close()
        let editor = NativeScreenshotEditorController(
            base: image,
            onAction: { [weak self] action, edited in
                self?.detachedEditor?.close()
                self?.detachedEditor = nil
                self?.handleEditorAction(action, image: edited)
            },
            onCancel: { [weak self] in self?.detachedEditor = nil }
        )
        detachedEditor = editor
        editor.show()
    }

    private func handleEditorAction(
        _ action: NativeScreenshotDeliveryAction,
        image: NativeScreenshotCapturedImage
    ) {
        switch action {
        case .confirm: deliver(image)
        case .ocr, .qrCode, .autoRedact: showRecognition(for: image)
        case .pin: deliver(image, action: .pin)
        case .save: deliver(image, action: .saveAs)
        }
    }

    private func deliver(
        _ image: NativeScreenshotCapturedImage,
        action: ScreenshotPostCaptureAction? = nil
    ) {
        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let output = try await self.imageForDelivery(image)
                let delivery = try await NativeScreenshotDeliveryService.deliver(
                    output, action: action
                )
                self.showThumbnail(for: output, png: delivery.historyPNG)
                if PreferencesManager.shared.playCopySound {
                    NSSound(named: NSSound.Name("Tink"))?.play()
                }
                MemoryFootprintReclaimer.scheduleDelayedReclaim()
            } catch NativeScreenshotDeliveryService.DeliveryError.saveCancelled {
                return
            } catch {
                self?.showError(error)
            }
        }
    }

    private func imageForDelivery(
        _ captured: NativeScreenshotCapturedImage
    ) async throws -> NativeScreenshotCapturedImage {
        guard PreferencesManager.shared.screenshotResolution.shouldDownscaleRetina(
                  PreferencesManager.shared.downscaleRetina),
              captured.pixelsPerPoint > 1.01 else { return captured }
        let scale = captured.pixelsPerPoint
        let image = captured.image
        let target = CGSize(
            width: max(1, (CGFloat(image.width) / scale).rounded()),
            height: max(1, (CGFloat(image.height) / scale).rounded())
        )
        let reduced = try await Task.detached(priority: .userInitiated) {
            try NativeScreenshotImageEditor.resize(image, to: target)
        }.value
        return NativeScreenshotCapturedImage(
            image: reduced, sourceRect: captured.sourceRect, pixelsPerPoint: 1
        )
    }

    private func deliverQuick(_ image: NativeScreenshotCapturedImage, mode: Int) {
        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let output = try await self.imageForDelivery(image)
                let delivery = try await NativeScreenshotDeliveryService.deliverQuick(
                    output, mode: mode
                )
                if mode == 3 || PreferencesManager.shared.showFloatingThumbnail {
                    self.showThumbnail(for: output, png: delivery.historyPNG,
                                       force: mode == 3)
                }
                if (mode == 1 || mode == 2) && PreferencesManager.shared.playCopySound {
                    NSSound(named: NSSound.Name("Tink"))?.play()
                }
                MemoryFootprintReclaimer.scheduleDelayedReclaim()
            } catch { self?.showError(error) }
        }
    }

    private func showThumbnail(
        for image: NativeScreenshotCapturedImage,
        png: Data,
        force: Bool = false
    ) {
        // The card keeps only compressed PNG bytes. Decode a full bitmap only
        // after a user chooses an action, so four large previews do not retain
        // four uncompressed screenshots while the cards are visible.
        let sourceRect = image.sourceRect
        let pixelScale = image.pixelsPerPoint
        NativeScreenshotThumbnailPresenter.shared.present(
            image: image.image,
            actions: .init(
                copy: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(png, forType: .png)
                },
                save: { [weak self] in
                    Task { @MainActor in
                        do {
                            let decoded = try await Task.detached(priority: .userInitiated) {
                                try nativeScreenshotDecodePNG(png)
                            }.value
                            _ = try await NativeScreenshotDeliveryService.saveOnly(decoded)
                        }
                        catch NativeScreenshotDeliveryService.DeliveryError.saveCancelled { return }
                        catch { self?.showError(error) }
                    }
                },
                pin: {
                    Task { @MainActor in
                        guard let decoded = try? await Task.detached(
                            priority: .userInitiated,
                            operation: { try nativeScreenshotDecodePNG(png) }
                        ).value else { return }
                        let nsImage = NSImage(
                            cgImage: decoded,
                            size: NSSize(width: decoded.width, height: decoded.height)
                        )
                        PinPanelController.shared.pin(image: nsImage, skipIngest: true)
                    }
                },
                edit: { [weak self] in
                    Task { @MainActor in
                        do {
                            let decoded = try await Task.detached(priority: .userInitiated) {
                                try nativeScreenshotDecodePNG(png)
                            }.value
                            self?.openEditor(NativeScreenshotCapturedImage(
                                image: decoded, sourceRect: sourceRect,
                                pixelsPerPoint: pixelScale
                            ))
                        } catch { self?.showError(error) }
                    }
                }
            ),
            force: force,
            estimatedBytes: png.count
        )
    }

    private func showRecognition(for image: NativeScreenshotCapturedImage) {
        NativeScreenshotRecognitionWindowController.open(
            image: image.image,
            language: PreferencesManager.shared.screenshotOCRLanguage,
            onRedactedImage: { [weak self] covered in
                self?.deliver(NativeScreenshotCapturedImage(
                    image: covered,
                    sourceRect: image.sourceRect,
                    pixelsPerPoint: image.pixelsPerPoint
                ), action: .copy)
            }
        )
    }

    private func startScrolling(region: CGRect) async {
        let hud = NativeScreenshotLongCaptureHUD()
        let preferences = PreferencesManager.shared
        let options = NativeScreenshotScrollingCaptureSession.Options(
            maximumHeight: preferences.scrollMaxHeight,
            maximumPixels: 100_000_000,
            autoScrollSpeed: preferences.scrollAutoScrollSpeed,
            detectFrozenEdges: preferences.scrollFrozenDetection,
            showsCursor: preferences.captureCursor
        )
        let session = NativeScreenshotScrollingCaptureSession(
            region: region,
            options: options,
            beforeFrame: { [weak hud] in
                hud?.hideForFrame()
                try? await Task.sleep(nanoseconds: 80_000_000)
            },
            afterFrame: { [weak hud] in hud?.restoreAfterFrame() }
        )
        scrollSession = session
        scrollHUD = hud
        hud.onStop = { [weak self] in self?.finishScrolling() }
        hud.onCancel = { [weak self] in self?.cancelScrolling() }
        hud.show()
        do {
            let first = try await session.start()
            guard scrollSession === session else { return }
            hud.updatePreview(first, addedRows: nil)
            if preferences.scrollAutoScrollEnabled {
                do {
                    try session.startAutomaticScroll(
                        onFrame: { [weak self] result, preview in
                            self?.handleScrollFrame(result, preview: preview)
                        },
                        onError: { [weak self] error in self?.showError(error) },
                        onReachedEnd: { [weak self] in self?.finishScrolling() }
                    )
                } catch NativeScreenshotScrollingCaptureSession.SessionError
                    .automaticScrollNeedsAccessibility {
                    hud.setStatus(NativeScreenshotUserText.string(
                        "自动滚动需要辅助功能权限，可手动滚动。",
                        "Auto scroll needs Accessibility permission; scroll manually."))
                    startManualScrollPolling(session)
                }
            } else {
                startManualScrollPolling(session)
            }
        } catch {
            guard scrollSession === session else { return }
            cancelScrolling()
            showCaptureError(error)
        }
    }

    private func startManualScrollPolling(
        _ session: NativeScreenshotScrollingCaptureSession
    ) {
        scrollPollTask = Task { @MainActor [weak self] in
            var appendedContent = false
            var idleFrames = 0
            while !Task.isCancelled, self?.scrollSession === session {
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { break }
                do {
                    let (result, preview) = try await session.captureNext()
                    guard self?.scrollSession === session else { break }
                    self?.handleScrollFrame(result, preview: preview)
                    switch result {
                    case .appended:
                        appendedContent = true
                        idleFrames = 0
                    case .noMovement:
                        idleFrames += 1
                        if appendedContent && idleFrames >= 15 {
                            self?.finishScrolling()
                            return
                        }
                        if !appendedContent && idleFrames >= 46 {
                            self?.cancelScrolling()
                            self?.showError(NSError(
                                domain: "ClipyClone.NativeScreenshot", code: 1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    NativeScreenshotUserText.string(
                                        "页面没有滚动，已取消长截图。",
                                        "The page did not scroll. Long capture was cancelled.")]
                            ))
                            return
                        }
                    case .uncertainOverlap:
                        idleFrames = 0
                    case .heightLimit:
                        return
                    }
                } catch is CancellationError {
                    break
                } catch {
                    self?.showError(error)
                    break
                }
            }
        }
    }

    private func handleScrollFrame(
        _ result: NativeScreenshotScrollAssembler.AppendResult,
        preview: CGImage?
    ) {
        switch result {
        case .appended(let rows):
            if let preview { scrollHUD?.updatePreview(preview, addedRows: rows) }
        case .noMovement:
            scrollHUD?.setStatus(NativeScreenshotUserText.string(
                "等待页面滚动…", "Waiting for page movement…"))
        case .uncertainOverlap:
            scrollHUD?.setStatus(NativeScreenshotUserText.string(
                "拼接位置不确定，请放慢滚动速度。",
                "Alignment uncertain. Scroll more slowly."))
        case .heightLimit:
            scrollHUD?.setStatus(NativeScreenshotUserText.string(
                "已达到最大高度", "Maximum height reached"))
            finishScrolling()
        }
    }

    private func finishScrolling() {
        scrollPollTask?.cancel()
        scrollPollTask = nil
        guard let session = scrollSession else { return }
        scrollSession = nil
        let completionID = UUID()
        scrollCompletionID = completionID
        let hud = scrollHUD
        hud?.setStatus(NativeScreenshotUserText.string(
            "正在生成长截图…", "Rendering long screenshot…"))
        Task { @MainActor [weak self] in
            do {
                let result = try await session.finish()
                guard self?.scrollCompletionID == completionID else { return }
                self?.scrollCompletionID = nil
                self?.scrollHUD = nil
                hud?.close()
                self?.deliver(NativeScreenshotCapturedImage(
                    image: result, sourceRect: CGRect(origin: .zero,
                                                      size: CGSize(width: result.width,
                                                                   height: result.height)),
                    pixelsPerPoint: 1
                ))
            } catch {
                guard self?.scrollCompletionID == completionID else { return }
                self?.scrollCompletionID = nil
                self?.scrollHUD = nil
                hud?.close()
                self?.showError(error)
            }
        }
    }

    private func cancelScrolling() {
        scrollCompletionID = nil
        scrollPollTask?.cancel()
        scrollPollTask = nil
        scrollSession?.cancel()
        scrollSession = nil
        scrollHUD?.close()
        scrollHUD = nil
    }

    private func startRecording(region: CGRect) async {
        guard recordingSessionID == nil else { return }
        let sessionID = UUID()
        recordingSessionID = sessionID
        recordingStarted = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard recordingSessionID == sessionID else { return }
            guard let display = content.displays.max(by: {
                $0.frame.intersection(region).area < $1.frame.intersection(region).area
            }), !display.frame.intersection(region).isEmpty else {
                throw NativeScreenshotRecordingError.displayUnavailable
            }
            let overlappingDisplays = content.displays.filter {
                $0.frame.intersection(region).area > 1
            }
            guard overlappingDisplays.count == 1,
                  display.frame.contains(region) else {
                throw NSError(
                    domain: "ClipyClone.NativeScreenshot", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        NativeScreenshotUserText.string(
                            "录屏选区必须位于同一台显示器内。请缩小选区后重试。",
                            "The recording region must fit on one display. Select a smaller area and try again.")]
                )
            }
            let local = region.intersection(display.frame)
                .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let outputURL = try newRecordingURL()
            let preferences = PreferencesManager.shared
            let hud = NativeScreenshotRecordingHUD(showTimer: !preferences.hideRecordingHUD)
            recordingHUD = hud
            hud.onStop = { [weak self] in Task { @MainActor in await self?.stopRecording() } }
            hud.onCancel = { [weak self] in Task { @MainActor in await self?.cancelRecording() } }
            hud.show()
            let refreshed = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard recordingSessionID == sessionID else { return }
            let excluded = refreshed.windows.filter {
                $0.windowID == CGWindowID(hud.window.windowNumber)
            }
            guard !excluded.isEmpty else {
                throw NativeScreenshotRecordingError.captureUnavailable
            }
            let options = NativeScreenshotRecordingOptions(
                displayID: display.displayID,
                sourceRect: local,
                outputURL: outputURL,
                framesPerSecond: preferences.recordingFPS,
                includesSystemAudio: preferences.recordSystemAudio,
                includesMicrophone: preferences.recordMicAudio,
                highlightsMouseClicks: preferences.recordMouseHighlight,
                webcam: preferences.recordWebcam ? webcamOptions(preferences) : nil,
                keystrokeMode: !preferences.recordKeystroke ? .off
                    : (preferences.keystrokeShowAll ? .allKeys : .shortcutsOnly)
            )
            let recorder = NativeScreenshotRecorder(options: options,
                                                    excludedWindows: excluded)
            self.recorder = recorder
            recorder.onAutomaticStop = { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.recordingEnded(result, sessionID: sessionID)
                }
            }
            recorder.onCameraUnavailable = { [weak self, weak hud] in
                Task { @MainActor [weak self, weak hud] in
                    guard self?.recordingSessionID == sessionID else { return }
                    hud?.addWarning(NativeScreenshotUserText.string(
                        "摄像头已断开，后续画面不再包含摄像头。",
                        "Camera disconnected; the remaining video will not include it."))
                }
            }
            try await recorder.start()
            guard recordingSessionID == sessionID else {
                await recorder.cancel()
                return
            }
            recordingStarted = true
            if !recorder.warnings.isEmpty {
                appLog(recorder.warnings.joined(separator: " | "), level: .warning)
                showRecordingWarnings(recorder.warnings, on: hud)
            }
        } catch {
            guard recordingSessionID == sessionID else { return }
            await cancelRecording()
            showCaptureError(error)
        }
    }

    private func webcamOptions(
        _ preferences: PreferencesManager
    ) -> NativeScreenshotRecordingOptions.Webcam {
        typealias Webcam = NativeScreenshotRecordingOptions.Webcam
        let position: Webcam.Position
        switch preferences.webcamPosition {
        case "topLeft": position = .topLeft
        case "topRight": position = .topRight
        case "bottomLeft": position = .bottomLeft
        default: position = .bottomRight
        }
        let size: Webcam.Size
        switch preferences.webcamSize {
        case "small": size = .small
        case "large": size = .large
        case "xlarge": size = .extraLarge
        default: size = .medium
        }
        let shape: Webcam.Shape = preferences.webcamShape == "roundedRect"
            ? .roundedRectangle : .circle
        return Webcam(position: position, size: size, shape: shape)
    }

    private func showRecordingWarnings(
        _ warnings: [String], on hud: NativeScreenshotRecordingHUD
    ) {
        var missingChinese: [String] = []
        var missingEnglish: [String] = []
        if warnings.contains(where: { $0.contains("麦克风") }) {
            missingChinese.append("麦克风")
            missingEnglish.append("microphone")
        }
        if warnings.contains(where: { $0.contains("摄像头") }) {
            missingChinese.append("摄像头")
            missingEnglish.append("camera")
        }
        if warnings.contains(where: { $0.contains("鼠标点击") }) {
            missingChinese.append("鼠标点击高亮")
            missingEnglish.append("click highlight")
        }
        if warnings.contains(where: { $0.contains("按键") }) {
            missingChinese.append("按键显示")
            missingEnglish.append("keystroke display")
        }
        guard !missingChinese.isEmpty else {
            hud.addWarning(NativeScreenshotUserText.string(
                "部分录制输入不可用，请检查权限。",
                "Some recording inputs are unavailable; check permissions."))
            return
        }
        hud.addWarning(NativeScreenshotUserText.string(
            "未录入：\(missingChinese.joined(separator: "、"))；录制仍在进行。",
            "Missing: \(missingEnglish.joined(separator: ", ")); recording continues."))
    }

    private func stopRecording() async {
        guard let recorder, let sessionID = recordingSessionID,
              recordingStarted else {
            await cancelRecording()
            return
        }
        self.recorder = nil
        do {
            let url = try await recorder.stop()
            recordingEnded(.success(url), sessionID: sessionID)
        } catch { recordingEnded(.failure(error), sessionID: sessionID) }
    }

    private func recordingEnded(_ result: Result<URL, Error>, sessionID: UUID) {
        guard recordingSessionID == sessionID else {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }
        recordingSessionID = nil
        recordingStarted = false
        recorder = nil
        recordingHUD?.close()
        recordingHUD = nil
        switch result {
        case .success(let url):
            NativeScreenshotRecordingDeliveryService.deliver(
                url, action: PreferencesManager.shared.recordingOnStop
            )
        case .failure(let error): showError(error)
        }
    }

    private func cancelRecording() async {
        recordingSessionID = nil
        recordingStarted = false
        let recorder = self.recorder
        self.recorder = nil
        recordingHUD?.close()
        recordingHUD = nil
        await recorder?.cancel()
    }

    private func newRecordingURL() throws -> URL {
        let directory = PreferencesManager.shared.screenshotSaveDirectory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let name = ScreenshotSaveService.defaultFilename()
        var url = directory.appendingPathComponent(name).appendingPathExtension("mp4")
        var index = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)-\(index)")
                .appendingPathExtension("mp4")
            index += 1
        }
        return url
    }

    private func showCaptureError(_ error: Error) {
        if !ScreenCapturePermissionManager.isAuthorized {
            let alert = NSAlert()
            alert.messageText = NativeScreenshotUserText.string(
                "需要屏幕录制权限", "Screen Recording permission required")
            alert.informativeText = NativeScreenshotUserText.string(
                "请在系统设置中允许 Clipy 录制屏幕，然后重新尝试。",
                "Allow Clipy to record the screen in System Settings, then try again.")
            alert.addButton(withTitle: NativeScreenshotUserText.string(
                "打开系统设置", "Open System Settings"))
            alert.addButton(withTitle: NativeScreenshotUserText.string("取消", "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                ScreenCapturePermissionManager.openSettings()
            }
            return
        }
        showError(error)
    }

    private func showError(_ error: Error) {
        appLog("Screenshot: \(error.localizedDescription)", level: .error)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}

private enum NativeScreenshotDecodeError: Error { case invalidPNG }

private func nativeScreenshotDecodePNG(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NativeScreenshotDecodeError.invalidPNG
    }
    return image
}
