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
        if CommandLine.arguments.contains("--fps-only") {
            try await checkFrameRateConversions(folder: folder, selection: selection)
            print("NativeScreenshotVideoSegmentRegression FPS passed")
            return
        }
        if CommandLine.arguments.contains("--styles-only") {
            try await checkStyledEffects(folder: folder, source: source)
            return
        }
        let cut = NativeScreenshotVideoEffectSegment(start: 1.2, end: 1.6, content: .cut)
        let speed = NativeScreenshotVideoEffectSegment(start: 2, end: 3,
                                                       content: .speed(2))
        let cutSpeedEffects = NativeScreenshotVideoEffects(segments: [cut, speed])
        let cutSpeedDuration = try NativeScreenshotVideoSegmentExporter.expectedOutputDuration(
            selection: selection, effects: cutSpeedEffects)
        precondition(abs(cutSpeedDuration - 1.1) < 0.001,
                     "Cut and speed segments produced wrong timeline: \(cutSpeedDuration)")
        assertThrows {
            _ = try NativeScreenshotVideoEffects(
                freezeAt: 1.3, segments: [cut]).validated(for: selection)
        }
        assertThrows {
            _ = try NativeScreenshotVideoEffects(segments: [speed,
                .init(start: 2.5, end: 3, content: .speed(0.5))])
                .validated(for: selection)
        }

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

        let mutedURL = folder.appendingPathComponent("muted.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: mutedURL, selection: selection,
            quality: .lossless, effects: NativeScreenshotVideoEffects(muteAudio: true),
            progress: { _ in })
        let mutedAsset = AVURLAsset(url: mutedURL)
        let mutedTracks = try await mutedAsset.loadTracks(withMediaType: .audio)
        precondition(mutedTracks.isEmpty, "Mute must remove audio from the exported movie")

        let cutSpeedURL = folder.appendingPathComponent("cut-speed.mp4")
        var cutSpeedPicture = cutSpeedEffects
        cutSpeedPicture.segments.append(.init(start: 2, end: 3,
            content: .redaction(CGRect(x: 0.4, y: 0.4,
                                       width: 0.2, height: 0.2))))
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: cutSpeedURL, selection: selection,
            quality: .high, effects: cutSpeedPicture, progress: { _ in })
        let cutSpeedAsset = AVURLAsset(url: cutSpeedURL)
        let cutSpeedActual = try await cutSpeedAsset.load(.duration).seconds
        precondition(abs(cutSpeedActual - 1.1) < 0.16,
                     "Cut/speed export duration was \(cutSpeedActual), expected 1.1")
        let cutSpeedAudio = try await cutSpeedAsset.loadTracks(withMediaType: .audio)
        precondition(cutSpeedAudio.count == 1,
                     "Cut/speed export lost audio")
        let cutSpeedGenerator = AVAssetImageGenerator(asset: cutSpeedAsset)
        cutSpeedGenerator.appliesPreferredTrackTransform = true
        // Without exact sampling, AVAssetImageGenerator may return the keyframe
        // at the start of the speed segment for a later requested timestamp.
        cutSpeedGenerator.requestedTimeToleranceBefore = .zero
        cutSpeedGenerator.requestedTimeToleranceAfter = .zero
        let early = try cutSpeedGenerator.copyCGImage(
            at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
        let late = try cutSpeedGenerator.copyCGImage(
            at: CMTime(seconds: 0.8, preferredTimescale: 600), actualTime: nil)
        let earlyPixel = centerPixel(early)
        let latePixel = centerPixel(late)
        precondition(earlyPixel.green > earlyPixel.red + 30,
                     "Cut/speed export skipped the wrong source frame: \(earlyPixel)")
        precondition(latePixel.red < 50 && latePixel.green < 50 && latePixel.blue < 50,
                     "Picture segment moved after cut/speed mapping: \(latePixel)")
        if CommandLine.arguments.contains("--cut-speed-only") {
            print("NativeScreenshotVideoSegmentRegression cut/speed passed")
            return
        }

        let effectsURL = folder.appendingPathComponent("edited.mp4")
        let effects = NativeScreenshotVideoEffects(
            speed: 2, freezeAt: 2, freezeDuration: 0.5, zoom: 1.2,
            redaction: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            text: "Test", textPosition: CGPoint(x: 0.05, y: 0.1),
            outputScale: 0.5, framesPerSecond: 30)
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: effectsURL, selection: selection,
            quality: .high, effects: effects, progress: { _ in })
        let withAudio = AVURLAsset(url: effectsURL)
        let withAudioDuration = try await withAudio.load(.duration).seconds
        let withAudioTracks = try await withAudio.loadTracks(withMediaType: .audio)
        precondition(abs(withAudioDuration - 1.5) < 0.15
                     && withAudioTracks.count == 1,
                     "Freeze with audio lost its timeline or audio track")
        let leadingAudio = try await audioRMS(
            in: withAudio, track: withAudioTracks[0], start: 0.18, duration: 0.1)
        let frozenAudio = try await audioRMS(
            in: withAudio, track: withAudioTracks[0], start: 0.68, duration: 0.1)
        let trailingAudio = try await audioRMS(
            in: withAudio, track: withAudioTracks[0], start: 1.18, duration: 0.1)
        precondition(leadingAudio > 1_000 && frozenAudio < 300
                     && trailingAudio > 1_000,
                     "Freeze audio timeline is wrong: \(leadingAudio), \(frozenAudio), \(trailingAudio)")
        let sourceRateFreeze = NativeScreenshotVideoEffects(
            freezeAt: 1.95, freezeDuration: 0.4,
            framesPerSecond: 15, frameRateRequested: true)
        let sourceRateURL = folder.appendingPathComponent("freeze-audio-15fps.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: sourceRateURL,
            selection: selection, quality: .high,
            effects: sourceRateFreeze, progress: { _ in })
        let sourceRateAsset = AVURLAsset(url: sourceRateURL)
        let sourceRateExpected = try NativeScreenshotVideoSegmentExporter
            .expectedOutputDuration(selection: selection, effects: sourceRateFreeze)
        let sourceRateDuration = try await sourceRateAsset.load(.duration).seconds
        let sourceRateTrack = try await sourceRateAsset
            .loadTracks(withMediaType: .video).first!
        let sourceRateFPS = try await sourceRateTrack.load(.nominalFrameRate)
        let sourceRateAudio = try await sourceRateAsset
            .loadTracks(withMediaType: .audio).first!
        precondition(abs(sourceRateDuration - sourceRateExpected) < 0.08
                     && abs(sourceRateFPS - 15) < 1,
                     "Explicit FPS freeze changed duration or cadence")
        let simpleBefore = try await audioRMS(
            in: sourceRateAsset, track: sourceRateAudio,
            start: 0.3, duration: 0.1)
        let simpleFreeze = try await audioRMS(
            in: sourceRateAsset, track: sourceRateAudio,
            start: 1.1, duration: 0.1)
        let simpleAfter = try await audioRMS(
            in: sourceRateAsset, track: sourceRateAudio,
            start: 1.55, duration: 0.1)
        precondition(simpleBefore > 1_000 && simpleFreeze < 300
                     && simpleAfter > 1_000,
                     "Explicit FPS freeze audio was mistimed")
        let frozenPicture = centerPixel(try movieFrame(at: sourceRateURL, second: 1.1))
        let resumedPicture = centerPixel(try movieFrame(at: sourceRateURL, second: 1.55))
        precondition(frozenPicture.green > frozenPicture.blue + 30
                     && resumedPicture.blue > resumedPicture.green + 30,
                     "Freeze picture or following scene did not resume correctly")

        let dualSource = folder.appendingPathComponent("dual-short.mp4")
        try await makeFixture(
            at: dualSource, additionalAudioStart: 0.378,
            additionalAudioEnd: 1.6)
        let dualSourceTracks = try await AVURLAsset(url: dualSource)
            .loadTracks(withMediaType: .audio)
        precondition(dualSourceTracks.count == 2)
        let dualSelection = try NativeScreenshotVideoSelection(
            start: 0, end: 2, duration: 4)
        let dualEffects = NativeScreenshotVideoEffects(
            speed: 2, freezeAt: 1, freezeDuration: 0.5)
        let dualURL = folder.appendingPathComponent("dual-short-freeze.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: dualSource, destinationURL: dualURL,
            selection: dualSelection, quality: .high,
            effects: dualEffects, progress: { _ in })
        let dualAsset = AVURLAsset(url: dualURL)
        let dualExpected = try NativeScreenshotVideoSegmentExporter
            .expectedOutputDuration(selection: dualSelection, effects: dualEffects)
        let dualDuration = try await dualAsset.load(.duration).seconds
        let dualTracks = try await dualAsset.loadTracks(withMediaType: .audio)
        precondition(abs(dualDuration - dualExpected) < 0.08
                     && dualTracks.count == 2,
                     "Delayed short audio track was lost")
        let second = dualTracks[1]
        let secondEarly = try await audioRMS(
            in: dualAsset, track: second, start: 0.1, duration: 0.06)
        let secondBefore = try await audioRMS(
            in: dualAsset, track: second, start: 0.25, duration: 0.08)
        let secondFreeze = try await audioRMS(
            in: dualAsset, track: second, start: 0.7, duration: 0.1)
        let secondAfter = try await audioRMS(
            in: dualAsset, track: second, start: 1.13, duration: 0.08)
        let secondTail = try await audioRMS(
            in: dualAsset, track: second, start: 1.38, duration: 0.06)
        precondition(secondEarly < 300 && secondBefore > 1_000
                     && secondFreeze < 300 && secondAfter > 1_000
                     && secondTail < 300,
                     "Delayed short track timing is wrong: \(secondEarly), \(secondBefore), \(secondFreeze), \(secondAfter), \(secondTail)")
        if CommandLine.arguments.contains("--freeze-audio-only") {
            print("NativeScreenshotVideoSegmentRegression freeze audio passed")
            return
        }
        var mutedEffects = effects
        mutedEffects.muteAudio = true
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: effectsURL, selection: selection,
            quality: .high, effects: mutedEffects, progress: { _ in })
        let edited = AVURLAsset(url: effectsURL)
        let editedDuration = try await edited.load(.duration).seconds
        let editedAudio = try await edited.loadTracks(withMediaType: .audio)
        let editedVideo = try await edited.loadTracks(withMediaType: .video)
        precondition(abs(editedDuration - 1.5) < 0.18,
                     "Unexpected edited duration: \(editedDuration)")
        precondition(editedAudio.isEmpty && editedVideo.count == 1,
                     "Muted freeze export has the wrong track layout")
        let editedSize = try await editedVideo[0].load(.naturalSize)
        precondition(abs(editedSize.width - 160) <= 2 && abs(editedSize.height - 90) <= 2,
                     "Unexpected edited dimensions: \(editedSize)")
        let editedGenerator = AVAssetImageGenerator(asset: edited)
        editedGenerator.appliesPreferredTrackTransform = true
        let editedFrame = try editedGenerator.copyCGImage(
            at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
        guard let center = editedFrame.cropping(to: CGRect(
            x: editedFrame.width / 2, y: editedFrame.height / 2,
            width: 1, height: 1)) else { fatalError("Cannot sample edited frame") }
        let coveredCenter = centerPixel(center)
        precondition(coveredCenter.red < 50 && coveredCenter.green < 50
                     && coveredCenter.blue < 50,
                     "Redaction was not rendered: \(coveredCenter)")

        let editedGIFURL = folder.appendingPathComponent("edited.gif")
        let shortSelection = try NativeScreenshotVideoSelection(start: 1, end: 1.5,
                                                                duration: 4)
        try await NativeScreenshotVideoSegmentExporter.exportEditedGIF(
            sourceURL: source, destinationURL: editedGIFURL,
            selection: shortSelection,
            effects: NativeScreenshotVideoEffects(
                redaction: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)),
            framesPerSecond: 10, maximumDimension: 320, progress: { _ in })
        guard let editedGIF = CGImageSourceCreateWithURL(editedGIFURL as CFURL, nil),
              let firstEditedGIF = CGImageSourceCreateImageAtIndex(editedGIF, 0, nil),
              let gifCenter = firstEditedGIF.cropping(to: CGRect(
                x: firstEditedGIF.width / 2, y: firstEditedGIF.height / 2,
                width: 1, height: 1)) else { fatalError("Edited GIF cannot be opened") }
        precondition(CGImageSourceGetCount(editedGIF) == 5,
                     "Edited GIF frame count is wrong")
        let coveredGIFCenter = centerPixel(gifCenter)
        precondition(coveredGIFCenter.red < 50 && coveredGIFCenter.green < 50
                     && coveredGIFCenter.blue < 50,
                     "GIF redaction was not rendered: \(coveredGIFCenter)")

        let segmentedURL = folder.appendingPathComponent("segmented.mp4")
        let timedCover = NativeScreenshotVideoEffectSegment(
            start: 1, end: 2,
            content: .redaction(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: segmentedURL, selection: selection,
            quality: .high, effects: NativeScreenshotVideoEffects(segments: [timedCover]),
            progress: { _ in })
        let segmentedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: segmentedURL))
        segmentedGenerator.appliesPreferredTrackTransform = true
        segmentedGenerator.requestedTimeToleranceBefore = .zero
        segmentedGenerator.requestedTimeToleranceAfter = .zero
        let covered = try segmentedGenerator.copyCGImage(
            at: CMTime(seconds: 0.4, preferredTimescale: 600), actualTime: nil)
        let clear = try segmentedGenerator.copyCGImage(
            at: CMTime(seconds: 1.4, preferredTimescale: 600), actualTime: nil)
        let coveredPixel = centerPixel(covered)
        let clearPixel = centerPixel(clear)
        precondition(coveredPixel.red < 50 && coveredPixel.green < 50
                     && coveredPixel.blue < 50,
                     "Timed redaction did not cover the first segment: \(coveredPixel)")
        precondition(clearPixel.blue > clearPixel.red + 30
                     && clearPixel.blue > clearPixel.green + 30,
                     "Timed redaction leaked into the following segment: \(clearPixel)")

        let quarterURL = folder.appendingPathComponent("quarter-size.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: quarterURL, selection: selection,
            quality: .high, effects: NativeScreenshotVideoEffects(outputScale: 0.25),
            progress: { _ in })
        let quarterTrack = try await AVURLAsset(url: quarterURL)
            .loadTracks(withMediaType: .video).first!
        let quarterSize = try await quarterTrack.load(.naturalSize)
        precondition(Int(quarterSize.width) % 2 == 0 && Int(quarterSize.height) % 2 == 0,
                     "Quarter-size export must have codec-compatible even dimensions")

        try await checkStyledEffects(folder: folder, source: source)
        try await checkFrameRateConversions(folder: folder, selection: selection)

        print("NativeScreenshotVideoSegmentRegression passed")
    }

    private static func checkFrameRateConversions(
        folder: URL, selection: NativeScreenshotVideoSelection
    ) async throws {
        let source24 = folder.appendingPathComponent("source-24fps.mp4")
        try await makeFixture(at: source24, framesPerSecond: 24)
        let retained24 = folder.appendingPathComponent("retained-24fps.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source24, destinationURL: retained24, selection: selection,
            quality: .high, progress: { _ in })
        try await assertVideoMetadata(at: retained24, fps: 24, frames: 48,
                                      audioTracks: 1, tolerance: 2)
        for fps in [15, 30, 60] {
            let converted = folder.appendingPathComponent("converted-\(fps)fps.mp4")
            try await NativeScreenshotVideoSegmentExporter.exportMP4(
                sourceURL: source24, destinationURL: converted, selection: selection,
                quality: .high,
                effects: NativeScreenshotVideoEffects(framesPerSecond: fps,
                                                      frameRateRequested: true),
                progress: { _ in })
            try await assertVideoMetadata(at: converted, fps: fps, frames: fps * 2,
                                          audioTracks: 1)
        }
        let covered = folder.appendingPathComponent("converted-covered.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source24, destinationURL: covered, selection: selection,
            quality: .high,
            effects: NativeScreenshotVideoEffects(
                redaction: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                framesPerSecond: 30, frameRateRequested: true),
            progress: { _ in })
        try await assertVideoMetadata(at: covered, fps: 30, frames: 60,
                                      audioTracks: 1)
        let coveredGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: covered))
        let coveredFrame = try coveredGenerator.copyCGImage(
            at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let coveredPixel = centerPixel(coveredFrame)
        precondition(coveredPixel.red < 50 && coveredPixel.green < 50
                     && coveredPixel.blue < 50,
                     "FPS conversion skipped the selected redaction")

        let cutSpeed = NativeScreenshotVideoEffects(framesPerSecond: 30,
            frameRateRequested: true,
            segments: [
                .init(start: 1.2, end: 1.6, content: .cut),
                .init(start: 2, end: 3, content: .speed(2))
            ])
        let cutSpeedURL = folder.appendingPathComponent("converted-cut-speed.mp4")
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source24, destinationURL: cutSpeedURL, selection: selection,
            quality: .high, effects: cutSpeed, progress: { _ in })
        try await assertVideoMetadata(at: cutSpeedURL, fps: 30, frames: 33,
                                      audioTracks: 1, expectedDuration: 1.1)
    }

    private static func checkStyledEffects(folder: URL, source: URL) async throws {
        let selection = try NativeScreenshotVideoSelection(start: 1, end: 2, duration: 4)
        assertThrows {
            _ = try NativeScreenshotVideoEffects(redactionStyle: .init(fadeIn: -1))
                .validated(for: selection)
        }
        assertThrows {
            _ = try NativeScreenshotVideoEffects(textStyle: .init(fontSize: 500))
                .validated(for: selection)
        }

        let fadeURL = folder.appendingPathComponent("styled-fade.mp4")
        let fadeStyle = NativeScreenshotVideoRedactionStyle(
            kind: .solid, color: .black, fadeIn: 0.35, fadeOut: 0.35)
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: fadeURL, selection: selection,
            quality: .high,
            effects: .init(redaction: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3),
                           redactionStyle: fadeStyle),
            progress: { _ in })
        let fadedStart = try movieFrame(at: fadeURL, second: 0.04)
        let fadedMiddle = try movieFrame(at: fadeURL, second: 0.48)
        let fadedEnd = try movieFrame(at: fadeURL, second: 0.9)
        let start = centerPixel(fadedStart)
        let middle = centerPixel(fadedMiddle)
        let end = centerPixel(fadedEnd)
        precondition(start.green > middle.green + 40 && end.green > middle.green + 30,
                     "Redaction fades did not reach the encoded movie")
        precondition(middle.red < 50 && middle.green < 50 && middle.blue < 50)

        let patternedURL = folder.appendingPathComponent("patterned.mp4")
        try await makeFixture(at: patternedURL, patterned: true)
        let sourceFrame = try movieFrame(at: patternedURL, second: 1.5)
        for kind in [NativeScreenshotVideoRedactionStyle.Kind.pixelate, .blur] {
            let output = folder.appendingPathComponent("styled-\(kind).mp4")
            try await NativeScreenshotVideoSegmentExporter.exportMP4(
                sourceURL: patternedURL, destinationURL: output, selection: selection,
                quality: .high,
                effects: .init(redaction: CGRect(x: 0.35, y: 0.35,
                                                 width: 0.3, height: 0.3),
                               redactionStyle: .init(kind: kind)),
                progress: { _ in })
            let frame = try movieFrame(at: output, second: 0.5)
            let changed = differingPixels(
                sourceFrame, frame, area: CGRect(x: 112, y: 63, width: 96, height: 54))
            precondition(changed > 20,
                         "\(kind) did not change the encoded region: \(changed) pixels")
            let originalOutside = pixel(sourceFrame, x: 20, y: 20)
            let outputOutside = pixel(frame, x: 20, y: 20)
            precondition(abs(Int(originalOutside.red) - Int(outputOutside.red)) < 35,
                         "\(kind) changed pixels outside the redaction")
        }

        let textURL = folder.appendingPathComponent("styled-text.mp4")
        let textStyle = NativeScreenshotVideoTextStyle(
            fontSize: 120, bold: false, italic: true,
            textColor: .init(red: 1, green: 0, blue: 0, alpha: 1),
            background: .rectangle,
            backgroundColor: .init(red: 0, green: 0, blue: 1, alpha: 1),
            alignment: .right, boxWidth: 0.55,
            fadeIn: 0.35, fadeOut: 0.35)
        try await NativeScreenshotVideoSegmentExporter.exportMP4(
            sourceURL: source, destinationURL: textURL, selection: selection,
            quality: .high,
            effects: .init(text: "STYLE", textPosition: CGPoint(x: 0.1, y: 0.1),
                           textStyle: textStyle),
            progress: { _ in })
        let textFrame = try movieFrame(at: textURL, second: 0.5)
        let colors = dominantColorCounts(textFrame)
        precondition(colors.red > 15 && colors.blue > 100,
                     "Styled text or background did not reach the encoded movie: \(colors)")
        let openingText = dominantColorCounts(
            try movieFrame(at: textURL, second: 0.04))
        precondition(openingText.red < colors.red / 2,
                     "Text fade-in did not reach the encoded movie")
        print("NativeScreenshotVideoSegmentRegression styles passed")
    }

    private static func movieFrame(at url: URL, second: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: second, preferredTimescale: 600),
            actualTime: nil)
    }

    private static func pixel(
        _ image: CGImage, x: Int, y: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { fatalError("Cannot crop test pixel") }
        return centerPixel(crop)
    }

    private static func dominantColorCounts(_ image: CGImage) -> (red: Int, blue: Int) {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let success = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: image.width, height: image.height))
            return true
        }
        precondition(success)
        var red = 0
        var blue = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if Int(bytes[offset]) > Int(bytes[offset + 1]) + 55
                && Int(bytes[offset]) > Int(bytes[offset + 2]) + 55 { red += 1 }
            if Int(bytes[offset + 2]) > Int(bytes[offset + 1]) + 55
                && Int(bytes[offset + 2]) > Int(bytes[offset]) + 55 { blue += 1 }
        }
        return (red, blue)
    }

    private static func differingPixels(
        _ first: CGImage, _ second: CGImage, area: CGRect
    ) -> Int {
        precondition(first.width == second.width && first.height == second.height)
        func bytes(_ image: CGImage) -> [UInt8] {
            let stride = image.width * 4
            var buffer = [UInt8](repeating: 0, count: stride * image.height)
            let success = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: stride,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0,
                                               width: image.width, height: image.height))
                return true
            }
            precondition(success)
            return buffer
        }
        let a = bytes(first)
        let b = bytes(second)
        var changed = 0
        for y in stride(from: Int(area.minY), to: Int(area.maxY), by: 4) {
            for x in stride(from: Int(area.minX), to: Int(area.maxX), by: 4) {
                let offset = (y * first.width + x) * 4
                if abs(Int(a[offset]) - Int(b[offset])) > 50 {
                    changed += 1
                }
            }
        }
        return changed
    }

    private static func makeFixture(
        at url: URL, framesPerSecond: Int = 30, patterned: Bool = false,
        additionalAudioStart: Double? = nil, additionalAudioEnd: Double = 4
    ) async throws {
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
        let extraAudio: AVAssetWriterInput? = additionalAudioStart.map { _ in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = false
            return input
        }
        precondition(writer.canAdd(video) && writer.canAdd(audio)
                     && (extraAudio.map(writer.canAdd) ?? true))
        writer.add(video)
        writer.add(audio)
        if let extraAudio { writer.add(extraAudio) }
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let format = try audioFormat()
        try await waitUntilReady(audio, writer: writer, label: "audio", frame: 0)
        let sound = try makeAudioSample(startSample: 0, sampleCount: 192_000, format: format)
        guard audio.append(sound) else { throw writer.error ?? FixtureError.writerFailed }
        audio.markAsFinished()
        if let extraAudio, let additionalAudioStart {
            let firstFrame = Int((additionalAudioStart * 48_000).rounded())
            let frameCount = Int(((additionalAudioEnd - additionalAudioStart)
                * 48_000).rounded())
            guard frameCount > 0 else { throw FixtureError.audioSampleFailed }
            try await waitUntilReady(extraAudio, writer: writer,
                                     label: "extra audio", frame: 0)
            let extra = try makeAudioSample(
                startSample: firstFrame, sampleCount: frameCount,
                format: format)
            guard extraAudio.append(extra) else {
                throw writer.error ?? FixtureError.writerFailed
            }
            extraAudio.markAsFinished()
        }
        for frame in 0..<(framesPerSecond * 4) {
            try await waitUntilReady(video, writer: writer, label: "video", frame: frame)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond))
            guard let buffer = makePixelBuffer(
                second: frame / framesPerSecond, patterned: patterned),
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

    private static func makePixelBuffer(
        second: Int, patterned: Bool = false
    ) -> CVPixelBuffer? {
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
                if patterned {
                    let value: UInt8 = ((row / 12 + column / 12) % 2 == 0) ? 255 : 0
                    bytes[position] = value
                    bytes[position + 1] = value
                    bytes[position + 2] = value
                } else {
                    bytes[position] = blue
                    bytes[position + 1] = green
                    bytes[position + 2] = red
                }
                bytes[position + 3] = 255
            }
        }
        return buffer
    }

    private static func audioRMS(
        in asset: AVAsset, track: AVAssetTrack,
        start: Double, duration: Double
    ) async throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60_000),
            duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? FixtureError.writerFailed
        }
        var sum = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                let pointer else { continue }
            for index in 0..<(length / 2) {
                let amplitude = Double(pointer.withMemoryRebound(
                    to: Int16.self, capacity: length / 2) { $0[index] })
                sum += amplitude * amplitude
                count += 1
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? FixtureError.writerFailed
        }
        return count == 0 ? 0 : sqrt(sum / Double(count))
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

    private static func assertVideoMetadata(at url: URL, fps: Int, frames: Int,
                                            audioTracks: Int, tolerance: Int = 0,
                                            expectedDuration: Double = 2) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            fatalError("FPS export has no video: \(url.lastPathComponent)")
        }
        let nominal = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        precondition(abs(nominal - Float(fps)) < (tolerance == 0 ? 0.5 : 1.1),
                     "FPS export retained \(nominal) instead of \(fps)")
        precondition(abs(duration - expectedDuration) < 0.05,
                     "FPS export duration changed to \(duration)")
        precondition(audioCount == audioTracks,
                     "FPS export lost an audio track")
        // Decode the picture; compressed sample buffers can expose B-frame
        // reorder and invalid tail timestamps instead of display frames.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FixtureError.writerFailed }
        var frameIndices = Set<Int>()
        while let sample = output.copyNextSampleBuffer() {
            let second = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard second.isFinite, second >= 0, second < duration - 0.000_001 else {
                continue
            }
            frameIndices.insert(Int((second * Double(fps)).rounded()))
        }
        precondition(abs(frameIndices.count - frames) <= tolerance,
                     "FPS export contains \(frameIndices.count) frames; expected \(frames)")
    }

    private static func centerPixel(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        // Sampling the full frame into a 1×1 context averages its colors. Crop
        // first so a small center redaction is actually checked at its center.
        guard let sample = image.cropping(to: CGRect(x: image.width / 2,
                                                     y: image.height / 2,
                                                     width: 1, height: 1)) else {
            fatalError("Cannot crop center pixel")
        }
        var pixels = [UInt8](repeating: 0, count: 4)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
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
