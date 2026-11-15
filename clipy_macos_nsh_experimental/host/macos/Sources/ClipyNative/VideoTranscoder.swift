import AVFoundation
import CoreVideo
import AudioToolbox

/// Explicit bitrate control keeps export size independent from the quality choice.
enum VideoTranscoder {
    static func encode(asset:AVAsset,videoComposition:AVVideoComposition?,size:CGSize,output:URL,quality:String,id:String) async throws {
        let videoTracks=try await asset.loadTracks(withMediaType:.video)
        let audioTracks=try await asset.loadTracks(withMediaType:.audio)
        guard !videoTracks.isEmpty,size.width>=2,size.height>=2 else{throw failure("视频没有可编码画面")}
        let reader=try AVAssetReader(asset:asset)
        let videoOutput=AVAssetReaderVideoCompositionOutput(videoTracks:videoTracks,videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition=videoComposition ?? AVMutableVideoComposition(propertiesOf:asset)
        videoOutput.alwaysCopiesSampleData=false
        guard reader.canAdd(videoOutput) else{throw failure("系统不能读取视频画面")};reader.add(videoOutput)
        var audioOutput:AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let audio=AVAssetReaderAudioMixOutput(audioTracks:audioTracks,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:44100,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
            audio.alwaysCopiesSampleData=false
            guard reader.canAdd(audio)else{throw failure("系统不能读取视频音轨")};reader.add(audio);audioOutput=audio
        }
        let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        let nominal=Double(try await videoTracks[0].load(.nominalFrameRate)),fps=max(12,min(60,nominal>0 ? nominal:30))
        let factor=quality=="low" ? 0.035:0.08
        let bitrate=max(64000,Int(size.width*size.height*fps*factor))
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height),AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bitrate,AVVideoExpectedSourceFrameRateKey:fps,AVVideoMaxKeyFrameIntervalKey:Int(fps*2)]])
        videoInput.expectsMediaDataInRealTime=false
        guard writer.canAdd(videoInput)else{throw failure("系统不能创建视频编码器")};writer.add(videoInput)
        var audioInput:AVAssetWriterInput?
        if audioOutput != nil {
            let input=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:44100,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:quality=="low" ? 64000:128000]);input.expectsMediaDataInRealTime=false
            guard writer.canAdd(input)else{throw failure("系统不能创建音频编码器")};writer.add(input);audioInput=input
        }
        guard writer.startWriting(),reader.startReading()else{throw writer.error ?? reader.error ?? failure("视频编解码器启动失败")};writer.startSession(atSourceTime:.zero)
        var videoDone=false,audioDone=audioInput==nil
        let duration=try await asset.load(.duration).seconds
        var lastProgress=0.0
        do {
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                guard writer.status == .writing else{throw writer.error ?? failure("视频写入失败")}
                if reader.status == .failed{throw reader.error ?? failure("视频读取失败")}
                var advanced=false
                if !videoDone,videoInput.isReadyForMoreMediaData {
                    if let sample=videoOutput.copyNextSampleBuffer(){guard videoInput.append(sample)else{throw writer.error ?? failure("画面编码失败")};let now=CMSampleBufferGetPresentationTimeStamp(sample).seconds;if now-lastProgress>=0.5{lastProgress=now;BridgeOutput.write(["event":"video.progress","payload":["id":id,"progress":min(1,now/max(0.01,duration))]])}}
                    else{videoDone=true;videoInput.markAsFinished()};advanced=true
                }
                if !audioDone,let input=audioInput,let source=audioOutput,input.isReadyForMoreMediaData {
                    if let sample=source.copyNextSampleBuffer(){guard input.append(sample)else{throw writer.error ?? failure("音轨编码失败")}}
                    else{audioDone=true;input.markAsFinished()};advanced=true
                }
                if !advanced{try await Task.sleep(nanoseconds:2_000_000)}
            }
            await withTaskCancellationHandler(operation:{await withCheckedContinuation{(done:CheckedContinuation<Void,Never>)in writer.finishWriting{done.resume()}}},onCancel:{reader.cancelReading();writer.cancelWriting()})
            guard writer.status == .completed else{throw writer.error ?? failure("视频导出失败")}
        }catch{reader.cancelReading();writer.cancelWriting();try? FileManager.default.removeItem(at:output);throw error}
    }
    private static func failure(_ message:String)->BridgeFailure{BridgeFailure(code:"VIDEO_ENCODING",message:message)}
}
