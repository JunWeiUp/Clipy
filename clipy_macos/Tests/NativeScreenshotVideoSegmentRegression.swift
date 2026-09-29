import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Self-contained media regression. All frames and audio are generated in memory.
@main
struct NativeScreenshotVideoSegmentRegression {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-video-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mp4")
        try await makeFixture(at: source)
        let sourceAsset = AVURLAsset(url: source)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio)
        precondition(abs(sourceDuration - 4) < 0.1)
        precondition(sourceAudio.count == 1)

        let selection = try NativeScreenshotVideoSelection(start: 1, end: 3, duration: 4)
        precondition(abs(selection.timeRange.duration.seconds - 2) < 0.001)
        assertThrows { _ = try NativeScreenshotVideoSelection(start: 3, end: 1, duration: 4) }

        let gifURL = folder.appendingPathComponent("selected.gif")
        try NativeScreenshotVideoSegmentExporter.exportGIF(
            sourceURL: source, destinationURL: gifURL,
            selection: selection, progress: { _ in })
        guard let gif = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            fatalError("GIF cannot be opened")
        }
        precondition(CGImageSourceGetCount(gif) == 30)
        let properties = CGImageSourceCopyProperties(gif, nil) as? [String: Any]
        let gifProperties = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        precondition(gifProperties?[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
        let gifDuration = (0..<CGImageSourceGetCount(gif)).reduce(0.0) { sum, index in
            let frameProperties = CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [String: Any]
            let metadata = frameProperties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            return sum + (metadata?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? 0)
        }
        precondition(abs(gifDuration - 2) < 0.05, "GIF duration: \(gifDuration)")
        // The exact segment boundary must not leak the preceding red scene.
        guard let firstFrame = CGImageSourceCreateImageAtIndex(gif, 0, nil),
              let lastFrame = CGImageSourceCreateImageAtIndex(gif, 29, nil) else {
            fatalError("GIF frames cannot be decoded")
        }
        let firstColor = centerPixel(firstFrame)
        let lastColor = centerPixel(lastFrame)
        precondition(firstColor.green > firstColor.red && firstColor.green > firstColor.blue)
        precondition(lastColor.blue > lastColor.red && lastColor.blue > lastColor.green)

        for quality in [NativeScreenshotVideoSegmentExporter.MP4Quality.standard, .lossless] {
            let name = quality == .lossless ? "lossless.mp4" : "standard.mp4"
            let output = folder.appendingPathComponent(name)
            try await NativeScreenshotVideoSegmentExporter.exportMP4(
                sourceURL: source, destinationURL: output, selection: selection,
                quality: quality, progress: { _ in })
            let asset = AVURLAsset(url: output)
            let seconds = try await asset.load(.duration).seconds
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            precondition(abs(seconds - 2) < 0.15, "Unexpected trim duration: \(seconds)")
            precondition(audioTracks.count == 1, "Audio track was lost")
            precondition(videoTracks.count == 1, "Video track was lost")
        }

        print("NativeScreenshotVideoSegmentRegression passed")
    }

    private static func makeFixture(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180
        ])
        video.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180
            ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ])
        audio.expectsMediaDataInRealTime = false
        precondition(writer.canAdd(video) && writer.canAdd(audio))
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let format = try audioFormat()
        try await waitUntilReady(audio, writer: writer, label: "audio", frame: 0)
        let sound = try makeAudioSample(startSample: 0, sampleCount: 192_000, format: format)
        guard audio.append(sound) else { throw writer.error ?? FixtureError.writerFailed }
        audio.markAsFinished()
        for frame in 0..<120 {
            try await waitUntilReady(video, writer: writer, label: "video", frame: frame)
            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            guard let buffer = makePixelBuffer(second: frame / 30),
                  adapter.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? FixtureError.writerFailed
            }
        }
        video.markAsFinished()
        let box = WriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.value.finishWriting {
                if box.value.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: box.value.error ?? FixtureError.writerFailed) }
            }
        }
    }

    private static func makePixelBuffer(second: Int) -> CVPixelBuffer? {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                                         kCVPixelFormatType_32BGRA, nil, &optional)
        guard status == kCVReturnSuccess, let buffer = optional else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let colors: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 255),   // red (BGRA)
            (0, 255, 0),   // green
            (255, 0, 0),   // blue
            (0, 255, 255)  // yellow
        ]
        let (blue, green, red) = colors[second]
        for row in 0..<180 {
            for column in 0..<320 {
                let position = row * stride + column * 4
                bytes[position] = blue
                bytes[position + 1] = green
                bytes[position + 2] = red
                bytes[position + 3] = 255
            }
        }
        return buffer
    }

    private static func audioFormat() throws -> CMAudioFormatDescription {
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        let result = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard result == noErr, let format else { throw FixtureError.audioSampleFailed }
        return format
    }

    private static func makeAudioSample(startSample: Int, sampleCount: Int,
                                        format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let time = Double(startSample + index) / 48_000
            samples[index] = Int16(sin(2 * .pi * 440 * time) * 8_000)
        }
        var block: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Int16>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw FixtureError.audioSampleFailed
        }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { throw FixtureError.audioSampleFailed }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: 48_000),
            decodeTimeStamp: .invalid)
        var sampleSize = 2
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: sampleCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &result)
        guard status == noErr, let result else { throw FixtureError.audioSampleFailed }
        return result
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput,
                                       writer: AVAssetWriter, label: String, frame: Int) async throws {
        let limit = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < limit else {
                throw writer.error ?? FixtureError.notReady("\(label) frame \(frame), status \(writer.status.rawValue)")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func centerPixel(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var pixels = [UInt8](repeating: 0, count: 4)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        precondition(success)
        return (pixels[0], pixels[1], pixels[2])
    }

    private static func assertThrows(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") }
        catch { }
    }

    private enum FixtureError: Error { case writerFailed, audioSampleFailed, notReady(String) }

    private final class WriterBox: @unchecked Sendable {
        let value: AVAssetWriter
        init(_ value: AVAssetWriter) { self.value = value }
    }
}
