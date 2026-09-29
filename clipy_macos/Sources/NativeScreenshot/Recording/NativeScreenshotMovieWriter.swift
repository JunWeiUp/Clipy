import AVFoundation
import CoreMedia
import Foundation

/// All methods are called on the recorder's serial sample queue.
final class NativeScreenshotMovieWriter {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var systemAudioInput: AVAssetWriterInput? = nil
    private var microphoneInput: AVAssetWriterInput? = nil
    private let maxDuration: TimeInterval
    private(set) var firstVideoTime: CMTime?
    private(set) var lastVideoTime: CMTime?
    private(set) var reachedDurationLimit = false
    private(set) var appendError: Error?
    private var firstVideoUptime: TimeInterval?
    private var lastVideoSample: CMSampleBuffer?
    private var inputsFinished = false
    private var pauseBeganUptime: TimeInterval?
    private var pausedDuration: TimeInterval = 0

    /// Capture remains live while paused, but timestamps delivered to the
    /// encoder omit the paused interval so video and both audio tracks agree.
    var activeElapsed: TimeInterval {
        guard let firstVideoUptime else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        let currentPause = pauseBeganUptime.map { now - $0 } ?? 0
        return max(0, now - firstVideoUptime - pausedDuration - currentPause)
    }

    func pause() {
        guard !inputsFinished, pauseBeganUptime == nil else { return }
        _ = appendCleanFrameAtCurrentTime()
        pauseBeganUptime = ProcessInfo.processInfo.systemUptime
    }

    func resume() {
        guard let pauseBeganUptime else { return }
        pausedDuration += max(0, ProcessInfo.processInfo.systemUptime - pauseBeganUptime)
        self.pauseBeganUptime = nil
    }

    init(url: URL, size: CGSize, systemAudio: Bool, microphone: Bool, maxDuration: TimeInterval) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.maxDuration = maxDuration
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, min(20_000_000, Int(size.width * size.height * 4))),
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NativeScreenshotRecordingError.writerFailed("无法添加视频轨")
        }
        writer.add(videoInput)

        func makeAudioInput(channels: Int) throws -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw NativeScreenshotRecordingError.writerFailed("无法添加音频轨")
            }
            writer.add(input)
            return input
        }
        systemAudioInput = try systemAudio ? makeAudioInput(channels: 2) : nil
        microphoneInput = try microphone ? makeAudioInput(channels: 1) : nil
    }

    func appendVideo(_ sample: CMSampleBuffer, cleanFallback: CMSampleBuffer? = nil) {
        guard !inputsFinished, pauseBeganUptime == nil, appendError == nil,
              CMSampleBufferDataIsReady(sample) else { return }
        guard let adjusted = shiftingPastPauses(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard time.isValid, !time.isIndefinite else { return }
        if firstVideoTime == nil {
            guard writer.startWriting() else {
                appendError = NativeScreenshotRecordingError.writerFailed(writer.error.map { String(describing: $0) } ?? "无法启动编码器")
                return
            }
            writer.startSession(atSourceTime: time)
            firstVideoTime = time
            firstVideoUptime = ProcessInfo.processInfo.systemUptime
        }
        guard let firstVideoTime else { return }
        if CMTimeGetSeconds(time - firstVideoTime) >= maxDuration {
            reachedDurationLimit = true
            return
        }
        // The first sample may arrive before the encoder reports readiness.
        // AVAssetWriterInput accepts it after startSession and primes its pipeline.
        guard videoInput.isReadyForMoreMediaData || lastVideoTime == nil else { return }
        if videoInput.append(adjusted) {
            lastVideoTime = time
            // Duration extension must never preserve transient camera/key/click overlays.
            lastVideoSample = cleanFallback.flatMap(shiftingPastPauses) ?? adjusted
        } else {
            appendError = NativeScreenshotRecordingError.writerFailed(writer.error?.localizedDescription ?? "视频帧写入失败")
        }
    }

    func appendSystemAudio(_ sample: CMSampleBuffer) {
        appendAudio(sample, input: systemAudioInput)
    }

    func appendMicrophone(_ sample: CMSampleBuffer) {
        appendAudio(sample, input: microphoneInput)
    }

    private func appendAudio(_ sample: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let input, !inputsFinished, pauseBeganUptime == nil,
              appendError == nil, let firstVideoTime,
              CMSampleBufferDataIsReady(sample) else { return }
        guard let adjusted = shiftingPastPauses(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard time.isValid, time >= firstVideoTime,
              CMTimeGetSeconds(time - firstVideoTime) < maxDuration,
              input.isReadyForMoreMediaData else { return }
        if !input.append(adjusted) {
            appendError = NativeScreenshotRecordingError.writerFailed(writer.error?.localizedDescription ?? "音频帧写入失败")
        }
    }

    private func shiftingPastPauses(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard pausedDuration > 0 else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else {
            appendError = NativeScreenshotRecordingError.writerFailed("无法读取录制时间戳")
            return nil
        }
        var entries = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid
        ), count: count)
        let readStatus = entries.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sample, entryCount: count, arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard readStatus == noErr else {
            appendError = NativeScreenshotRecordingError.writerFailed("无法读取录制时间戳")
            return nil
        }
        let offset = CMTime(seconds: pausedDuration, preferredTimescale: 1_000_000)
        for index in entries.indices {
            if entries[index].presentationTimeStamp.isValid {
                entries[index].presentationTimeStamp = entries[index].presentationTimeStamp - offset
            }
            if entries[index].decodeTimeStamp.isValid {
                entries[index].decodeTimeStamp = entries[index].decodeTimeStamp - offset
            }
        }
        var result: CMSampleBuffer?
        let copyStatus = entries.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: count, sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &result
            )
        }
        guard copyStatus == noErr, let result else {
            appendError = NativeScreenshotRecordingError.writerFailed("无法调整暂停后的录制时间戳")
            return nil
        }
        return result
    }

    /// Ends a transient overlay even when the captured desktop stays unchanged.
    @discardableResult
    func appendCleanFrameAtCurrentTime() -> Bool {
        guard !inputsFinished, let firstVideoTime, let lastVideoTime,
              let lastVideoSample, writer.status == .writing,
              videoInput.isReadyForMoreMediaData else { return false }
        let elapsed = min(maxDuration, activeElapsed)
        let encoded = CMTimeGetSeconds(lastVideoTime - firstVideoTime)
        guard elapsed - encoded > 0.03 else { return false }
        let time = firstVideoTime + CMTime(seconds: elapsed, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(lastVideoSample),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var repeated: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                   sampleBuffer: lastVideoSample,
                                                   sampleTimingEntryCount: 1,
                                                   sampleTimingArray: &timing,
                                                   sampleBufferOut: &repeated) == noErr,
              let repeated else { return false }
        if videoInput.append(repeated) {
            self.lastVideoTime = time
            return true
        }
        appendError = NativeScreenshotRecordingError.writerFailed(writer.error?.localizedDescription ?? "结束临时叠层失败")
        return false
    }

    /// Call on the recorder's sample queue after it has stopped accepting new
    /// samples. This keeps the final frame and input state changes serialized
    /// with every append callback.
    func prepareToFinish() throws {
        guard !inputsFinished else {
            throw NativeScreenshotRecordingError.writerFailed("编码器已结束")
        }
        if let appendError {
            inputsFinished = true
            writer.cancelWriting()
            throw appendError
        }
        guard firstVideoTime != nil, lastVideoTime != nil else {
            inputsFinished = true
            writer.cancelWriting()
            throw NativeScreenshotRecordingError.noFrames
        }
        // A static screen may not emit new frames. Extend the final clean frame to stop time.
        _ = appendCleanFrameAtCurrentTime()
        lastVideoSample = nil
        inputsFinished = true
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
    }

    /// May wait away from the sample queue. No input may append after
    /// `prepareToFinish()` has marked the tracks finished.
    func completeFinish() async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw NativeScreenshotRecordingError.writerFailed(writer.error?.localizedDescription ?? "无法完成 MP4")
        }
    }

    func finish() async throws {
        try prepareToFinish()
        try await completeFinish()
    }

    func cancel() {
        inputsFinished = true
        lastVideoSample = nil
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: writer.outputURL)
    }
}
