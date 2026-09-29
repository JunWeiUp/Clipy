import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The times shown in the editor are seconds in the finished movie's timeline.
struct NativeScreenshotVideoSelection {
    let start: TimeInterval
    let end: TimeInterval

    init(start: TimeInterval, end: TimeInterval, duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0, start.isFinite, end.isFinite,
              start >= 0, end <= duration + 0.001, end - start >= 0.1 else {
            throw NativeScreenshotVideoExportError.invalidSelection
        }
        self.start = start
        self.end = min(end, duration)
    }

    var duration: TimeInterval { end - start }
    var timeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                    duration: CMTime(seconds: duration, preferredTimescale: 60_000))
    }
}

enum NativeScreenshotVideoExportError: LocalizedError {
    case invalidSelection
    case unsupportedFormat
    case exportFailed(String)
    case gifTooLong

    var errorDescription: String? {
        let zh = NativeScreenshotUserText.string
        switch self {
        case .invalidSelection: return zh("请先选择至少 0.1 秒的有效片段。", "Select a valid segment of at least 0.1 seconds.")
        case .unsupportedFormat: return zh("该录屏不支持所选导出格式。", "This recording does not support the selected export format.")
        case .exportFailed(let reason): return zh("导出失败：", "Export failed: ") + reason
        case .gifTooLong: return zh("GIF 片段最长为 120 秒。", "GIF segments are limited to 120 seconds.")
        }
    }
}

enum NativeScreenshotVideoSegmentExporter {
    enum MP4Quality { case lossless, standard }

    // AVAssetExportSession's callback and cancellation are explicitly concurrent.
    // Its own status/progress/cancel API is designed for that usage.
    private final class SessionBox: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    /// Writes next to the destination, then moves the complete file into place.
    static func exportMP4(
        sourceURL: URL, destinationURL: URL, selection: NativeScreenshotVideoSelection,
        quality: MP4Quality, progress: @escaping (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard sourceURL.isFileURL, destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "mp4" else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let source = AVURLAsset(url: sourceURL)
        let preset = quality == .lossless ? AVAssetExportPresetPassthrough : AVAssetExportPresetMediumQuality
        guard let session = AVAssetExportSession(asset: source, presetName: preset),
              session.supportedFileTypes.contains(.mp4) else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let box = SessionBox(session)
        let stagedURL = temporaryURL(beside: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        session.outputURL = stagedURL
        session.outputFileType = .mp4
        session.timeRange = selection.timeRange
        session.shouldOptimizeForNetworkUse = false

        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(box.value.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: NativeScreenshotVideoExportError.exportFailed(
                        String(describing: box.value.error ?? NSError(domain: "AVFoundation", code: -1))))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
        try Task.checkCancellation()
        try commit(stagedURL, to: destinationURL)
        progress(1)
    }

    /// Image generation is synchronous; call this from a detached task.
    static func exportGIF(
        sourceURL: URL, destinationURL: URL, selection: NativeScreenshotVideoSelection,
        framesPerSecond: Int = 15, maximumDimension: Int = 960,
        progress: @escaping (Double) -> Void
    ) throws {
        guard sourceURL.isFileURL, destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "gif" else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        guard selection.duration <= 120 else { throw NativeScreenshotVideoExportError.gifTooLong }
        let count = max(1, Int(ceil(selection.duration * Double(framesPerSecond))))
        let stagedURL = temporaryURL(beside: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        guard let destination = CGImageDestinationCreateWithURL(
            stagedURL as CFURL, UTType.gif.identifier as CFString, count, nil
        ) else { throw NativeScreenshotVideoExportError.unsupportedFormat }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        // Never reach behind the selected start. A symmetric one-frame tolerance
        // can otherwise put the preceding scene into the first GIF frame.
        generator.requestedTimeToleranceBefore = .zero
        for index in 0..<count {
            if Task<Never, Never>.isCancelled {
                generator.cancelAllCGImageGeneration()
                throw CancellationError()
            }
            let offset = Double(index) / Double(framesPerSecond)
            let second = min(selection.start + offset, selection.end - 0.001)
            generator.requestedTimeToleranceAfter = CMTime(
                seconds: max(0, min(1 / Double(framesPerSecond), selection.end - second - 0.001)),
                preferredTimescale: 60_000)
            let time = CMTime(seconds: second, preferredTimescale: 60_000)
            let frame = try generator.copyCGImage(at: time, actualTime: nil)
            // GIF delays are stored in centiseconds. Distribute rounding across
            // frames so a 15 FPS two-second selection remains two seconds.
            let startCentiseconds = Int((offset * 100).rounded())
            let nextOffset = min(Double(index + 1) / Double(framesPerSecond), selection.duration)
            let endCentiseconds = Int((nextOffset * 100).rounded())
            let delay = max(0.02, Double(endCentiseconds - startCentiseconds) / 100)
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                              kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary)
            progress(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NativeScreenshotVideoExportError.exportFailed("GIF encoder failed")
        }
        if Task<Never, Never>.isCancelled { throw CancellationError() }
        try commit(stagedURL, to: destinationURL)
    }

    private static func temporaryURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".native-segment-\(UUID().uuidString).\(destination.pathExtension)")
    }

    private static func commit(_ staged: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staged)
        } else {
            try files.moveItem(at: staged, to: destination)
        }
    }
}
