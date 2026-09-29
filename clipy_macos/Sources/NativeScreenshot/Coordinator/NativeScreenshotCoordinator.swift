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
    private var scrollModeSwitchTask: Task<Void, Never>?
    private var scrollCaptureReady = false
    private var scrollCompletionID: UUID?
    private var recorder: NativeScreenshotRecorder?
    private var recordingSetup: NativeScreenshotRecordingSetupPanel?
    private var recordingRegion: CGRect?
    private var recordingDisplayID: CGDirectDisplayID?
    private var recordingSetupGeneration: UInt64 = 0
    private var recordingCountdown: NativeScreenshotRecordingCountdownHUD?
    private var recordingHUD: NativeScreenshotRecordingHUD?
    private var recordingSessionID: UUID?
    private var recordingStarted = false
    private var recordingPaused = false
    private var recordingFinalizing = false
    private var recordingControlsHidden = false
    private var recordingWarningHideTask: Task<Void, Never>?
    private var captureHandoffID: UUID?

    private init() {}

    var hasActiveRecording: Bool { recordingSessionID != nil }
    var hasStartedRecording: Bool { recordingSessionID != nil && recordingStarted }
    var isRecordingPaused: Bool { recordingPaused }
    var isRecordingFinalizing: Bool { recordingFinalizing }

    func stopRecordingFromMenu() {
        Task { await stopRecording() }
    }

    func cancelRecordingFromMenu() {
        Task { await cancelRecording() }
    }

    func toggleRecordingPauseFromMenu() {
        toggleRecordingPause()
    }

    func startCapture(mode: NativeScreenshotSelectionMode, fromMenu: Bool = false) {
        guard overlay == nil, scrollSession == nil, scrollCompletionID == nil,
              captureHandoffID == nil,
              recordingSetup == nil, recordingSessionID == nil else { return }
        let callbacks = NativeScreenshotOverlayCallbacks(
            onConfirm: { [weak self] image in self?.finishOverlay(); self?.deliver(image) },
            onCancel: { [weak self] in
                self?.recordingSetupGeneration &+= 1
                self?.recordingSetup?.close()
                self?.recordingSetup = nil
                self?.recordingRegion = nil
                self?.recordingDisplayID = nil
                self?.finishOverlay()
            },
            onRecordingRequested: { [weak self] rect in
                self?.queueRecordingSetup(region: rect)
            },
            onScrollingRequested: { [weak self] rect in
                guard let self else { return }
                let handoffID = UUID()
                self.captureHandoffID = handoffID
                self.finishOverlay()
                Task { @MainActor [weak self] in
                    await self?.startScrolling(region: rect, handoffID: handoffID)
                }
            },
            onOCRRequested: { [weak self] image in
                self?.finishOverlay()
                self?.showRecognition(for: image, initialIntent: .text)
            },
            onQRCodeRequested: { [weak self] image in
                self?.finishOverlay()
                self?.showRecognition(for: image, initialIntent: .qrCode)
            },
            onAutoRedactRequested: { [weak self] image in
                self?.finishOverlay()
                self?.showRecognition(for: image, initialIntent: .redact)
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
                self?.recordingSetupGeneration &+= 1
                self?.recordingSetup?.close()
                self?.recordingSetup = nil
                self?.recordingRegion = nil
                self?.recordingDisplayID = nil
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
        captureHandoffID = nil
        overlay?.cancel()
        overlay = nil
        cancelScrolling()
        recordingSetup?.close()
        recordingSetup = nil
        recordingRegion = nil
        recordingDisplayID = nil
        recordingSetupGeneration &+= 1
        recordingCountdown?.close()
        recordingCountdown = nil
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
        case .ocr: showRecognition(for: image, initialIntent: .text)
        case .qrCode: showRecognition(for: image, initialIntent: .qrCode)
        case .autoRedact: showRecognition(for: image, initialIntent: .redact)
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
        let pinRect = Self.appKitPinRect(for: sourceRect)
        NativeScreenshotThumbnailPresenter.shared.present(
            image: image.image,
            actions: .init(
                copy: { currentPNG in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(currentPNG, forType: .png)
                },
                save: { [weak self] currentPNG in
                    Task { @MainActor in
                        do {
                            let decoded = try await Task.detached(priority: .userInitiated) {
                                try nativeScreenshotDecodePNG(currentPNG)
                            }.value
                            _ = try await NativeScreenshotDeliveryService.saveToDefault(decoded)
                        } catch { self?.showError(error) }
                    }
                },
                saveAs: { [weak self] currentPNG in
                    Task { @MainActor in
                        do {
                            let decoded = try await Task.detached(priority: .userInitiated) {
                                try nativeScreenshotDecodePNG(currentPNG)
                            }.value
                            _ = try await NativeScreenshotDeliveryService.saveOnly(decoded)
                        }
                        catch NativeScreenshotDeliveryService.DeliveryError.saveCancelled { return }
                        catch { self?.showError(error) }
                    }
                },
                pin: { currentPNG in
                    Task { @MainActor in
                        guard let decoded = try? await Task.detached(
                            priority: .userInitiated,
                            operation: { try nativeScreenshotDecodePNG(currentPNG) }
                        ).value else { return }
                        let nsImage = NSImage(
                            cgImage: decoded,
                            size: NSSize(width: decoded.width, height: decoded.height)
                        )
                        PinPanelController.shared.pin(image: nsImage,
                                                      at: pinRect, skipIngest: true)
                    }
                },
                edit: { [weak self] currentPNG in
                    Task { @MainActor in
                        do {
                            let decoded = try await Task.detached(priority: .userInitiated) {
                                try nativeScreenshotDecodePNG(currentPNG)
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
            estimatedBytes: png.count,
            pngData: png
        )
    }

    private func showRecognition(
        for image: NativeScreenshotCapturedImage,
        initialIntent: NativeScreenshotRecognitionIntent
    ) {
        NativeScreenshotRecognitionWindowController.open(
            image: image.image,
            language: PreferencesManager.shared.screenshotOCRLanguage,
            initialIntent: initialIntent,
            onRedactedImage: { [weak self] covered in
                self?.deliver(NativeScreenshotCapturedImage(
                    image: covered,
                    sourceRect: image.sourceRect,
                    pixelsPerPoint: image.pixelsPerPoint
                ), action: .copy)
            },
            onCopyOriginal: { [weak self] in
                self?.deliver(image, action: .copy)
            },
            onSaveOriginal: { [weak self] in
                self?.deliver(image, action: .saveAs)
            },
            onContinueEditing: { [weak self] in
                self?.openEditor(image)
            }
        )
    }

    /// ScreenCaptureKit uses a top-left desktop origin; pinned AppKit windows
    /// require a bottom-left rect on the matching NSScreen.
    private static func appKitPinRect(for captureRect: CGRect) -> CGRect? {
        guard captureRect.width > 1, captureRect.height > 1 else { return nil }
        let match = NSScreen.screens.compactMap { screen -> (CGRect, NSScreen, CGFloat)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value else { return nil }
            let display = CGDisplayBounds(id)
            let overlap = captureRect.intersection(display)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            return (display, screen, area)
        }.max { $0.2 < $1.2 }
        guard let (display, screen, area) = match,
              area >= captureRect.width * captureRect.height * 0.8 else { return nil }
        return CGRect(
            x: screen.frame.minX + captureRect.minX - display.minX,
            y: screen.frame.maxY - (captureRect.maxY - display.minY),
            width: captureRect.width, height: captureRect.height
        )
    }

    private func startScrolling(region: CGRect, handoffID: UUID) async {
        guard captureHandoffID == handoffID else { return }
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
        captureHandoffID = nil
        scrollHUD = hud
        scrollCaptureReady = false
        hud.onStop = { [weak self] in self?.finishScrolling() }
        hud.onCancel = { [weak self] in self?.cancelScrolling() }
        hud.onAutoScrollToggle = { [weak self, weak session] enabled in
            guard let self, let session, self.scrollSession === session else { return }
            preferences.scrollAutoScrollEnabled = enabled
            guard self.scrollCaptureReady else { return }
            self.switchScrollingMode(session, autoScrollEnabled: enabled)
        }
        hud.show(near: region, autoScrollEnabled: preferences.scrollAutoScrollEnabled)
        do {
            let first = try await session.start()
            guard scrollSession === session else { return }
            scrollCaptureReady = true
            hud.updatePreview(first, addedRows: nil)
            if preferences.scrollAutoScrollEnabled {
                beginAutomaticScrolling(session)
            } else {
                startManualScrollPolling(session)
            }
        } catch {
            guard scrollSession === session else { return }
            cancelScrolling()
            showCaptureError(error)
        }
    }

    private func switchScrollingMode(
        _ session: NativeScreenshotScrollingCaptureSession,
        autoScrollEnabled: Bool
    ) {
        scrollPollTask?.cancel()
        scrollPollTask = nil
        session.stopAutomaticScroll()
        scrollModeSwitchTask?.cancel()
        // A prior capture may still be unwinding after cancellation. Wait for
        // that task before starting the other mode's capture loop.
        scrollModeSwitchTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, let session,
                  self.scrollSession === session else { return }
            if autoScrollEnabled { self.beginAutomaticScrolling(session) }
            else { self.startManualScrollPolling(session) }
            self.scrollModeSwitchTask = nil
        }
    }

    private func beginAutomaticScrolling(_ session: NativeScreenshotScrollingCaptureSession) {
        do {
            try session.startAutomaticScroll(
                onFrame: { [weak self] result, preview in
                    self?.handleScrollFrame(result, preview: preview)
                },
                onError: { [weak self, weak session] error in
                    guard let self, let session, self.scrollSession === session else { return }
                    self.cancelScrolling()
                    self.showError(error)
                },
                onReachedEnd: { [weak self] in self?.finishScrolling() }
            )
        } catch NativeScreenshotScrollingCaptureSession.SessionError.automaticScrollNeedsAccessibility {
            scrollHUD?.setStatus(NativeScreenshotUserText.string(
                "自动滚动需要辅助功能权限，可手动滚动。",
                "Auto scroll needs Accessibility permission; scroll manually."))
            scrollHUD?.setAutoScrollEnabled(false)
            PreferencesManager.shared.scrollAutoScrollEnabled = false
            startManualScrollPolling(session)
        } catch {
            showError(error)
            startManualScrollPolling(session)
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
                    guard self?.scrollSession === session else { break }
                    self?.cancelScrolling()
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
        scrollModeSwitchTask?.cancel()
        scrollModeSwitchTask = nil
        scrollCaptureReady = false
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
        scrollModeSwitchTask?.cancel()
        scrollModeSwitchTask = nil
        scrollCaptureReady = false
        scrollCompletionID = nil
        scrollPollTask?.cancel()
        scrollPollTask = nil
        scrollSession?.cancel()
        scrollSession = nil
        scrollHUD?.close()
        scrollHUD = nil
    }

    private func queueRecordingSetup(region: CGRect) {
        recordingSetupGeneration &+= 1
        let generation = recordingSetupGeneration
        // The visible size fields are authoritative immediately. A pending
        // display refresh may reposition the controls, but Start must never
        // use the previous rectangle.
        recordingRegion = region
        if let setup = recordingSetup, let recordingDisplayID {
            setup.show(near: region, displayID: recordingDisplayID)
        }
        Task { @MainActor [weak self] in
            await self?.showRecordingSetup(region: region, generation: generation)
        }
    }

    private func showRecordingSetup(region: CGRect, generation: UInt64) async {
        guard recordingSessionID == nil,
              recordingSetupGeneration == generation else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard overlay != nil, recordingSessionID == nil,
                  recordingSetupGeneration == generation else { return }
            guard let display = content.displays.max(by: {
                $0.frame.intersection(region).area < $1.frame.intersection(region).area
            }), display.frame.contains(region) else {
                throw NativeScreenshotRecordingError.displayUnavailable
            }
            recordingRegion = region
            recordingDisplayID = display.displayID
            if let setup = recordingSetup {
                setup.show(near: region, displayID: display.displayID)
            } else {
                let setup = NativeScreenshotRecordingSetupPanel()
                recordingSetup = setup
                setup.onStart = { [weak self, weak setup] selection in
                    guard let self, let setup, self.recordingSetup === setup else { return }
                    let handoffID = UUID()
                    self.captureHandoffID = handoffID
                    self.recordingSetup = nil
                    self.recordingSetupGeneration &+= 1
                    let selectedRegion = self.recordingRegion ?? region
                    self.recordingRegion = nil
                    self.recordingDisplayID = nil
                    self.overlay?.dismissForHandoff()
                    self.overlay = nil
                    Task { @MainActor [weak self] in
                        await self?.startRecording(region: selectedRegion,
                                                   selection: selection,
                                                   handoffID: handoffID)
                    }
                }
                setup.onCancel = { [weak self, weak setup] in
                    guard let self, let setup, self.recordingSetup === setup else { return }
                    self.recordingSetup = nil
                    self.recordingSetupGeneration &+= 1
                    self.recordingRegion = nil
                    self.recordingDisplayID = nil
                    self.overlay?.dismissForHandoff()
                    self.overlay = nil
                }
                setup.onMove = { [weak self] in
                    self?.overlay?.beginRecordingSelectionMove()
                }
                setup.show(near: region, displayID: display.displayID)
            }
        } catch {
            guard recordingSetupGeneration == generation else { return }
            recordingSetupGeneration &+= 1
            recordingSetup?.close()
            recordingSetup = nil
            recordingRegion = nil
            recordingDisplayID = nil
            overlay?.dismissForHandoff()
            overlay = nil
            showCaptureError(error)
        }
    }

    private func startRecording(
        region: CGRect,
        selection: NativeScreenshotRecordingSetupSelection,
        handoffID: UUID
    ) async {
        guard recordingSessionID == nil, captureHandoffID == handoffID else { return }
        let sessionID = UUID()
        recordingSessionID = sessionID
        captureHandoffID = nil
        recordingStarted = false
        recordingPaused = false
        recordingFinalizing = false
        recordingControlsHidden = selection.hidesHUD
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
            if selection.delaySeconds > 0 {
                let countdown = NativeScreenshotRecordingCountdownHUD()
                recordingCountdown = countdown
                countdown.onCancel = { [weak self] in
                    Task { @MainActor [weak self] in await self?.cancelRecording() }
                }
                countdown.show(near: region, displayID: display.displayID)
                for seconds in stride(from: selection.delaySeconds, through: 1, by: -1) {
                    countdown.update(seconds: seconds)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard recordingSessionID == sessionID else { return }
                }
                countdown.close()
                recordingCountdown = nil
            }
            let local = region.intersection(display.frame)
                .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let outputURL = try newRecordingURL()
            let preferences = PreferencesManager.shared
            let hud = NativeScreenshotRecordingHUD(showTimer: !selection.hidesHUD)
            recordingHUD = hud
            hud.onStop = { [weak self] in Task { @MainActor in await self?.stopRecording() } }
            hud.onCancel = { [weak self] in Task { @MainActor in await self?.cancelRecording() } }
            hud.onPauseToggle = { [weak self] in self?.toggleRecordingPause() }
            // The HUD must exist on screen when the filter is built so the
            // capture stream can exclude this exact window, even if hidden
            // controls were selected for the recording itself.
            hud.show(near: region, displayID: display.displayID)
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
                framesPerSecond: selection.framesPerSecond,
                includesSystemAudio: selection.includesSystemAudio,
                includesMicrophone: selection.includesMicrophone,
                microphoneDeviceID: selection.microphoneDeviceID,
                highlightsMouseClicks: selection.highlightsMouseClicks,
                webcam: selection.includesWebcam ? webcamOptions(preferences) : nil,
                webcamDeviceID: selection.webcamDeviceID,
                keystrokeMode: selection.keystrokeMode
            )
            let recorder = NativeScreenshotRecorder(options: options,
                                                    excludedWindows: excluded)
            self.recorder = recorder
            recorder.onAutomaticStop = { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.recordingEnded(result, sessionID: sessionID)
                }
            }
            recorder.onAutomaticStopBegan = { [weak self] in
                MainActor.assumeIsolated {
                    self?.beginRecordingFinalizing(sessionID: sessionID)
                }
            }
            recorder.onCameraUnavailable = { [weak self, weak hud] in
                Task { @MainActor [weak self, weak hud] in
                    guard self?.recordingSessionID == sessionID else { return }
                    hud?.addWarning(NativeScreenshotUserText.string(
                        "摄像头已断开，后续画面不再包含摄像头。",
                        "Camera disconnected; the remaining video will not include it."))
                    if let hud {
                        self?.showHiddenRecordingWarning(on: hud, sessionID: sessionID)
                    }
                }
            }
            try await recorder.start()
            guard recordingSessionID == sessionID else {
                await recorder.cancel()
                return
            }
            recordingStarted = true
            hud.startTiming()
            if !recorder.warnings.isEmpty {
                appLog(recorder.warnings.joined(separator: " | "), level: .warning)
                showRecordingWarnings(recorder.warnings, on: hud)
            }
            if selection.hidesHUD {
                if recorder.warnings.isEmpty { hud.window.orderOut(nil) }
                else { showHiddenRecordingWarning(on: hud, sessionID: sessionID) }
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

    private func showHiddenRecordingWarning(
        on hud: NativeScreenshotRecordingHUD,
        sessionID: UUID
    ) {
        guard recordingControlsHidden, recordingSessionID == sessionID else { return }
        hud.window.orderFrontRegardless()
        recordingWarningHideTask?.cancel()
        recordingWarningHideTask = Task { @MainActor [weak self, weak hud] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self,
                  self.recordingSessionID == sessionID,
                  self.recordingControlsHidden else { return }
            hud?.window.orderOut(nil)
            self.recordingWarningHideTask = nil
        }
    }

    private func stopRecording() async {
        guard let sessionID = recordingSessionID else { return }
        guard !recordingFinalizing else { return }
        guard recordingStarted else {
            await cancelRecording()
            return
        }
        // A previous Stop owns the encoder once it removes `recorder`.
        // Repeated clicks must wait for that result, not cancel the session.
        guard let recorder else { return }
        beginRecordingFinalizing(sessionID: sessionID)
        self.recorder = nil
        do {
            let url = try await recorder.stop()
            recordingEnded(.success(url), sessionID: sessionID)
        } catch NativeScreenshotRecordingError.captureUnavailable {
            // The duration-limit callback already owns stop(). Its result will
            // complete this session; treating this race as failure would delete
            // a valid movie when the automatic callback arrives.
        } catch { recordingEnded(.failure(error), sessionID: sessionID) }
    }

    private func beginRecordingFinalizing(sessionID: UUID) {
        guard recordingSessionID == sessionID, !recordingFinalizing else { return }
        recordingFinalizing = true
        recordingWarningHideTask?.cancel()
        recordingWarningHideTask = nil
        recordingHUD?.close()
        recordingHUD = nil
    }

    private func toggleRecordingPause() {
        guard let recorder, recordingSessionID != nil, recordingStarted else { return }
        if recordingPaused {
            if recorder.resume() {
                recordingPaused = false
                recordingHUD?.setPaused(false)
            }
        } else if recorder.pause() {
            recordingPaused = true
            recordingHUD?.setPaused(true)
        }
    }

    private func recordingEnded(_ result: Result<URL, Error>, sessionID: UUID) {
        guard recordingSessionID == sessionID else {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }
        recordingSessionID = nil
        recordingStarted = false
        recordingPaused = false
        recordingFinalizing = false
        recordingControlsHidden = false
        recordingWarningHideTask?.cancel()
        recordingWarningHideTask = nil
        recordingCountdown?.close()
        recordingCountdown = nil
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
        guard !recordingFinalizing else { return }
        recordingSessionID = nil
        recordingStarted = false
        recordingPaused = false
        recordingFinalizing = false
        recordingControlsHidden = false
        recordingWarningHideTask?.cancel()
        recordingWarningHideTask = nil
        recordingCountdown?.close()
        recordingCountdown = nil
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
