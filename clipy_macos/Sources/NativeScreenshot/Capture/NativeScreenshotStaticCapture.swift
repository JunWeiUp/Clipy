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
        case .timedOut: return "Screen Capture timed out."
        case .captureAlreadyRunning: return "A screenshot is already in progress."
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

        let scale = content.displays
            .filter { !$0.frame.intersection(frame).isEmpty }
            .map { CGFloat(CGDisplayPixelsWide($0.displayID)) / $0.frame.width }
            .filter { $0.isFinite && $0 > 0 }
            .max() ?? 2
        guard let size = NativeScreenshotCaptureGeometry.outputSize(
            region: frame, scale: scale, maxPixels: maxOutputPixels
        ) else { throw NativeScreenshotCaptureError.imageTooLarge }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await firstFrame(filter: filter, width: size.width, height: size.height, showsCursor: showsCursor)
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
        // SCDisplay.width/height are screen points; the stream configuration
        // expects output pixels. Core Graphics supplies each display's backing
        // pixel dimensions, including mixed Retina/1× arrangements.
        let pixelWidth = CGDisplayPixelsWide(display.displayID)
        let pixelHeight = CGDisplayPixelsHigh(display.displayID)
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 32_768, pixelHeight <= 32_768,
              Double(pixelWidth) * Double(pixelHeight) <= Double(maxOutputPixels) else {
            throw NativeScreenshotCaptureError.imageTooLarge
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await firstFrame(
            filter: filter, width: pixelWidth, height: pixelHeight, showsCursor: showsCursor
        )
        return NativeScreenshotCapturedImage(
            image: image,
            sourceRect: frame,
            pixelsPerPoint: CGFloat(image.width) / frame.width
        )
    }

    private func firstFrame(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        showsCursor: Bool
    ) async throws -> CGImage {
        try checkCancellation()
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let output = NativeScreenshotFirstFrameOutput()
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

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var completed: Result<CGImage, Error>?
    private var timeout: DispatchWorkItem?

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
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            finish(.failure(NativeScreenshotCaptureError.frameConversionFailed))
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

        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
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
            context.draw(cropped, in: destination)
            drewPiece = true
        }
        guard drewPiece else { throw NativeScreenshotCaptureError.invalidRegion }
        guard let image = context.makeImage() else {
            throw NativeScreenshotCaptureError.frameConversionFailed
        }
        return (image, scale)
    }
}
