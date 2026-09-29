import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum NativeScreenshotCaptureError: LocalizedError {
    case screenRecordingPermissionRequired
    case displayNotFound
    case windowNotFound
    case invalidRegion
    case imageTooLarge
    case noFrame
    case frameConversionFailed
    case nativeResolutionUnavailable
    case frameSizeMismatch(expected: NativeScreenshotPixelSize, actual: NativeScreenshotPixelSize)
    case timedOut
    case captureAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired: return "Screen Recording permission is required. Allow it in System Settings, then retry."
        case .displayNotFound: return "The selected display is no longer available."
        case .windowNotFound: return "The selected window is no longer available."
        case .invalidRegion: return "The selected capture region is invalid."
        case .imageTooLarge: return "The capture exceeds the image size limit."
        case .noFrame: return "Screen Capture did not provide an image frame."
        case .frameConversionFailed: return "The captured frame could not be converted to an image."
        case .nativeResolutionUnavailable:
            return NativeScreenshotUserText.string(
                "无法确定显示器的原生像素分辨率，请重试。",
                "The display's native pixel resolution is unavailable. Please retry.")
        case let .frameSizeMismatch(expected, actual):
            return NativeScreenshotUserText.string(
                "截图帧分辨率异常：实际 \(actual.width)×\(actual.height)，预期 \(expected.width)×\(expected.height)。请重试。",
                "Screen Capture returned \(actual.width)×\(actual.height) pixels instead of the requested \(expected.width)×\(expected.height). Please retry.")
        case .timedOut: return "Screen Capture timed out."
        case .captureAlreadyRunning: return "A screenshot is already in progress."
        }
    }
}

struct NativeScreenshotPixelSize: Equatable {
    let width: Int
    let height: Int
}

struct NativeScreenshotDisplayResolution {
    let frame: CGRect
    let pixels: NativeScreenshotPixelSize
}

/// Keep the requested stream size in device pixels. `CGDisplayPixelsWide`
/// reports the 1× logical size on some HiDPI display modes, so it cannot be
/// used to size a Retina preview.
enum NativeScreenshotCaptureResolution {
    static func displayPixels(
        frame: CGRect,
        modePixels: NativeScreenshotPixelSize?,
        backingScaleFactor: CGFloat?
    ) -> NativeScreenshotPixelSize? {
        guard NativeScreenshotCaptureGeometry.intersection(frame, displayFrame: frame) != nil else {
            return nil
        }
        if let modePixels, modePixels.width > 0, modePixels.height > 0 {
            return modePixels
        }
        guard let backingScaleFactor, backingScaleFactor.isFinite,
              backingScaleFactor > 0,
              let size = NativeScreenshotCaptureGeometry.outputSize(
                region: frame, scale: backingScaleFactor, maxPixels: Int.max
              ) else { return nil }
        return NativeScreenshotPixelSize(width: size.width, height: size.height)
    }

    static func fitsOutputLimit(_ size: NativeScreenshotPixelSize, maxPixels: Int) -> Bool {
        size.width > 0 && size.height > 0 &&
            size.width <= 32_768 && size.height <= 32_768 &&
            maxPixels > 0 && size.width <= maxPixels / size.height
    }

    static func windowPixels(
        frame: CGRect,
        displays: [NativeScreenshotDisplayResolution],
        maxPixels: Int
    ) -> NativeScreenshotPixelSize? {
        let scales = displays.compactMap { display -> CGFloat? in
            guard NativeScreenshotCaptureGeometry.intersection(
                frame, displayFrame: display.frame) != nil else { return nil }
            let x = CGFloat(display.pixels.width) / display.frame.width
            let y = CGFloat(display.pixels.height) / display.frame.height
            let scale = max(x, y)
            return scale.isFinite && scale > 0 ? scale : nil
        }
        guard let scale = scales.max(),
              let size = NativeScreenshotCaptureGeometry.outputSize(
                region: frame, scale: scale, maxPixels: maxPixels
              ) else { return nil }
        return NativeScreenshotPixelSize(width: size.width, height: size.height)
    }

    static func validateFrame(
        actual: NativeScreenshotPixelSize,
        expected: NativeScreenshotPixelSize
    ) throws {
        guard actual == expected else {
            throw NativeScreenshotCaptureError.frameSizeMismatch(
                expected: expected, actual: actual)
        }
    }
}

struct NativeScreenshotCapturedImage {
    let image: CGImage
    /// Global screen points in the coordinate system of `SCDisplay.frame`.
    let sourceRect: CGRect
    let pixelsPerPoint: CGFloat
}

/// One capture operation at a time. Create a new instance after calling cancel().
/// The caller owns overlay presentation and hides its own UI before capture.
@available(macOS 13.0, *)
final class NativeScreenshotStaticCapture {
    private let lock = NSLock()
    private var cancelled = false
    private var activeOutput: NativeScreenshotFirstFrameOutput?
    private var activeStream: SCStream?

    /// Bounds the final uncompressed bitmap to about 256 MiB at 32 bits/pixel.
    let maxOutputPixels: Int

    init(maxOutputPixels: Int = 64_000_000) {
        self.maxOutputPixels = maxOutputPixels
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let output = activeOutput
        let stream = activeStream
        lock.unlock()
        output?.cancel()
        if let stream {
            Task { try? await stream.stopCapture() }
        }
    }

    func captureDisplay(displayID: CGDirectDisplayID, showsCursor: Bool = false) async throws -> NativeScreenshotCapturedImage {
        try checkCancellation()
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NativeScreenshotCaptureError.displayNotFound
        }
        return try await capture(display: display, showsCursor: showsCursor)
    }

    func captureWindow(windowID: CGWindowID, showsCursor: Bool = false) async throws -> NativeScreenshotCapturedImage {
        try checkCancellation()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NativeScreenshotCaptureError.windowNotFound
        }
        let frame = window.frame
        guard NativeScreenshotCaptureGeometry.intersection(frame, displayFrame: frame) != nil else {
            throw NativeScreenshotCaptureError.invalidRegion
        }

        let intersecting = content.displays.filter {
            NativeScreenshotCaptureGeometry.intersection(frame, displayFrame: $0.frame) != nil
        }
        guard !intersecting.isEmpty else { throw NativeScreenshotCaptureError.displayNotFound }
        var resolutions: [NativeScreenshotDisplayResolution] = []
        for display in intersecting {
            resolutions.append(NativeScreenshotDisplayResolution(
                frame: display.frame, pixels: try await nativePixels(for: display)))
        }
        guard let size = NativeScreenshotCaptureResolution.windowPixels(
            frame: frame, displays: resolutions, maxPixels: maxOutputPixels
        ) else { throw NativeScreenshotCaptureError.imageTooLarge }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await firstFrame(filter: filter, size: size, showsCursor: showsCursor)
        return NativeScreenshotCapturedImage(
            image: image,
            sourceRect: frame,
            pixelsPerPoint: CGFloat(image.width) / frame.width
        )
    }

    /// Captures a region that may cross displays. `region` uses SCDisplay.frame
    /// global points; the UI layer must convert any AppKit coordinates first.
    func captureRegion(_ region: CGRect, showsCursor: Bool = false) async throws -> NativeScreenshotCapturedImage {
        try checkCancellation()
        let content = try await shareableContent()
        let displays = content.displays.filter {
            NativeScreenshotCaptureGeometry.intersection(region, displayFrame: $0.frame) != nil
        }
        guard !displays.isEmpty else { throw NativeScreenshotCaptureError.invalidRegion }

        var pieces: [NativeScreenshotCapturePiece] = []
        pieces.reserveCapacity(displays.count)
        for display in displays {
            try checkCancellation()
            let captured = try await capture(display: display, showsCursor: showsCursor)
            pieces.append(NativeScreenshotCapturePiece(displayFrame: display.frame, image: captured.image))
        }
        try checkCancellation()
        let (image, scale) = try NativeScreenshotCaptureComposer.compose(
            region: region, pieces: pieces, maxOutputPixels: maxOutputPixels
        )
        return NativeScreenshotCapturedImage(image: image, sourceRect: region, pixelsPerPoint: scale)
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NativeScreenshotCaptureError.screenRecordingPermissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try checkCancellation()
        return content
    }

    private func capture(display: SCDisplay, showsCursor: Bool) async throws -> NativeScreenshotCapturedImage {
        let frame = display.frame
        guard NativeScreenshotCaptureGeometry.intersection(frame, displayFrame: frame) != nil else {
            throw NativeScreenshotCaptureError.invalidRegion
        }
        let size = try await nativePixels(for: display)
        guard NativeScreenshotCaptureResolution.fitsOutputLimit(
            size, maxPixels: maxOutputPixels) else {
            throw NativeScreenshotCaptureError.imageTooLarge
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await firstFrame(
            filter: filter, size: size, showsCursor: showsCursor
        )
        return NativeScreenshotCapturedImage(
            image: image,
            sourceRect: frame,
            pixelsPerPoint: CGFloat(image.width) / frame.width
        )
    }

    private func nativePixels(for display: SCDisplay) async throws -> NativeScreenshotPixelSize {
        let modePixels = CGDisplayCopyDisplayMode(display.displayID).flatMap { mode -> NativeScreenshotPixelSize? in
            guard mode.pixelWidth > 0, mode.pixelHeight > 0 else { return nil }
            return NativeScreenshotPixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let fallbackScale: CGFloat?
        if modePixels == nil {
            let displayID = display.displayID
            fallbackScale = await MainActor.run {
                NSScreen.screens.first { screen in
                    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? NSNumber
                    return number?.uint32Value == displayID
                }?.backingScaleFactor
            }
        } else {
            fallbackScale = nil
        }
        guard let size = NativeScreenshotCaptureResolution.displayPixels(
            frame: display.frame,
            modePixels: modePixels,
            backingScaleFactor: fallbackScale
        ) else { throw NativeScreenshotCaptureError.nativeResolutionUnavailable }
        return size
    }

    private func firstFrame(
        filter: SCContentFilter,
        size: NativeScreenshotPixelSize,
        showsCursor: Bool
    ) async throws -> CGImage {
        try checkCancellation()
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let output = NativeScreenshotFirstFrameOutput(expectedSize: size)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try begin(output, stream: stream)
        defer { end(output) }
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            let image: CGImage = try await withTaskCancellationHandler {
                try await stream.startCapture()
                return try await withCheckedThrowingContinuation { continuation in
                    output.waitForFrame(continuation)
                }
            } onCancel: {
                output.cancel()
                Task { try? await stream.stopCapture() }
            }
            try? await stream.stopCapture()
            try checkCancellation()
            return image
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }

    private func begin(_ output: NativeScreenshotFirstFrameOutput, stream: SCStream) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if activeOutput != nil { throw NativeScreenshotCaptureError.captureAlreadyRunning }
        activeOutput = output
        activeStream = stream
    }

    private func end(_ output: NativeScreenshotFirstFrameOutput) {
        lock.lock()
        if activeOutput === output {
            activeOutput = nil
            activeStream = nil
        }
        lock.unlock()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }
}

private final class NativeScreenshotFirstFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "clipy.native-screenshot.first-frame", qos: .userInitiated)
    private let expectedSize: NativeScreenshotPixelSize

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var completed: Result<CGImage, Error>?
    private var timeout: DispatchWorkItem?

    init(expectedSize: NativeScreenshotPixelSize) {
        self.expectedSize = expectedSize
    }

    func waitForFrame(_ continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        if let completed {
            lock.unlock()
            continuation.resume(with: completed)
            return
        }
        self.continuation = continuation
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(NativeScreenshotCaptureError.timedOut))
        }
        self.timeout = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = result
        timeout?.cancel()
        timeout = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }

        guard let buffer = sampleBuffer.imageBuffer else {
            finish(.failure(NativeScreenshotCaptureError.noFrame))
            return
        }
        do {
            try NativeScreenshotCaptureResolution.validateFrame(
                actual: NativeScreenshotPixelSize(
                    width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                expected: expectedSize)
        } catch {
            finish(.failure(error))
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            finish(.failure(NativeScreenshotCaptureError.frameConversionFailed))
            return
        }
        do {
            try NativeScreenshotCaptureResolution.validateFrame(
                actual: NativeScreenshotPixelSize(width: cgImage.width, height: cgImage.height),
                expected: expectedSize)
        } catch {
            finish(.failure(error))
            return
        }
        finish(.success(cgImage))
    }
}

struct NativeScreenshotCapturePiece {
    let displayFrame: CGRect
    let image: CGImage
}

enum NativeScreenshotCaptureComposer {
    static func compose(
        region: CGRect,
        pieces: [NativeScreenshotCapturePiece],
        maxOutputPixels: Int
    ) throws -> (image: CGImage, pixelsPerPoint: CGFloat) {
        let scales = pieces.compactMap { piece -> CGFloat? in
            guard piece.displayFrame.width > 0 else { return nil }
            let value = CGFloat(piece.image.width) / piece.displayFrame.width
            return value.isFinite && value > 0 ? value : nil
        }
        guard let scale = scales.max(),
              let size = NativeScreenshotCaptureGeometry.outputSize(
                region: region, scale: scale, maxPixels: maxOutputPixels
              ) else { throw NativeScreenshotCaptureError.imageTooLarge }
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw NativeScreenshotCaptureError.frameConversionFailed }

        context.interpolationQuality = .high
        var drewPiece = false
        for piece in pieces {
            guard let overlap = NativeScreenshotCaptureGeometry.intersection(region, displayFrame: piece.displayFrame),
                  let crop = NativeScreenshotCaptureGeometry.pixelCrop(
                    intersection: overlap,
                    displayFrame: piece.displayFrame,
                    imageWidth: piece.image.width,
                    imageHeight: piece.image.height
                  ),
                  let destination = NativeScreenshotCaptureGeometry.outputRect(
                    intersection: overlap, region: region, scale: scale
                  ),
                  let cropped = piece.image.cropping(to: crop) else { continue }
            // `destination` uses top-left screen coordinates. The bitmap
            // context is bottom-left based; move the rect without flipping the
            // CGImage itself, or text in an inline selection appears inverted.
            context.draw(cropped, in: CGRect(
                x: destination.minX,
                y: CGFloat(size.height) - destination.maxY,
                width: destination.width,
                height: destination.height))
            drewPiece = true
        }
        guard drewPiece else { throw NativeScreenshotCaptureError.invalidRegion }
        guard let image = context.makeImage() else {
            throw NativeScreenshotCaptureError.frameConversionFailed
        }
        return (image, scale)
    }
}
