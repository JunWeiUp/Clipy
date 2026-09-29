import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NativeScreenshotGIFExporter {
    struct Options {
        let framesPerSecond: Int
        let maximumDimension: Int
        let maximumDuration: TimeInterval

        init(framesPerSecond: Int = 15, maximumDimension: Int = 960, maximumDuration: TimeInterval = 120) {
            self.framesPerSecond = framesPerSecond
            self.maximumDimension = maximumDimension
            self.maximumDuration = maximumDuration
        }
    }

    /// Converts a completed MP4 into a looping GIF. The caller runs this away from the main actor.
    static func export(
        videoURL: URL,
        destinationURL: URL,
        options: Options = Options(),
        progress: ((Double) -> Void)? = nil
    ) async throws {
        guard videoURL.isFileURL, destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "gif",
              (1...60).contains(options.framesPerSecond), options.maximumDimension >= 64,
              options.maximumDuration > 0 else {
            throw NativeScreenshotRecordingError.invalidDestination
        }
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw NativeScreenshotRecordingError.noFrames }
        let exportDuration = min(duration, options.maximumDuration)
        let count = max(1, Int(ceil(exportDuration * Double(options.framesPerSecond))))
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".native-gif-\(UUID().uuidString).gif")
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw NativeScreenshotRecordingError.invalidDestination
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maximumDimension, height: options.maximumDimension)
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        for index in 0..<count {
            try Task.checkCancellation()
            let second = min(Double(index) / Double(options.framesPerSecond), max(0, duration - 0.001))
            let time = CMTime(seconds: second, preferredTimescale: 600)
            let frame = try generator.copyCGImage(at: time, actualTime: nil)
            let delay = min(1 / Double(options.framesPerSecond), max(0.02, exportDuration - second))
            let properties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                              kCGImagePropertyGIFUnclampedDelayTime: delay]
            ]
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
            progress?(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NativeScreenshotRecordingError.writerFailed("GIF 编码失败")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NativeScreenshotRecordingError.invalidDestination
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }
}
