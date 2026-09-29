import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Region MP4 capture for macOS 13+. Each instance is single-use.
final class NativeScreenshotRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State { case idle, starting, recording, stopping, finished }

    private let options: NativeScreenshotRecordingOptions
    private let excludedWindows: [SCWindow]
    private let sampleQueue = DispatchQueue(label: "NativeScreenshot.recording.samples", qos: .userInitiated)
    private let stateLock = NSLock()
    private var state: State = .idle
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var cameraSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var cameraDisconnectObserver: NSObjectProtocol?
    private var cameraAvailable = false  // sampleQueue only
    private var videoCompositor: NativeScreenshotVideoCompositor?
    private var clickMonitor: NativeScreenshotClickMonitor?
    private var keystrokeMonitor: NativeScreenshotKeystrokeMonitor?
    private var movieWriter: NativeScreenshotMovieWriter?
    private var temporaryURL: URL?
    private var microphoneActive = false
    private var durationStopQueued = false

    /// Warnings include optional features denied by the system without aborting screen capture.
    private(set) var warnings: [String] = []
    var onAutomaticStop: ((Result<URL, Error>) -> Void)?
    var onCameraUnavailable: (() -> Void)?

    init(options: NativeScreenshotRecordingOptions, excludedWindows: [SCWindow] = []) {
        self.options = options
        self.excludedWindows = excludedWindows
        super.init()
    }

    private func transition(from expected: State, to newState: State) -> Bool {
        stateLock.withLock {
            guard state == expected else { return false }
            state = newState
            return true
        }
    }

    func start() async throws {
        guard transition(from: .idle, to: .starting) else {
            throw NativeScreenshotRecordingError.captureUnavailable
        }

        do {
            let options = try options.validated()
            let contents = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard stateLock.withLock({ state == .starting }) else {
                throw NativeScreenshotRecordingError.captureUnavailable
            }
            guard let display = contents.displays.first(where: { $0.displayID == options.displayID }) else {
                throw NativeScreenshotRecordingError.displayUnavailable
            }
            let localBounds = CGRect(origin: .zero, size: display.frame.size)
            guard localBounds.contains(options.sourceRect) else {
                throw NativeScreenshotRecordingError.invalidRegion
            }
            let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / display.frame.width
            let size = options.outputSize(displayScale: scale)
            let directory = options.outputURL.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: directory.path),
                  !FileManager.default.fileExists(atPath: options.outputURL.path) else {
                throw NativeScreenshotRecordingError.invalidDestination
            }
            let temp = directory.appendingPathComponent(".native-recording-\(UUID().uuidString).mp4")
            temporaryURL = temp

            microphoneActive = await prepareMicrophoneIfRequested()
            sampleQueue.sync { videoCompositor = NativeScreenshotVideoCompositor(webcam: options.webcam) }
            await prepareCameraIfRequested()
            if let microphoneSession {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        microphoneSession.startRunning()
                        continuation.resume()
                    }
                }
                if !microphoneSession.isRunning {
                    microphoneActive = false
                    warnings.append("麦克风启动失败，录屏继续但不包含麦克风音轨。")
                }
            }
            if let cameraSession {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cameraSession.startRunning()
                        continuation.resume()
                    }
                }
                if !cameraSession.isRunning {
                    warnings.append("摄像头启动失败，录屏继续但不包含摄像头。")
                    sampleQueue.sync { cameraAvailable = false; videoCompositor?.clearCameraFrame() }
                } else {
                    sampleQueue.sync { cameraAvailable = true }
                }
            }
            guard stateLock.withLock({ state == .starting }) else {
                throw NativeScreenshotRecordingError.captureUnavailable
            }
            let writer = try NativeScreenshotMovieWriter(
                url: temp,
                size: size,
                systemAudio: options.includesSystemAudio,
                microphone: microphoneActive,
                maxDuration: options.maxDuration
            )
            sampleQueue.sync { movieWriter = writer }

            let config = SCStreamConfiguration()
            config.sourceRect = options.sourceRect
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
            config.queueDepth = 5
            config.showsCursor = true
            config.capturesAudio = options.includesSystemAudio
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            if #available(macOS 15.0, *) {
                config.showMouseClicks = options.highlightsMouseClicks
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if options.includesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            self.stream = stream
            try await stream.startCapture()
            if options.highlightsMouseClicks {
                if #available(macOS 15.0, *) {
                    // ScreenCaptureKit draws its own click ring.
                } else {
                    let monitor = NativeScreenshotClickMonitor()
                    monitor.onClick = { [weak self] point in
                        guard let self,
                              let outputPoint = self.options.outputPoint(
                                forGlobalPoint: point, displayFrame: display.frame, outputSize: size
                              ) else { return }
                        self.sampleQueue.async { self.videoCompositor?.showClick(at: outputPoint) }
                    }
                    if await MainActor.run(body: { monitor.start() }) {
                        clickMonitor = monitor
                    } else {
                        warnings.append("缺少输入监控权限，鼠标点击高亮不可用。")
                    }
                }
            }
            if options.keystrokeMode != .off {
                let monitor = NativeScreenshotKeystrokeMonitor(mode: options.keystrokeMode)
                monitor.onDisplayText = { [weak self] text in
                    guard let self else { return }
                    self.sampleQueue.async { [weak self] in
                        guard let self,
                              let generation = self.videoCompositor?.showKeystroke(text) else { return }
                        self.sampleQueue.asyncAfter(deadline: .now() + 1.25) { [weak self] in
                            guard let self,
                                  self.videoCompositor?.expireKeystroke(generation: generation) == true else { return }
                            _ = self.movieWriter?.appendCleanFrameAtCurrentTime()
                        }
                    }
                }
                if await MainActor.run(body: { monitor.start() }) {
                    keystrokeMonitor = monitor
                } else {
                    warnings.append("缺少输入监控权限，按键显示不可用。")
                }
            }
            guard stateLock.withLock({ state == .starting }) else {
                try? await stream.stopCapture()
                throw NativeScreenshotRecordingError.captureUnavailable
            }
            guard transition(from: .starting, to: .recording) else {
                try? await stream.stopCapture()
                throw NativeScreenshotRecordingError.captureUnavailable
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + options.maxDuration) { [weak self] in
                self?.stopForDurationLimit()
            }
        } catch {
            try? await stream?.stopCapture()
            await stopMicrophone()
            await stopCamera()
            await stopClickMonitor()
            await stopKeystrokeMonitor()
            removeCameraObserver()
            sampleQueue.sync { movieWriter?.cancel(); movieWriter = nil }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            stream = nil
            microphoneSession = nil
            cameraSession = nil
            cameraOutput = nil
            sampleQueue.sync { videoCompositor?.clear(); videoCompositor = nil }
            stateLock.withLock { state = .finished }
            throw error
        }
    }

    /// Stops capture, finalizes the MP4 and atomically moves it to the requested destination.
    @discardableResult
    func stop() async throws -> URL {
        guard transition(from: .recording, to: .stopping) else {
            throw NativeScreenshotRecordingError.captureUnavailable
        }
        defer {
            stateLock.withLock { state = .finished }
        }
        do {
            try await stream?.stopCapture()
            await stopMicrophone()
            await stopCamera()
            await stopClickMonitor()
            await stopKeystrokeMonitor()
            guard let writer = sampleQueue.sync(execute: { movieWriter }), let temp = temporaryURL else {
                throw NativeScreenshotRecordingError.writerFailed("编码器已释放")
            }
            try await writer.finish()
            try FileManager.default.moveItem(at: temp, to: options.outputURL)
            sampleQueue.sync { movieWriter = nil }
            stream = nil
            microphoneSession = nil
            cameraSession = nil
            cameraOutput = nil
            removeCameraObserver()
            sampleQueue.sync { videoCompositor?.clear(); videoCompositor = nil }
            return options.outputURL
        } catch {
            try? await stream?.stopCapture()
            await stopMicrophone()
            await stopCamera()
            await stopClickMonitor()
            await stopKeystrokeMonitor()
            sampleQueue.sync { movieWriter?.cancel(); movieWriter = nil }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            stream = nil
            microphoneSession = nil
            cameraSession = nil
            cameraOutput = nil
            removeCameraObserver()
            sampleQueue.sync { videoCompositor?.clear(); videoCompositor = nil }
            throw error
        }
    }

    /// Cancels without delivering a file. Safe to call while starting or recording.
    func cancel() async {
        let shouldCancel = stateLock.withLock { () -> Bool in
            guard state == .starting || state == .recording else { return false }
            state = .stopping
            return true
        }
        guard shouldCancel else { return }
        try? await stream?.stopCapture()
        await stopMicrophone()
        await stopCamera()
        await stopClickMonitor()
        await stopKeystrokeMonitor()
        sampleQueue.sync { movieWriter?.cancel(); movieWriter = nil }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        stream = nil
        microphoneSession = nil
        cameraSession = nil
        cameraOutput = nil
        removeCameraObserver()
        sampleQueue.sync { videoCompositor?.clear(); videoCompositor = nil }
        stateLock.withLock { state = .finished }
    }

    private func prepareMicrophoneIfRequested() async -> Bool {
        guard options.includesMicrophone else { return false }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            warnings.append("麦克风权限被拒绝，录屏将不包含麦克风音轨。")
            return false
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            warnings.append("未找到可用麦克风，录屏将不包含麦克风音轨。")
            return false
        }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                warnings.append("麦克风无法加入录制会话。")
                return false
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            microphoneSession = session
            return true
        } catch {
            warnings.append("麦克风无法启动：\(error.localizedDescription)")
            return false
        }
    }

    private func stopMicrophone() async {
        guard let microphoneSession, microphoneSession.isRunning else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                microphoneSession.stopRunning()
                continuation.resume()
            }
        }
    }

    private func prepareCameraIfRequested() async {
        guard options.webcam != nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            warnings.append("摄像头权限被拒绝，录屏将不包含摄像头。")
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            warnings.append("未找到可用摄像头，录屏将不包含摄像头。")
            return
        }
        do {
            let session = AVCaptureSession()
            session.sessionPreset = .medium
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddInput(input), session.canAddOutput(output) else {
                warnings.append("摄像头无法加入录制会话。")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            cameraOutput = output
            cameraSession = session
            cameraDisconnectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: device,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                guard self.stateLock.withLock({ self.state == .recording }) else { return }
                self.sampleQueue.async {
                    guard self.cameraAvailable else { return }
                    self.cameraAvailable = false
                    self.videoCompositor?.clearCameraFrame()
                    DispatchQueue.main.async {
                        guard self.stateLock.withLock({ self.state == .recording }) else { return }
                        self.onCameraUnavailable?()
                    }
                }
            }
        } catch {
            warnings.append("摄像头无法启动：\(error.localizedDescription)")
        }
    }

    private func stopCamera() async {
        guard let cameraSession, cameraSession.isRunning else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                cameraSession.stopRunning()
                continuation.resume()
            }
        }
    }

    private func removeCameraObserver() {
        if let cameraDisconnectObserver {
            NotificationCenter.default.removeObserver(cameraDisconnectObserver)
            self.cameraDisconnectObserver = nil
        }
    }

    private func stopClickMonitor() async {
        guard let clickMonitor else { return }
        await MainActor.run { clickMonitor.stop() }
        self.clickMonitor = nil
    }

    private func stopKeystrokeMonitor() async {
        guard let keystrokeMonitor else { return }
        await MainActor.run { keystrokeMonitor.stop() }
        self.keystrokeMonitor = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer = movieWriter else { return }
        switch type {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let status = attachments.first?[.status] as? Int,
               status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.suspended.rawValue
                || status == SCFrameStatus.stopped.rawValue { return }
            writer.appendVideo(videoCompositor?.compose(sampleBuffer) ?? sampleBuffer,
                               cleanFallback: sampleBuffer)
            if writer.reachedDurationLimit, !durationStopQueued {
                durationStopQueued = true
                stopForDurationLimit()
            }
        case .audio:
            writer.appendSystemAudio(sampleBuffer)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === cameraOutput {
            if cameraAvailable { videoCompositor?.updateCameraFrame(sampleBuffer) }
        } else {
            movieWriter?.appendMicrophone(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stateLock.withLock({ state == .recording }) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.cancel()
            DispatchQueue.main.async { self.onAutomaticStop?(.failure(error)) }
        }
    }

    private func stopForDurationLimit() {
        guard stateLock.withLock({ state == .recording }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.stop()
                DispatchQueue.main.async { self.onAutomaticStop?(.success(url)) }
            } catch NativeScreenshotRecordingError.captureUnavailable {
                // A concurrent manual stop or cancel already owns the result.
            } catch {
                DispatchQueue.main.async { self.onAutomaticStop?(.failure(error)) }
            }
        }
    }
}
