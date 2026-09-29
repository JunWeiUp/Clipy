import AVFoundation
import AudioToolbox
import CoreImage
import CoreText
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

/// Normalized positions use the visible video's top-left as (0, 0).
/// All values are captured before export so a background encoder never reads UI state.
struct NativeScreenshotVideoColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = Self(red: 1, green: 1, blue: 1, alpha: 1)
    static let darkBackground = Self(red: 0, green: 0, blue: 0, alpha: 0.72)
    static let black = Self(red: 0, green: 0, blue: 0, alpha: 1)

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

struct NativeScreenshotVideoRedactionStyle: Equatable {
    enum Kind: CaseIterable { case solid, pixelate, blur }
    var kind: Kind = .solid
    var color: NativeScreenshotVideoColor = .black
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0

    var isValid: Bool {
        color.isValid && (kind != .solid || color.alpha >= 0.99)
            && fadeIn.isFinite && fadeOut.isFinite
            && (0...3).contains(fadeIn) && (0...3).contains(fadeOut)
    }

    func opacity(at second: TimeInterval, start: TimeInterval, end: TimeInterval) -> CGFloat {
        NativeScreenshotVideoEffectFade.opacity(
            at: second, start: start, end: end, fadeIn: fadeIn, fadeOut: fadeOut)
    }
}

struct NativeScreenshotVideoTextStyle: Equatable {
    enum Background: CaseIterable { case none, rectangle, rounded }
    enum Alignment: CaseIterable { case left, center, right }

    var fontSize: CGFloat = 48   // point size relative to a 1080 px video
    var bold = true
    var italic = false
    var textColor: NativeScreenshotVideoColor = .white
    var background: Background = .rounded
    var backgroundColor: NativeScreenshotVideoColor = .darkBackground
    var alignment: Alignment = .center
    var boxWidth: CGFloat = 0.5
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0

    var isValid: Bool {
        fontSize.isFinite && (12...160).contains(fontSize)
            && boxWidth.isFinite && (0.15...0.9).contains(boxWidth)
            && textColor.isValid && backgroundColor.isValid
            && fadeIn.isFinite && fadeOut.isFinite
            && (0...3).contains(fadeIn) && (0...3).contains(fadeOut)
    }

    func opacity(at second: TimeInterval, start: TimeInterval, end: TimeInterval) -> CGFloat {
        NativeScreenshotVideoEffectFade.opacity(
            at: second, start: start, end: end, fadeIn: fadeIn, fadeOut: fadeOut)
    }
}

private enum NativeScreenshotVideoEffectFade {
    static func opacity(
        at second: TimeInterval, start: TimeInterval, end: TimeInterval,
        fadeIn: TimeInterval, fadeOut: TimeInterval
    ) -> CGFloat {
        guard second >= start, second < end, end > start else { return 0 }
        let half = max(0, (end - start) / 2 - 0.001)
        let entrance = min(fadeIn, half)
        let exit = min(fadeOut, half)
        let linear: Double
        if entrance > 0, second - start < entrance {
            linear = (second - start) / entrance
        } else if exit > 0, end - second < exit {
            linear = (end - second) / exit
        } else {
            linear = 1
        }
        let value = max(0, min(1, linear))
        return CGFloat(value * value * (3 - 2 * value))
    }
}

struct NativeScreenshotVideoEffectSegment {
    enum Content {
        case cut
        case speed(Double)
        case zoom(CGFloat)
        case redaction(CGRect)
        case text(String, CGPoint)
        case styledRedaction(CGRect, NativeScreenshotVideoRedactionStyle)
        case styledText(String, CGPoint, NativeScreenshotVideoTextStyle)
    }

    var start: TimeInterval
    var end: TimeInterval
    var content: Content

    func contains(_ sourceSecond: TimeInterval) -> Bool {
        sourceSecond >= start && sourceSecond < end
    }
}

struct NativeScreenshotVideoEffects {
    var speed: Double = 1
    var muteAudio = false
    var freezeAt: TimeInterval?
    var freezeDuration: TimeInterval = 1
    var zoom: CGFloat = 1
    var redaction: CGRect?
    var redactionStyle = NativeScreenshotVideoRedactionStyle()
    var text: String = ""
    var textPosition: CGPoint = CGPoint(x: 0.06, y: 0.12)
    var textStyle = NativeScreenshotVideoTextStyle()
    var outputScale: CGFloat = 1
    var framesPerSecond: Int = 30
    /// `false` preserves the source frame rate when no other edit requires a
    /// video composition. An explicit 30 FPS choice must still re-encode a
    /// source recorded at 15, 24 or 60 FPS.
    var frameRateRequested = false
    var segments: [NativeScreenshotVideoEffectSegment] = []

    var changesTimeline: Bool {
        speed != 1 || freezeAt != nil || muteAudio || segments.contains {
            switch $0.content {
            case .cut, .speed: return true
            default: return false
            }
        }
    }
    var changesPicture: Bool {
        zoom != 1 || redaction != nil || !text.isEmpty
            || outputScale != 1 || framesPerSecond != 30 || frameRateRequested
            || segments.contains {
                switch $0.content {
                case .zoom, .redaction, .text, .styledRedaction, .styledText: return true
                default: return false
                }
            }
    }
    var needsProcessing: Bool { changesTimeline || changesPicture }
    var canPassthrough: Bool {
        !needsProcessing || (muteAudio && speed == 1 && freezeAt == nil
                             && segments.isEmpty
                             && !changesPicture)
    }

    func validated(for selection: NativeScreenshotVideoSelection) throws -> Self {
        guard speed.isFinite, (0.25...4).contains(speed),
              freezeDuration.isFinite, (0.1...5).contains(freezeDuration),
              zoom.isFinite, (1...3).contains(zoom),
              outputScale.isFinite, (0.25...2).contains(outputScale),
              (10...60).contains(framesPerSecond), text.count <= 120,
              redactionStyle.isValid, textStyle.isValid,
              textPosition.x.isFinite, textPosition.y.isFinite,
              (0...1).contains(textPosition.x), (0...1).contains(textPosition.y) else {
            throw NativeScreenshotVideoExportError.invalidEffects
        }
        if let freezeAt {
            guard freezeAt.isFinite, freezeAt >= selection.start,
                  freezeAt < selection.end - 0.04 else {
                throw NativeScreenshotVideoExportError.invalidEffects
            }
        }
        if let redaction {
            guard redaction.minX.isFinite, redaction.minY.isFinite,
                  redaction.width.isFinite, redaction.height.isFinite,
                  redaction.minX >= 0, redaction.minY >= 0,
                  redaction.maxX <= 1, redaction.maxY <= 1,
                  redaction.width >= 0.01, redaction.height >= 0.01 else {
                throw NativeScreenshotVideoExportError.invalidEffects
            }
        }
        guard segments.count <= 64 else { throw NativeScreenshotVideoExportError.invalidEffects }
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start else {
                throw NativeScreenshotVideoExportError.invalidEffects
            }
            switch segment.content {
            case .cut: break
            case .speed(let value):
                guard value.isFinite, (0.25...4).contains(value) else {
                    throw NativeScreenshotVideoExportError.invalidEffects
                }
            case .zoom(let value):
                guard value.isFinite, (1...3).contains(value) else {
                    throw NativeScreenshotVideoExportError.invalidEffects
                }
            case .redaction(let rect):
                guard rect.minX.isFinite, rect.minY.isFinite,
                      rect.width.isFinite, rect.height.isFinite,
                      rect.minX >= 0, rect.minY >= 0,
                      rect.maxX <= 1, rect.maxY <= 1,
                      rect.width >= 0.01, rect.height >= 0.01 else {
                    throw NativeScreenshotVideoExportError.invalidEffects
                }
            case .styledRedaction(let rect, let style):
                guard style.isValid, rect.minX.isFinite, rect.minY.isFinite,
                      rect.width.isFinite, rect.height.isFinite,
                      rect.minX >= 0, rect.minY >= 0,
                      rect.maxX <= 1, rect.maxY <= 1,
                      rect.width >= 0.01, rect.height >= 0.01 else {
                    throw NativeScreenshotVideoExportError.invalidEffects
                }
            case .text(let value, let position):
                guard !value.isEmpty, value.count <= 120,
                      position.x.isFinite, position.y.isFinite,
                      (0...1).contains(position.x),
                      (0...1).contains(position.y) else {
                    throw NativeScreenshotVideoExportError.invalidEffects
                }
            case .styledText(let value, let position, let style):
                guard style.isValid, !value.isEmpty, value.count <= 120,
                      position.x.isFinite, position.y.isFinite,
                      (0...1).contains(position.x),
                      (0...1).contains(position.y) else {
                    throw NativeScreenshotVideoExportError.invalidEffects
                }
            }
        }
        let speedSegments = segments.filter {
            if case .speed = $0.content { return true }
            return false
        }.sorted { $0.start < $1.start }
        for pair in zip(speedSegments, speedSegments.dropFirst()) {
            guard pair.0.end <= pair.1.start else {
                throw NativeScreenshotVideoExportError.invalidEffects
            }
        }
        if let freezeAt, segments.contains(where: {
            if case .cut = $0.content { return $0.contains(freezeAt) }
            return false
        }) {
            throw NativeScreenshotVideoExportError.invalidEffects
        }
        return self
    }

}

enum NativeScreenshotVideoExportError: LocalizedError {
    case invalidSelection
    case invalidEffects
    case unsupportedFormat
    case exportFailed(String)
    case gifTooLong
    case freezeAudioUnsupported
    case frameRateConversionUnsupported

    var errorDescription: String? {
        let zh = NativeScreenshotUserText.string
        switch self {
        case .invalidSelection: return zh("请先选择至少 0.1 秒的有效片段。", "Select a valid segment of at least 0.1 seconds.")
        case .invalidEffects: return zh("视频编辑参数无效，请检查片段范围和效果设置。", "Video edit settings are invalid. Check the clip range and effects.")
        case .unsupportedFormat: return zh("该录屏不支持所选导出格式。", "This recording does not support the selected export format.")
        case .exportFailed(let reason): return zh("导出失败：", "Export failed: ") + reason
        case .gifTooLong: return zh("GIF 片段最长为 120 秒。", "GIF segments are limited to 120 seconds.")
        case .freezeAudioUnsupported:
            return zh("无法安全合成此录屏的定格画面和音轨；可开启“静音”后重试，原文件未更改。",
                      "This recording's freeze frame and audio could not be combined safely. Enable Mute and retry; the original file is unchanged.")
        case .frameRateConversionUnsupported:
            return zh("当前录屏暂不能转换为所选 MP4 帧率；请改用“原帧率”导出。",
                      "This recording cannot be converted to the selected MP4 frame rate; export at Source FPS instead.")
        }
    }
}

enum NativeScreenshotVideoSegmentExporter {
    enum MP4Quality { case lossless, standard, high }

    static func expectedOutputDuration(
        selection: NativeScreenshotVideoSelection,
        effects: NativeScreenshotVideoEffects
    ) throws -> TimeInterval {
        let effects = try effects.validated(for: selection)
        guard effects.changesTimeline else { return selection.duration }
        guard let last = try buildTimelineParts(selection: selection, effects: effects).last else {
            throw NativeScreenshotVideoExportError.invalidEffects
        }
        return last.outputStart + last.outputDuration
    }

    // AVAssetExportSession's callback and cancellation are explicitly concurrent.
    // Its own status/progress/cancel API is designed for that usage.
    private final class SessionBox: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    private final class WriterBox: @unchecked Sendable {
        let value: AVAssetWriter
        init(_ value: AVAssetWriter) { self.value = value }
    }

    private final class ReaderBox: @unchecked Sendable {
        let value: AVAssetReader
        init(_ value: AVAssetReader) { self.value = value }
    }

    private final class ExportCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            let completed = result
            if completed == nil { self.continuation = continuation }
            lock.unlock()
            if let completed { continuation.resume(with: completed) }
        }

        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: result)
        }
    }

    private static func freezeAudioDiagnostic(_ message: String) {
        guard ProcessInfo.processInfo.environment["CLIPY_VIDEO_DEBUG"] == "1" else {
            return
        }
        fputs("NativeScreenshot freeze audio: \(message)\n", stderr)
    }

    /// Writes next to the destination, then moves the complete file into place.
    static func exportMP4(
        sourceURL: URL, destinationURL: URL, selection: NativeScreenshotVideoSelection,
        quality: MP4Quality, effects: NativeScreenshotVideoEffects = .init(),
        progress: @escaping (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard sourceURL.isFileURL, destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "mp4" else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let effects = try effects.validated(for: selection)
        guard effects.canPassthrough || quality != .lossless else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let source = AVURLAsset(url: sourceURL)
        if effects.freezeAt != nil && !effects.muteAudio,
           !(try await source.loadTracks(withMediaType: .audio)).isEmpty {
            try await exportFreezeWithAudioMP4(
                source: source, destinationURL: destinationURL,
                selection: selection, quality: quality, effects: effects,
                progress: progress)
            return
        }
        if effects.frameRateRequested || effects.framesPerSecond != 30 {
            try await exportFrameRateConvertedMP4(
                source: source, destinationURL: destinationURL,
                selection: selection, quality: quality, effects: effects,
                progress: progress)
            return
        }
        let timeline = effects.changesTimeline
            ? try await makeTimelineComposition(source: source, selection: selection,
                                                effects: effects)
            : nil
        let exportAsset: AVAsset = timeline?.asset ?? source
        let preset: String
        switch quality {
        case .lossless: preset = AVAssetExportPresetPassthrough
        case .standard: preset = AVAssetExportPresetMediumQuality
        case .high: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset),
              session.supportedFileTypes.contains(.mp4) else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let box = SessionBox(session)
        let stagedURL = temporaryURL(beside: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        session.outputURL = stagedURL
        session.outputFileType = .mp4
        if !effects.changesTimeline { session.timeRange = selection.timeRange }
        session.shouldOptimizeForNetworkUse = false
        if effects.changesPicture {
            let sourceTrack = try await source.loadTracks(withMediaType: .video).first
            let sourceRate = try await sourceTrack?.load(.nominalFrameRate) ?? 30
            session.videoComposition = makeVideoComposition(asset: exportAsset,
                                                            effects: effects,
                                                            sourceFrameRate: sourceRate,
                                                            timelineParts: timeline?.parts,
                                                            selection: selection)
        }

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

    /// Keep the freeze video and source audio on separate AVFoundation passes.
    /// Exporting a composition with a time-scaled video slice and audio holes
    /// in one pass can fail or never finish on supported macOS versions.
    private static func exportFreezeWithAudioMP4(
        source: AVURLAsset, destinationURL: URL,
        selection: NativeScreenshotVideoSelection, quality: MP4Quality,
        effects: NativeScreenshotVideoEffects,
        progress: @escaping (Double) -> Void
    ) async throws {
        var pictureEffects = effects
        pictureEffects.muteAudio = true
        let timeline = try await makeTimelineComposition(
            source: source, selection: selection, effects: pictureEffects)
        let duration = try expectedOutputDuration(selection: selection, effects: effects)
        guard let pictureTrack = try await timeline.asset.loadTracks(
                withMediaType: .video).first,
              let sourceTrack = try await source.loadTracks(
                withMediaType: .video).first else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let sourceRate = try await sourceTrack.load(.nominalFrameRate)
        let frameRate = effects.frameRateRequested || effects.framesPerSecond != 30
            ? effects.framesPerSecond
            : max(10, min(60, Int(sourceRate.isFinite && sourceRate > 0
                                    ? sourceRate.rounded() : 30)))
        let composition = makeVideoComposition(
            asset: timeline.asset, effects: pictureEffects,
            sourceFrameRate: sourceRate, timelineParts: timeline.parts,
            selection: selection)
        let pictureURL = temporaryURL(beside: destinationURL)
        let stagedURL = temporaryURL(beside: destinationURL)
        var audioTemporaryURLs: [URL] = []
        defer {
            try? FileManager.default.removeItem(at: pictureURL)
            try? FileManager.default.removeItem(at: stagedURL)
            for url in audioTemporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try await writeFixedRatePicture(
            asset: timeline.asset, videoTrack: pictureTrack,
            composition: composition,
            range: CMTimeRange(start: .zero, duration: time(duration)),
            framesPerSecond: frameRate, quality: quality,
            outputURL: pictureURL,
            progress: { progress($0 * 0.78) })
        freezeAudioDiagnostic("picture ready")
        try Task.checkCancellation()

        let picture = AVURLAsset(url: pictureURL)
        guard let encodedVideo = try await picture.loadTracks(
                withMediaType: .video).first else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        let mux = AVMutableComposition()
        let sourceAudioTracks = try await source.loadTracks(withMediaType: .audio)
        let silenceURL = temporaryURL(beside: destinationURL)
        audioTemporaryURLs.append(silenceURL)
        do {
            try await writeSilence(to: silenceURL, duration: 5)
        } catch {
            freezeAudioDiagnostic("silence writer failed: \(error)")
            throw error
        }
        freezeAudioDiagnostic("silence ready")
        guard let video = mux.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        do {
            try video.insertTimeRange(
                CMTimeRange(start: .zero, duration: time(duration)),
                of: encodedVideo, at: .zero)
            video.preferredTransform = try await encodedVideo.load(.preferredTransform)
            for (index, sourceAudio) in sourceAudioTracks.enumerated() {
                try Task.checkCancellation()
                let encodedAudioURL = temporaryURL(
                    beside: destinationURL.deletingPathExtension()
                        .appendingPathExtension("m4a"))
                audioTemporaryURLs.append(encodedAudioURL)
                try await exportFreezeAudioTrack(
                    sourceAudio: sourceAudio, silenceURL: silenceURL,
                    parts: timeline.parts, duration: duration,
                    destinationURL: encodedAudioURL)
                freezeAudioDiagnostic("audio track \(index) ready")
                let encodedAsset = AVURLAsset(url: encodedAudioURL)
                guard let encodedTrack = try await encodedAsset.loadTracks(
                        withMediaType: .audio).first,
                      let audio = mux.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw NativeScreenshotVideoExportError.freezeAudioUnsupported
                }
                let availableAudio = try await encodedTrack.load(.timeRange)
                let encodedDuration = availableAudio.end.seconds
                freezeAudioDiagnostic(
                    "audio track \(index) encoded end=\(encodedDuration), expected=\(duration)")
                guard encodedDuration.isFinite,
                      encodedDuration >= duration - 0.05 else {
                    throw NativeScreenshotVideoExportError.freezeAudioUnsupported
                }
                try audio.insertTimeRange(
                    CMTimeRange(start: .zero,
                                duration: time(min(duration, encodedDuration))),
                    of: encodedTrack, at: .zero)
                progress(0.78 + 0.17 * Double(index + 1)
                    / Double(sourceAudioTracks.count))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            freezeAudioDiagnostic("audio composition failed: \(error)")
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        guard let session = AVAssetExportSession(
                asset: mux, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        session.outputURL = stagedURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        session.timeRange = CMTimeRange(start: .zero, duration: time(duration))
        let box = SessionBox(session)
        let monitor = Task {
            while !Task.isCancelled {
                progress(0.95 + Double(box.value.progress) * 0.05)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { monitor.cancel() }
        do {
            try await exportSessionWithDeadline(
                box, seconds: max(45, min(600, duration * 2 + 30)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            freezeAudioDiagnostic("final mux failed: \(error)")
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        try Task.checkCancellation()
        let result = AVURLAsset(url: stagedURL)
        let resultDuration = try await result.load(.duration).seconds
        let audioCount = try await result.loadTracks(withMediaType: .audio).count
        guard resultDuration.isFinite,
              abs(resultDuration - duration) <= max(0.15, 2 / Double(frameRate)),
              audioCount == sourceAudioTracks.count,
              !(try await result.loadTracks(withMediaType: .video)).isEmpty else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        try commit(stagedURL, to: destinationURL)
        progress(1)
    }

    private static func exportSessionWithDeadline(
        _ box: SessionBox, seconds: TimeInterval
    ) async throws {
        let gate = ExportCompletionGate()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler {
            box.value.cancelExport()
            gate.finish(.failure(NativeScreenshotVideoExportError.freezeAudioUnsupported))
        }
        timer.resume()
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed: gate.finish(.success(()))
                    case .cancelled: gate.finish(.failure(CancellationError()))
                    default:
                        gate.finish(.failure(box.value.error
                            ?? NativeScreenshotVideoExportError.freezeAudioUnsupported))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func exportFreezeAudioTrack(
        sourceAudio: AVAssetTrack, silenceURL: URL,
        parts: [TimelinePart], duration: TimeInterval,
        destinationURL: URL
    ) async throws {
        let silenceAsset = AVURLAsset(url: silenceURL)
        let composition = AVMutableComposition()
        guard let silenceTrack = try await silenceAsset.loadTracks(
                withMediaType: .audio).first,
              let audio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        let available = try await sourceAudio.load(.timeRange)
        let availableStart = available.start.seconds
        let availableEnd = available.end.seconds
        let silenceCapacity = try await silenceTrack.load(.timeRange).duration.seconds
        guard silenceCapacity.isFinite, silenceCapacity >= 1 else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        func insertSilence(at outputStart: TimeInterval, duration: TimeInterval) throws {
            var offset = 0.0
            while duration - offset > 0.000_01 {
                let chunk = min(duration - offset, silenceCapacity - 0.01)
                guard chunk > 0 else {
                    throw NativeScreenshotVideoExportError.freezeAudioUnsupported
                }
                try audio.insertTimeRange(
                    CMTimeRange(start: .zero, duration: time(chunk)),
                    of: silenceTrack, at: time(outputStart + offset))
                offset += chunk
            }
        }
        do {
            for part in parts {
                try Task.checkCancellation()
                if !part.includesAudio {
                    try insertSilence(
                        at: part.outputStart, duration: part.outputDuration)
                    continue
                }
                let clippedStart = availableStart.isFinite
                    ? max(part.sourceStart, availableStart)
                    : part.sourceStart
                let clippedEnd = availableEnd.isFinite
                    ? min(part.sourceStart + part.sourceDuration, availableEnd)
                    : part.sourceStart + part.sourceDuration
                guard clippedEnd - clippedStart > 0.000_01 else {
                    try insertSilence(
                        at: part.outputStart, duration: part.outputDuration)
                    continue
                }
                let outputRatio = part.outputDuration / part.sourceDuration
                let mappedStart = part.outputStart
                    + (clippedStart - part.sourceStart) * outputRatio
                let mappedDuration = (clippedEnd - clippedStart) * outputRatio
                if mappedStart - part.outputStart > 0.000_01 {
                    try insertSilence(
                        at: part.outputStart,
                        duration: mappedStart - part.outputStart)
                }
                let sourceRange = CMTimeRange(
                    start: time(clippedStart),
                    duration: time(clippedEnd - clippedStart))
                let outputStart = time(mappedStart)
                try audio.insertTimeRange(
                    sourceRange, of: sourceAudio, at: outputStart)
                audio.scaleTimeRange(
                    CMTimeRange(start: outputStart,
                                duration: sourceRange.duration),
                    toDuration: time(mappedDuration))
                let partOutputEnd = part.outputStart + part.outputDuration
                if partOutputEnd - mappedStart - mappedDuration > 0.000_01 {
                    try insertSilence(
                        at: mappedStart + mappedDuration,
                        duration: partOutputEnd - mappedStart - mappedDuration)
                }
            }
            // AAC encoders may discard their final packet. Give the encoder
            // quiet tail material beyond the requested export range so the
            // final user-visible frame retains an audio timestamp.
            try insertSilence(at: duration, duration: 0.2)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            freezeAudioDiagnostic("track M4A failed: \(error)")
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        freezeAudioDiagnostic(
            "source audio composition end=\(composition.duration.seconds), track=\(audio.timeRange)")
        guard let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A),
              session.supportedFileTypes.contains(.m4a) else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        session.outputURL = destinationURL
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: .zero, duration: time(duration + 0.2))
        do {
            try await exportSessionWithDeadline(
                SessionBox(session), seconds: max(45, min(600, duration * 2 + 30)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
    }

    private static func writeSilence(
        to url: URL, duration: TimeInterval
    ) async throws {
        let rate: Int32 = 48_000
        let frameCount = Int(ceil(duration * Double(rate))) + 1_024
        guard frameCount > 0, frameCount <= 250_000 else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let box = WriterBox(writer)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }
        let readyDeadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing, Date() < readyDeadline else {
                throw writer.error ?? NativeScreenshotVideoExportError.freezeAudioUnsupported
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        var pcm = AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &pcm,
            layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr,
            let format else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        let byteCount = frameCount * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0,
            blockBufferOut: &block) == noErr,
            let block else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        let zeros = Data(repeating: 0, count: byteCount)
        let copied = zeros.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else {
            throw NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr,
            let sample, input.append(sample) else {
            throw writer.error ?? NativeScreenshotVideoExportError.freezeAudioUnsupported
        }
        input.markAsFinished()
        let gate = ExportCompletionGate()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler {
            box.value.cancelWriting()
            gate.finish(.failure(NativeScreenshotVideoExportError.freezeAudioUnsupported))
        }
        timer.resume()
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                box.value.finishWriting {
                    if box.value.status == .completed { gate.finish(.success(())) }
                    else {
                        gate.finish(.failure(box.value.error
                            ?? NativeScreenshotVideoExportError.freezeAudioUnsupported))
                    }
                }
            }
        } onCancel: {
            box.value.cancelWriting()
            gate.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
    }

    /// AVAssetExportSession may keep the source cadence even when
    /// videoComposition.frameDuration requests another one. Decode the edited
    /// picture and explicitly append one frame at every target timestamp, then
    /// remux the edited timeline's audio without touching its samples.
    private static func exportFrameRateConvertedMP4(
        source: AVURLAsset, destinationURL: URL,
        selection: NativeScreenshotVideoSelection, quality: MP4Quality,
        effects: NativeScreenshotVideoEffects,
        progress: @escaping (Double) -> Void
    ) async throws {
        let timeline = effects.changesTimeline
            ? try await makeTimelineComposition(source: source, selection: selection,
                                                effects: effects)
            : nil
        let exportAsset: AVAsset = timeline?.asset ?? source
        guard let videoTrack = try await exportAsset.loadTracks(withMediaType: .video).first,
              let sourceTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let sourceRate = try await sourceTrack.load(.nominalFrameRate)
        let composition = makeVideoComposition(asset: exportAsset, effects: effects,
                                               sourceFrameRate: sourceRate,
                                               timelineParts: timeline?.parts,
                                               selection: selection)
        let outputDuration = timeline == nil
            ? selection.duration
            : try expectedOutputDuration(selection: selection, effects: effects)
        let range = timeline == nil
            ? selection.timeRange
            : CMTimeRange(start: .zero, duration: time(outputDuration))
        let pictureURL = temporaryURL(beside: destinationURL)
        let stagedURL = temporaryURL(beside: destinationURL)
        defer {
            try? FileManager.default.removeItem(at: pictureURL)
            try? FileManager.default.removeItem(at: stagedURL)
        }
        try await writeFixedRatePicture(
            asset: exportAsset, videoTrack: videoTrack, composition: composition,
            range: range, framesPerSecond: effects.framesPerSecond,
            quality: quality, outputURL: pictureURL,
            progress: { progress($0 * 0.7) })
        try Task.checkCancellation()

        let pictureAsset = AVURLAsset(url: pictureURL)
        guard let pictureTrack = try await pictureAsset.loadTracks(
            withMediaType: .video).first else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let mux = AVMutableComposition()
        guard let video = mux.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                  of: pictureTrack, at: .zero)
        video.preferredTransform = try await pictureTrack.load(.preferredTransform)
        for sourceAudio in try await exportAsset.loadTracks(withMediaType: .audio) {
            guard let audio = mux.addMutableTrack(withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NativeScreenshotVideoExportError.unsupportedFormat
            }
            try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
        }
        guard let session = AVAssetExportSession(
            asset: mux, presetName: AVAssetExportPresetPassthrough),
            session.supportedFileTypes.contains(.mp4) else {
            throw NativeScreenshotVideoExportError.frameRateConversionUnsupported
        }
        session.outputURL = stagedURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        let box = SessionBox(session)
        let monitor = Task {
            while !Task.isCancelled {
                progress(0.7 + Double(box.value.progress) * 0.3)
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
                    default: continuation.resume(throwing:
                        NativeScreenshotVideoExportError.exportFailed(
                            String(describing: box.value.error
                                ?? NSError(domain: "AVFoundation", code: -1))))
                    }
                }
            }
        } onCancel: { box.value.cancelExport() }
        try Task.checkCancellation()
        try commit(stagedURL, to: destinationURL)
        progress(1)
    }

    private static func writeFixedRatePicture(
        asset: AVAsset, videoTrack: AVAssetTrack,
        composition: AVVideoComposition, range: CMTimeRange,
        framesPerSecond: Int, quality: MP4Quality, outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let frameCount = Int(ceil(range.duration.seconds * Double(framesPerSecond)))
        guard frameCount > 0, range.duration.seconds.isFinite else {
            throw NativeScreenshotVideoExportError.invalidSelection
        }
        let size = composition.renderSize
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let reader = try AVAssetReader(asset: asset)
        let readerBox = ReaderBox(reader)
        reader.timeRange = range
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        output.videoComposition = composition
        guard reader.canAdd(output) else {
            throw NativeScreenshotVideoExportError.frameRateConversionUnsupported
        }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerBox = WriterBox(writer)
        let bitsPerSecond = min(32_000_000, max(800_000,
            Int(Double(width * height * framesPerSecond)
                * (quality == .standard ? 0.10 : 0.18))))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitsPerSecond]
        ])
        input.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else {
            throw NativeScreenshotVideoExportError.frameRateConversionUnsupported
        }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error
                ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        func nextFrame() throws -> (CMTime, CVPixelBuffer)? {
            while let sample = output.copyNextSampleBuffer() {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                guard timestamp.isValid, timestamp.isNumeric,
                      timestamp.seconds.isFinite,
                      let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                return (timestamp - range.start, buffer)
            }
            if reader.status == .failed {
                throw reader.error ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported
            }
            if reader.status == .cancelled { throw CancellationError() }
            return nil
        }
        try await withTaskCancellationHandler {
            var current = try nextFrame()
            var upcoming = try nextFrame()
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                let timestamp = CMTime(value: CMTimeValue(frame),
                                       timescale: CMTimeScale(framesPerSecond))
                while let candidate = upcoming,
                      CMTimeCompare(candidate.0, timestamp) <= 0 {
                    current = candidate
                    upcoming = try nextFrame()
                }
                guard let current else {
                    throw reader.error
                        ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported
                }
                let deadline = Date().addingTimeInterval(10)
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing, Date() < deadline else {
                        throw writer.error
                            ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                guard adapter.append(current.1, withPresentationTime: timestamp) else {
                    throw writer.error
                        ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported
                }
                progress(Double(frame + 1) / Double(frameCount))
            }
            input.markAsFinished()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                writerBox.value.finishWriting {
                    if writerBox.value.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writerBox.value.error
                        ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported) }
                }
            }
            if reader.status == .failed {
                throw reader.error ?? NativeScreenshotVideoExportError.frameRateConversionUnsupported
            }
        } onCancel: {
            readerBox.value.cancelReading()
            writerBox.value.cancelWriting()
        }
        try Task.checkCancellation()
    }

    private struct TimelinePart {
        let sourceStart: TimeInterval
        let sourceDuration: TimeInterval
        let outputStart: TimeInterval
        let outputDuration: TimeInterval
        let includesAudio: Bool
    }

    private struct TimelineComposition {
        let asset: AVMutableComposition
        let parts: [TimelinePart]
    }

    private static func makeTimelineComposition(
        source: AVURLAsset, selection: NativeScreenshotVideoSelection,
        effects: NativeScreenshotVideoEffects
    ) async throws -> TimelineComposition {
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        let sourceAudio = try await source.loadTracks(withMediaType: .audio)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeScreenshotVideoExportError.unsupportedFormat
        }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let parts = try buildTimelineParts(selection: selection, effects: effects)
        for part in parts {
            let sourceRange = CMTimeRange(start: time(part.sourceStart),
                                          duration: time(part.sourceDuration))
            let outputStart = time(part.outputStart)
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: outputStart)
            video.scaleTimeRange(CMTimeRange(start: outputStart,
                                            duration: sourceRange.duration),
                                 toDuration: time(part.outputDuration))
        }
        for sourceTrack in sourceAudio where !effects.muteAudio {
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NativeScreenshotVideoExportError.unsupportedFormat
            }
            for part in parts where part.includesAudio {
                let sourceRange = CMTimeRange(start: time(part.sourceStart),
                                              duration: time(part.sourceDuration))
                let outputStart = time(part.outputStart)
                try track.insertTimeRange(sourceRange, of: sourceTrack, at: outputStart)
                track.scaleTimeRange(CMTimeRange(start: outputStart,
                                                duration: sourceRange.duration),
                                     toDuration: time(part.outputDuration))
            }
        }
        return TimelineComposition(asset: composition, parts: parts)
    }

    private static func buildTimelineParts(
        selection: NativeScreenshotVideoSelection,
        effects: NativeScreenshotVideoEffects
    ) throws -> [TimelinePart] {
        var boundaries = [selection.start, selection.end]
        for segment in effects.segments {
            switch segment.content {
            case .cut, .speed:
                if segment.start > selection.start && segment.start < selection.end {
                    boundaries.append(segment.start)
                }
                if segment.end > selection.start && segment.end < selection.end {
                    boundaries.append(segment.end)
                }
            default: break
            }
        }
        let freezeEnd: TimeInterval?
        if let freezeAt = effects.freezeAt {
            let end = min(freezeAt + 1 / 60, selection.end)
            boundaries.append(freezeAt)
            boundaries.append(end)
            freezeEnd = end
        } else {
            freezeEnd = nil
        }
        boundaries.sort()
        boundaries = boundaries.reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > 0.000_001 }) ?? true {
                result.append(value)
            }
        }
        var parts: [TimelinePart] = []
        var output = 0.0
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end - start > 0.000_001 {
            let center = (start + end) / 2
            let isCut = effects.segments.contains { segment in
                if case .cut = segment.content { return segment.contains(center) }
                return false
            }
            if isCut { continue }
            let isFreeze = effects.freezeAt.map { center >= $0 && center < (freezeEnd ?? $0) }
                ?? false
            let segmentSpeed = effects.segments.compactMap { segment -> Double? in
                guard segment.contains(center), case .speed(let rate) = segment.content
                else { return nil }
                return rate
            }.first ?? 1
            let outputDuration = isFreeze
                ? effects.freezeDuration : (end - start) / (effects.speed * segmentSpeed)
            parts.append(TimelinePart(sourceStart: start, sourceDuration: end - start,
                                      outputStart: output, outputDuration: outputDuration,
                                      includesAudio: !isFreeze))
            output += outputDuration
        }
        guard !parts.isEmpty, output >= 0.1 else {
            throw NativeScreenshotVideoExportError.invalidEffects
        }
        return parts
    }

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    private final class TextImageCache: @unchecked Sendable {
        private let text: String
        private let style: NativeScreenshotVideoTextStyle
        private let lock = NSLock()
        private var value: (CGSize, CIImage?)?

        init(text: String, style: NativeScreenshotVideoTextStyle) {
            self.text = text
            self.style = style
        }

        func image(for size: CGSize) -> CIImage? {
            guard !text.isEmpty else { return nil }
            lock.lock()
            defer { lock.unlock() }
            if let value, value.0 == size { return value.1 }
            let image = NativeScreenshotVideoSegmentExporter.makeTextImage(
                text, style: style, videoSize: size)
            value = (size, image)
            return image
        }
    }

    private static func makeVideoComposition(
        asset: AVAsset, effects: NativeScreenshotVideoEffects,
        sourceFrameRate: Float, timelineParts: [TimelinePart]?,
        selection: NativeScreenshotVideoSelection
    ) -> AVMutableVideoComposition {
        let textCache = TextImageCache(text: effects.text, style: effects.textStyle)
        let segmentTextCaches: [TextImageCache?] = effects.segments.map { segment in
            switch segment.content {
            case .text(let text, _):
                return TextImageCache(text: text, style: .init())
            case .styledText(let text, _, let style):
                return TextImageCache(text: text, style: style)
            default:
                return nil
            }
        }
        let video = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let extent = source.extent
            let bounds = CGRect(origin: .zero, size: extent.size)
            var image = source.transformed(by: CGAffineTransform(
                translationX: -extent.minX, y: -extent.minY))
            let outputSecond = request.compositionTime.seconds
            let sourceSecond: TimeInterval
            if let part = timelineParts?.last(where: {
                outputSecond + 0.000_001 >= $0.outputStart
            }), part.outputDuration > 0 {
                sourceSecond = part.sourceStart + min(part.sourceDuration,
                    max(0, outputSecond - part.outputStart)
                    * part.sourceDuration / part.outputDuration)
            } else {
                sourceSecond = outputSecond
            }
            let active = effects.segments.enumerated().filter {
                $0.element.contains(sourceSecond)
            }
            let segmentZoom = active.compactMap { item -> CGFloat? in
                if case .zoom(let value) = item.element.content { return value }
                return nil
            }.last
            let zoom = segmentZoom ?? effects.zoom
            if zoom > 1 {
                image = image.transformed(by: CGAffineTransform(
                    a: zoom, b: 0, c: 0, d: zoom,
                    tx: bounds.midX * (1 - zoom), ty: bounds.midY * (1 - zoom)))
                    .cropped(to: bounds)
            }
            var redactions: [(CGRect, NativeScreenshotVideoRedactionStyle, CGFloat)] = []
            if let rect = effects.redaction {
                redactions.append((rect, effects.redactionStyle,
                                   effects.redactionStyle.opacity(
                                    at: sourceSecond, start: selection.start,
                                    end: selection.end)))
            }
            for item in active {
                switch item.element.content {
                case .redaction(let rect):
                    redactions.append((rect, .init(), 1))
                case .styledRedaction(let rect, let style):
                    redactions.append((rect, style, style.opacity(
                        at: sourceSecond, start: item.element.start,
                        end: item.element.end)))
                default: break
                }
            }
            for (normalized, style, opacity) in redactions where opacity > 0 {
                let region = CGRect(x: normalized.minX * bounds.width,
                                    y: (1 - normalized.maxY) * bounds.height,
                                    width: normalized.width * bounds.width,
                                    height: normalized.height * bounds.height)
                    .intersection(bounds)
                if !region.isEmpty {
                    let cover: CIImage
                    switch style.kind {
                    case .solid:
                        let color = style.color
                        cover = CIImage(color: CIColor(
                            red: color.red, green: color.green, blue: color.blue,
                            alpha: color.alpha * Double(opacity))).cropped(to: region)
                    case .pixelate:
                        cover = image.applyingFilter("CIPixellate", parameters: [
                            kCIInputScaleKey: 20,
                            kCIInputCenterKey: CIVector(x: region.midX, y: region.midY)
                        ]).cropped(to: region).applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                        ])
                    case .blur:
                        cover = image.clampedToExtent()
                            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30])
                            .cropped(to: region)
                            .applyingFilter("CIColorMatrix", parameters: [
                                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                            ])
                    }
                    image = cover.composited(over: image)
                }
            }
            let textLayers: [(CIImage, CGPoint, CGFloat)] =
                ([textCache.image(for: bounds.size)].compactMap { $0 }.map {
                    ($0, effects.textPosition, effects.textStyle.opacity(
                        at: sourceSecond, start: selection.start, end: selection.end))
                }) + active.compactMap { item in
                    guard let cached = segmentTextCaches[item.offset]?.image(for: bounds.size)
                    else { return nil }
                    switch item.element.content {
                    case .text(_, let position): return (cached, position, 1)
                    case .styledText(_, let position, let style):
                        return (cached, position, style.opacity(
                            at: sourceSecond, start: item.element.start,
                            end: item.element.end))
                    default: return nil
                    }
                }
            for (textImage, position, opacity) in textLayers where opacity > 0 {
                let x = min(max(0, position.x * bounds.width),
                            max(0, bounds.width - textImage.extent.width))
                let y = min(max(0, (1 - position.y) * bounds.height
                                   - textImage.extent.height),
                            max(0, bounds.height - textImage.extent.height))
                let layer = opacity >= 0.999 ? textImage
                    : textImage.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                    ])
                image = layer.transformed(by: CGAffineTransform(
                    translationX: x, y: y)).composited(over: image)
            }
            image = image.cropped(to: bounds)
            if effects.outputScale != 1 {
                image = image.transformed(by: CGAffineTransform(
                    scaleX: effects.outputScale, y: effects.outputScale))
            }
            request.finish(with: image, context: nil)
        }
        let size = video.renderSize
        // H.264 export requires even pixel dimensions for common hardware encoders.
        func evenDimension(_ value: CGFloat) -> CGFloat {
            CGFloat(max(2, Int(value.rounded()) / 2 * 2))
        }
        video.renderSize = CGSize(width: evenDimension(size.width * effects.outputScale),
                                  height: evenDimension(size.height * effects.outputScale))
        let sourceFPS = sourceFrameRate.isFinite && sourceFrameRate > 0
            ? Int(sourceFrameRate.rounded()) : 30
        let fps = effects.frameRateRequested || effects.framesPerSecond != 30
            ? effects.framesPerSecond : max(10, min(60, sourceFPS))
        video.frameDuration = CMTime(value: 1, timescale: Int32(fps))
        return video
    }

    /// The editor uses the same compositor for playback and export.
    static func previewComposition(
        asset: AVAsset, effects: NativeScreenshotVideoEffects,
        sourceFrameRate: Float, selection: NativeScreenshotVideoSelection
    ) -> AVMutableVideoComposition {
        makeVideoComposition(asset: asset, effects: effects,
                             sourceFrameRate: sourceFrameRate,
                             timelineParts: nil, selection: selection)
    }

    private static func makeTextImage(
        _ text: String, style: NativeScreenshotVideoTextStyle,
        videoSize: CGSize
    ) -> CIImage? {
        guard !text.isEmpty else { return nil }
        let fontSize = max(8, min(220, style.fontSize * videoSize.height / 1_080))
        let fontName: String
        switch (style.bold, style.italic) {
        case (true, true): fontName = "Helvetica-BoldOblique"
        case (true, false): fontName = "Helvetica-Bold"
        case (false, true): fontName = "Helvetica-Oblique"
        case (false, false): fontName = "Helvetica"
        }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var alignment: CTTextAlignment
        switch style.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let paragraph = withUnsafeBytes(of: &alignment) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(
                spec: .alignment, valueSize: raw.count, value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let foreground = style.textColor
        let foregroundColor = CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [foreground.red, foreground.green,
                         foreground.blue, foreground.alpha]) ?? CGColor(gray: 1, alpha: 1)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: foregroundColor,
            kCTParagraphStyleAttributeName: paragraph
        ]
        guard let attributed = CFAttributedStringCreate(kCFAllocatorDefault,
                                                        text as CFString,
                                                        attributes as CFDictionary) else {
            return nil
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = max(80, min(videoSize.width * 0.9,
                                  videoSize.width * style.boxWidth))
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: maxWidth - 20, height: videoSize.height * 0.5), nil)
        let width = max(2, Int(ceil(maxWidth)))
        let height = max(2, Int(ceil(min(videoSize.height * 0.5,
                                      max(fontSize + 16, suggested.height + 20)))))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        if style.background != .none {
            let background = style.backgroundColor
            context.setFillColor(CGColor(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [background.red, background.green,
                             background.blue, background.alpha])
                ?? CGColor(gray: 0, alpha: 0.72))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            if style.background == .rounded {
                context.addPath(CGPath(
                    roundedRect: bounds, cornerWidth: min(14, CGFloat(height) / 3),
                    cornerHeight: min(14, CGFloat(height) / 3), transform: nil))
                context.fillPath()
            } else {
                context.fill(bounds)
            }
        }
        let path = CGPath(rect: CGRect(x: 10, y: 8,
                                      width: max(1, width - 20),
                                      height: max(1, height - 16)), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil),
                    context)
        return context.makeImage().map(CIImage.init(cgImage:))
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

    static func exportEditedGIF(
        sourceURL: URL, destinationURL: URL, selection: NativeScreenshotVideoSelection,
        effects: NativeScreenshotVideoEffects, framesPerSecond: Int,
        maximumDimension: Int, progress: @escaping (Double) -> Void
    ) async throws {
        let effects = try effects.validated(for: selection)
        if !effects.needsProcessing {
            try exportGIF(sourceURL: sourceURL, destinationURL: destinationURL,
                          selection: selection, framesPerSecond: framesPerSecond,
                          maximumDimension: maximumDimension, progress: progress)
            return
        }
        let intermediate = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".native-gif-source-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        try await exportMP4(sourceURL: sourceURL, destinationURL: intermediate,
                            selection: selection, quality: .high, effects: effects,
                            progress: { progress($0 * 0.6) })
        try Task.checkCancellation()
        let duration = try await AVURLAsset(url: intermediate).load(.duration).seconds
        let rendered = try NativeScreenshotVideoSelection(start: 0, end: duration,
                                                          duration: duration)
        try exportGIF(sourceURL: intermediate, destinationURL: destinationURL,
                      selection: rendered, framesPerSecond: framesPerSecond,
                      maximumDimension: maximumDimension,
                      progress: { progress(0.6 + $0 * 0.4) })
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
