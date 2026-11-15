import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
import CoreGraphics

/// A concrete still + silent AAC clip avoids stretching a one-sample edit.
enum StillVideoWriter {
    static func write(asset:AVAsset,time:Double,duration:Double) async throws -> URL {
        let generator=AVAssetImageGenerator(asset:asset)
        generator.appliesPreferredTrackTransform=false
        let total=try await asset.load(.duration).seconds
        let frame=try await generator.image(at:CMTime(seconds:max(0,min(time,total-1.0/30)),preferredTimescale:600)).image
        guard frame.width*frame.height<=80_000_000 else{throw error("定格画面过大")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-still-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let output=directory.appendingPathComponent("still.mp4")
        var completed=false
        defer {if !completed{try? FileManager.default.removeItem(at:directory)}}
        let width=frame.width+(frame.width%2),height=frame.height+(frame.height%2)
        let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        let video=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
        video.expectsMediaDataInRealTime=false
        let pixels=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:video,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        let audio=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:44100,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000])
        audio.expectsMediaDataInRealTime=false
        guard writer.canAdd(video),writer.canAdd(audio)else{throw error("系统不能创建定格编码器")}
        writer.add(video);writer.add(audio)
        guard writer.startWriting()else{throw writer.error ?? error("定格编码器启动失败")};writer.startSession(atSourceTime:.zero)
        var buffer:CVPixelBuffer?
        guard let pool=pixels.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess,let buffer else{throw error("无法分配定格画面")}
        CVPixelBufferLockBaseAddress(buffer,[])
        if let base=CVPixelBufferGetBaseAddress(buffer),let context=CGContext(data:base,width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue){
            context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height));context.draw(frame,in:CGRect(x:0,y:0,width:frame.width,height:frame.height))
        }else{CVPixelBufferUnlockBaseAddress(buffer,[]);throw error("无法绘制定格画面")}
        CVPixelBufferUnlockBaseAddress(buffer,[])
        var description=AudioStreamBasicDescription(mSampleRate:44100,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var audioFormat:CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&audioFormat)==noErr,let audioFormat else{throw error("无法创建静音音轨")}
        let frames=max(1,Int(ceil(duration*30))),sampleCount=max(1,Int(ceil(duration*44100)))
        var nextFrame=0,nextSample=0
        let deadline=ProcessInfo.processInfo.systemUptime+60
        do {
            while nextFrame<frames||nextSample<sampleCount {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime>deadline{throw error("定格编码超时")}
                guard writer.status == .writing else{throw writer.error ?? error("定格编码失败")}
                var progressed=false
                if nextFrame<frames,video.isReadyForMoreMediaData{
                    guard pixels.append(buffer,withPresentationTime:CMTime(value:Int64(nextFrame),timescale:30))else{throw writer.error ?? error("定格帧写入失败")};nextFrame+=1;progressed=true
                }
                if nextSample<sampleCount,audio.isReadyForMoreMediaData{
                    let count=min(1024,sampleCount-nextSample)
                    let sample=try silence(format:audioFormat,start:nextSample,count:count)
                    guard audio.append(sample)else{throw writer.error ?? error("静音帧写入失败")};nextSample+=count;progressed=true
                }
                if !progressed{try await Task.sleep(nanoseconds:1_000_000)}
            }
            video.markAsFinished();audio.markAsFinished();writer.endSession(atSourceTime:CMTime(seconds:duration,preferredTimescale:44100))
            await withTaskCancellationHandler(operation:{await withCheckedContinuation{(done:CheckedContinuation<Void,Never>)in writer.finishWriting{done.resume()}}},onCancel:{writer.cancelWriting()})
            guard writer.status == .completed else{throw writer.error ?? error("定格文件写入失败")}
            completed=true;return output
        }catch{writer.cancelWriting();throw error}
    }
    private static func silence(format:CMAudioFormatDescription,start:Int,count:Int)throws->CMSampleBuffer{
        var block:CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:count*8,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:count*8,flags:0,blockBufferOut:&block)==kCMBlockBufferNoErr,let block else{throw error("静音缓冲区创建失败")}
        guard CMBlockBufferFillDataBytes(with:0,blockBuffer:block,offsetIntoDestination:0,dataLength:count*8)==kCMBlockBufferNoErr else{throw error("静音缓冲区初始化失败")}
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:44100),presentationTimeStamp:CMTime(value:Int64(start),timescale:44100),decodeTimeStamp:.invalid)
        var size=8,sample:CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:count,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)==noErr,let sample else{throw error("静音采样创建失败")}
        return sample
    }
    private static func error(_ message:String)->BridgeFailure{BridgeFailure(code:"STILL_ENCODING",message:message)}
}
