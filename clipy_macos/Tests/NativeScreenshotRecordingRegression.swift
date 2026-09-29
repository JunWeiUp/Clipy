#if NATIVE_SCREENSHOT_RECORDING_TESTS
import AVFoundation
import Carbon
import CoreVideo
import Foundation
import ImageIO

@main
enum NativeScreenshotRecordingRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-recording-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = NativeScreenshotRecordingOptions(
            displayID: 1,
            sourceRect: CGRect(x: 0, y: 0, width: 1_501, height: 1_001),
            outputURL: directory.appendingPathComponent("test.mp4"),
            framesPerSecond: 24,
            maxDimension: 1_280
        )
        _ = try base.validated()
        let size = base.outputSize(displayScale: 2)
        precondition(Int(size.width) <= 1_280 && Int(size.height) <= 1_280)
        precondition(Int(size.width).isMultiple(of: 2) && Int(size.height).isMultiple(of: 2))
        let mapped = base.outputPoint(forGlobalPoint: CGPoint(x: 350, y: 450),
                                      displayFrame: CGRect(x: 100, y: 200, width: 2_000, height: 1_200),
                                      outputSize: size)
        precondition(mapped != nil && mapped!.x > 0 && mapped!.y < size.height)
        precondition(base.outputPoint(forGlobalPoint: CGPoint(x: 10, y: 10),
                                     displayFrame: CGRect(x: 100, y: 200, width: 2_000, height: 1_200),
                                     outputSize: size) == nil)
        let returnKey = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: true)!
        precondition(NativeScreenshotKeystrokeMonitor.displayText(
            for: returnKey, mode: .shortcutsOnly, secureInputEnabled: false
        ) == nil)
        precondition(NativeScreenshotKeystrokeMonitor.displayText(
            for: returnKey, mode: .allKeys, secureInputEnabled: false
        ) == "↩")
        returnKey.flags = .maskCommand
        precondition(NativeScreenshotKeystrokeMonitor.displayText(
            for: returnKey, mode: .shortcutsOnly, secureInputEnabled: false
        ) == "⌘↩")
        precondition(NativeScreenshotKeystrokeMonitor.displayText(
            for: returnKey, mode: .allKeys, secureInputEnabled: true
        ) == nil)
        let commandKey = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true)!
        commandKey.flags = .maskCommand
        precondition(NativeScreenshotKeystrokeMonitor.modifierDisplayText(
            for: commandKey, mode: .allKeys, secureInputEnabled: false
        ) == "⌘")
        precondition(NativeScreenshotKeystrokeMonitor.modifierDisplayText(
            for: commandKey, mode: .shortcutsOnly, secureInputEnabled: false
        ) == nil)
        do {
            _ = try NativeScreenshotRecordingOptions(
                displayID: 1, sourceRect: base.sourceRect,
                outputURL: base.outputURL, framesPerSecond: 25
            ).validated()
            fatalError("Unsupported frame rate accepted")
        } catch NativeScreenshotRecordingError.invalidFrameRate {}

        let movieURL = directory.appendingPathComponent("synthetic.mp4")
        let writer = try NativeScreenshotMovieWriter(
            url: movieURL,
            size: CGSize(width: 320, height: 240),
            systemAudio: false, microphone: false, maxDuration: 10
        )
        let compositor = NativeScreenshotVideoCompositor(
            webcam: .init(position: .topLeft, size: .small, shape: .circle)
        )
        var staticSample: CMSampleBuffer?
        for frame in 0..<12 {
            var pixelBuffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                               kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                               kCVPixelBufferIOSurfacePropertiesKey: [:]]
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                                             kCVPixelFormatType_32BGRA,
                                             attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
            guard let pixelBuffer else { fatalError("No pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(frame * 10), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            var format: CMVideoFormatDescription?
            precondition(CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &format) == noErr)
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30),
                decodeTimeStamp: .invalid
            )
            precondition(CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescription: format!, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr)
            if frame == 0 { compositor.updateCameraFrame(sample!) }
            if frame == 0 { staticSample = sample }
            if frame == 1 {
                let composed = compositor.compose(sample!)
                precondition(CMSampleBufferGetImageBuffer(composed) !== CMSampleBufferGetImageBuffer(sample!))
                let clickCompositor = NativeScreenshotVideoCompositor(webcam: nil)
                clickCompositor.showClick(at: CGPoint(x: 100, y: 100))
                let clicked = clickCompositor.compose(sample!)
                precondition(CMSampleBufferGetImageBuffer(clicked) !== CMSampleBufferGetImageBuffer(sample!))
                let keyCompositor = NativeScreenshotVideoCompositor(webcam: nil)
                let generation = keyCompositor.showKeystroke("⌘↩")!
                let keyed = keyCompositor.compose(sample!)
                precondition(CMSampleBufferGetImageBuffer(keyed) !== CMSampleBufferGetImageBuffer(sample!))
                precondition(!keyCompositor.expireKeystroke(generation: generation))
            }
            writer.appendVideo(sample!)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        try await writer.finish()
        let asset = AVURLAsset(url: movieURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        let duration = try await asset.load(.duration)
        precondition(duration.seconds > 0)

        let staticURL = directory.appendingPathComponent("static.mp4")
        let staticWriter = try NativeScreenshotMovieWriter(
            url: staticURL, size: CGSize(width: 320, height: 240),
            systemAudio: false, microphone: false, maxDuration: 10
        )
        let sampleQueue = DispatchQueue(label: "native-recording-test.samples")
        sampleQueue.sync { staticWriter.appendVideo(staticSample!) }
        try await Task.sleep(nanoseconds: 250_000_000)
        var lateTiming = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var lateSample: CMSampleBuffer?
        precondition(CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: staticSample!,
            sampleTimingEntryCount: 1, sampleTimingArray: &lateTiming,
            sampleBufferOut: &lateSample) == noErr)
        try sampleQueue.sync {
            precondition(staticWriter.appendCleanFrameAtCurrentTime())
            try staticWriter.prepareToFinish()
            let finalTime = staticWriter.lastVideoTime
            // A callback queued after stop must not write into finished inputs.
            staticWriter.appendVideo(lateSample!)
            precondition(staticWriter.lastVideoTime == finalTime)
        }
        try await staticWriter.completeFinish()
        let staticDuration = try await AVURLAsset(url: staticURL).load(.duration)
        precondition(staticDuration.seconds >= 0.15 && staticDuration.seconds < 0.8)

        let cancelledWriter = try NativeScreenshotMovieWriter(
            url: directory.appendingPathComponent("cancelled.mp4"),
            size: CGSize(width: 320, height: 240),
            systemAudio: false, microphone: false, maxDuration: 10
        )
        sampleQueue.sync {
            cancelledWriter.appendVideo(staticSample!)
            let lastTime = cancelledWriter.lastVideoTime
            cancelledWriter.cancel()
            cancelledWriter.appendVideo(lateSample!)
            precondition(cancelledWriter.lastVideoTime == lastTime)
        }

        let gifURL = directory.appendingPathComponent("synthetic.gif")
        try await NativeScreenshotGIFExporter.export(
            videoURL: movieURL, destinationURL: gifURL,
            options: .init(framesPerSecond: 10, maximumDimension: 320)
        )
        guard let gif = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else { fatalError("GIF not readable") }
        precondition(CGImageSourceGetCount(gif) > 1)
        let properties = CGImageSourceCopyProperties(gif, nil) as? [CFString: Any]
        let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        precondition(gifProperties?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        print("NativeScreenshotRecordingRegression passed")
    }
}
#endif
