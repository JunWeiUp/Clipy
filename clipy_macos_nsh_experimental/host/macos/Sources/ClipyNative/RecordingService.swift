import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// All writer operations are serialized; SCStream keeps at most four capture frames.
final class RecordingService:NSObject,SCStreamOutput,SCStreamDelegate,AVCaptureAudioDataOutputSampleBufferDelegate,@unchecked Sendable {
    let root:URL
    let queue = DispatchQueue(label:"dev.clipy.tsx.recording")
    var stream:SCStream?
    var writer:AVAssetWriter?
    var input:AVAssetWriterInput?
    var audioInput:AVAssetWriterInput?
    var microphoneInput:AVAssetWriterInput?
    var microphoneSession:AVCaptureSession?
    var cameraSession:AVCaptureSession?
    var cameraPanel:NSPanel?
    var overlays:RecordingOverlays?
    var output:URL?
    var began = false
    var started:Date?
    var starting = false
    init(root:URL) { self.root = root }
    func start(_ params:[String:Any]) async throws -> [String:Any] {
        guard stream == nil,!starting else { throw BridgeFailure(code:"BUSY",message:"录屏已在运行") };starting = true;var succeeded = false;defer { starting = false;if !succeeded { cancel() } }
        let clickEvents = params["highlightClicks"] as? Bool ?? params["recordClicks"] as? Bool ?? false,keyEvents = params["showKeys"] as? Bool ?? params["recordKeys"] as? Bool ?? false
        if (clickEvents || keyEvents) && !(CGPreflightListenEventAccess() || AXIsProcessTrusted()) { throw BridgeFailure(code:"PERMISSION_DENIED",message:"点击高亮和按键显示需要输入监控或辅助功能权限") }
        let microphone = params["microphone"] as? Bool ?? false,systemAudio = params["systemAudio"] as? Bool ?? false,camera = params["camera"] as? Bool ?? false
        if microphone && AVCaptureDevice.authorizationStatus(for:.audio) != .authorized { throw BridgeFailure(code:"PERMISSION_DENIED",message:"请先授权麦克风") }
        if camera && AVCaptureDevice.authorizationStatus(for:.video) != .authorized { throw BridgeFailure(code:"PERMISSION_DENIED",message:"请先授权摄像头") }
        var sourceRect:CGRect?
        var chosenDisplay = UInt32(params["displayId"] as? Int ?? 0)
        let screens = await MainActor.run { NSScreen.screens.map { (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,$0.frame,$0.backingScaleFactor) } }
        if let rect = params["rect"] as? [String:Double],let x = rect["x"],let y = rect["y"],let width = rect["width"],let height = rect["height"],width >= 2,height >= 2 { sourceRect = CGRect(x:x,y:y,width:width,height:height) }
        else if params["rect"] != nil { throw BridgeFailure(code:"INVALID_REGION",message:"录制区域参数无效") }
        else if params["mode"] as? String != "fullscreen" && params["recordingMode"] as? String != "fullscreen" {
            guard let target = await ScrollRegionSelector.select() else { return ["cancelled":true,"recording":false] }
            try Task.checkCancellation()
            guard let screen = screens.first(where:{$0.1.contains(CGPoint(x:target.midX,y:target.midY))}) else { throw BridgeFailure(code:"NO_DISPLAY",message:"无法确定录制区域所属显示器") }
            chosenDisplay = screen.0;sourceRect = CGRect(x:target.minX-screen.1.minX,y:screen.1.maxY-target.maxY,width:target.width,height:target.height)
        }
        let content:SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true) } catch { throw CaptureAccessPolicy.mapped(error) }
        guard let display = content.displays.first(where:{ $0.displayID == chosenDisplay }) ?? content.displays.first else { throw BridgeFailure(code:"NO_DISPLAY",message:"没有可录制的显示器") }
        let config = SCStreamConfiguration();let displayScreen = screens.first(where:{$0.0 == display.displayID});let captureScale = displayScreen?.2 ?? 1;config.width = Int((displayScreen?.1.width ?? CGFloat(display.width))*captureScale);config.height = Int((displayScreen?.1.height ?? CGFloat(display.height))*captureScale);config.queueDepth = 4;config.capturesAudio = systemAudio;config.excludesCurrentProcessAudio = false
        let fps = min(max(params["fps"] as? Int ?? 30,1),60);config.minimumFrameInterval = CMTime(value:1,timescale:CMTimeScale(fps));config.showsCursor = params["cursor"] as? Bool ?? true;config.pixelFormat = kCVPixelFormatType_32BGRA
        if let sourceRect {
            let screen = screens.first(where:{$0.0 == display.displayID})?.1 ?? CGRect(x:0,y:0,width:display.width,height:display.height)
            guard sourceRect.minX >= 0,sourceRect.minY >= 0,sourceRect.maxX <= screen.width,sourceRect.maxY <= screen.height else { throw BridgeFailure(code:"INVALID_REGION",message:"录制区域超出所选显示器") }
            let scale = captureScale;config.sourceRect = sourceRect;config.width = max(2,Int(sourceRect.width*scale)/2*2);config.height = max(2,Int(sourceRect.height*scale)/2*2)
        }
        guard config.width > 0,config.height > 0,config.width <= 16384,config.height <= 16384,config.width*config.height <= 80_000_000 else { throw BridgeFailure(code:"REGION_TOO_LARGE",message:"录制区域超过 80 MP，请选择较小区域") }
        let directory = root.appendingPathComponent("recordings",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let url = directory.appendingPathComponent(UUID().uuidString+".mp4")
        let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:config.width,AVVideoHeightKey:config.height]);input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw BridgeFailure(code:"ENCODING",message:"无法创建录屏编码器") };writer.add(input)
        self.writer = writer;self.input = input;self.output = url;self.began = false
        func makeAudioInput() throws -> AVAssetWriterInput {
            let item = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000]);item.expectsMediaDataInRealTime = true
            guard writer.canAdd(item) else { throw BridgeFailure(code:"ENCODING",message:"无法添加录屏音轨") };writer.add(item);return item
        }
        audioInput = systemAudio ? try makeAudioInput() : nil
        microphoneInput = microphone ? try makeAudioInput() : nil
        if microphone {
            guard let device = AVCaptureDevice.default(for:.audio) else { throw BridgeFailure(code:"NO_DEVICE",message:"没有可用麦克风") }
            let session = AVCaptureSession();let mic = try AVCaptureDeviceInput(device:device);let out = AVCaptureAudioDataOutput()
            guard session.canAddInput(mic),session.canAddOutput(out) else { throw BridgeFailure(code:"NO_DEVICE",message:"麦克风不可用") };session.addInput(mic);session.addOutput(out);out.setSampleBufferDelegate(self,queue:queue);microphoneSession = session
        }
        let effectiveParameters = params.merging(["displayId":Int(display.displayID)]) { _,new in new }
        if camera { try await openCamera(effectiveParameters) }
        let filter = SCContentFilter(display:display,excludingApplications:content.applications.filter { $0.processID == getppid() },exceptingWindows:[]);let stream = SCStream(filter:filter,configuration:config,delegate:self)
        do {
            try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
            if systemAudio { try stream.addStreamOutput(self,type:.audio,sampleHandlerQueue:queue) }
            try await stream.startCapture()
        } catch { writer.cancelWriting();self.writer = nil;self.input = nil;throw CaptureAccessPolicy.mapped(error) }
        self.stream = stream;try Task.checkCancellation()
        self.overlays = try await MainActor.run { try RecordingOverlays(parameters:effectiveParameters,displayId:display.displayID,stop:{ [weak self] in Task { do { if let result = try await self?.stop() { BridgeOutput.write(["event":"recording.finished","payload":result]) } } catch { BridgeOutput.write(["event":"recording.error","payload":["message":"录屏收尾失败"]]) } } }) }
        microphoneSession?.startRunning();cameraSession?.startRunning();started = Date();succeeded = true;return ["recording":true,"path":url.path,"fps":fps,"width":config.width,"height":config.height]
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of outputType:SCStreamOutputType) {
        guard sampleBuffer.isValid,let writer else { return }
        if outputType == .audio { if began,writer.status == .writing,let audioInput,audioInput.isReadyForMoreMediaData { _ = audioInput.append(sampleBuffer) };return }
        guard outputType == .screen,CMSampleBufferGetImageBuffer(sampleBuffer) != nil,let input else { return }
        if !began { guard writer.startWriting() else { return };writer.startSession(atSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer));began = true }
        guard writer.status == .writing,input.isReadyForMoreMediaData else { return };_ = input.append(sampleBuffer)
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard began,sampleBuffer.isValid,writer?.status == .writing,let microphoneInput,microphoneInput.isReadyForMoreMediaData else { return };_ = microphoneInput.append(sampleBuffer)
    }
    func openCamera(_ params:[String:Any]) async throws {
        guard let device = AVCaptureDevice.default(for:.video) else { throw BridgeFailure(code:"NO_DEVICE",message:"没有可用摄像头") }
        let session = AVCaptureSession();let input = try AVCaptureDeviceInput(device:device);guard session.canAddInput(input) else { throw BridgeFailure(code:"NO_DEVICE",message:"摄像头不可用") };session.addInput(input);session.sessionPreset = .medium;cameraSession = session
        await MainActor.run {
            let sizeName = params["cameraSize"] as? String ?? "",sizeValue = params["cameraSize"] as? Double ?? (["S":120,"small":120,"小":120,"L":240,"large":240,"大":240,"XL":320][sizeName].map(Double.init) ?? 180)
            let size = min(max(sizeValue,100),400),targetScreen = NSScreen.screens.first(where:{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(params["displayId"] as? Int ?? 0) }) ?? NSScreen.main
            let screen = targetScreen?.visibleFrame ?? CGRect(x:0,y:0,width:1200,height:800),position = params["cameraPosition"] as? String ?? "bottom-right"
            let left = position.lowercased().contains("left") || position.contains("左") || position == "↙" || position == "↖",top = position.lowercased().contains("top") || position.contains("上") || position == "↖" || position == "↗"
            let panel = NSPanel(contentRect:CGRect(x:left ? screen.minX+24 : screen.maxX-size-24,y:top ? screen.maxY-size-24 : screen.minY+24,width:size,height:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.level = .floating;panel.isOpaque = false;panel.backgroundColor = .clear;panel.isMovableByWindowBackground = true;panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let view = NSView();view.wantsLayer = true;view.layer?.cornerRadius = params["cameraShape"] as? String == "square" ? 16 : size/2;view.layer?.masksToBounds = true
            let preview = AVCaptureVideoPreviewLayer(session:session);preview.videoGravity = .resizeAspectFill;preview.frame = CGRect(x:0,y:0,width:size,height:size);view.layer?.addSublayer(preview);panel.contentView = view;panel.orderFrontRegardless();self.cameraPanel = panel
        }
    }
    func closeInputs() async {
        microphoneSession?.stopRunning();microphoneSession = nil;cameraSession?.stopRunning();cameraSession = nil
        await MainActor.run { self.cameraPanel?.close();self.cameraPanel = nil;self.overlays?.close();self.overlays = nil }
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {
        let mapped = CaptureAccessPolicy.mapped(error)
        let failure = mapped as? BridgeFailure
        BridgeOutput.write(["event":"recording.error","payload":["code":failure?.code ?? "CAPTURE_CANCELLED","message":failure?.message ?? "录屏已取消"]])
    }
    func stop() async throws -> [String:Any] {
        guard let stream else { throw BridgeFailure(code:"NOT_RECORDING",message:"当前没有录屏") };self.stream = nil
        do { try await stream.stopCapture() } catch { await closeInputs();cancel();throw CaptureAccessPolicy.mapped(error) }
        await closeInputs()
        let result:[String:Any] = try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard let writer,let input,let output,began else { self.writer?.cancelWriting();self.writer = nil;self.input = nil;continuation.resume(throwing:BridgeFailure(code:"EMPTY_RECORDING",message:"录屏未捕获到画面"));return }
            input.markAsFinished();audioInput?.markAsFinished();microphoneInput?.markAsFinished();writer.finishWriting { [self] in
                self.writer = nil;self.input = nil;self.audioInput = nil;self.microphoneInput = nil;self.output = nil
                guard writer.status == .completed else { continuation.resume(throwing:BridgeFailure(code:"ENCODING",message:"录屏文件写入失败"));return }
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
                continuation.resume(returning:["recording":false,"path":output.path,"duration":Date().timeIntervalSince(self.started ?? Date())])
            }
        } };return result
    }
    func cancel() { if starting { Task { @MainActor in ScrollRegionSelector.cancelActive?() } };let stream = self.stream;self.stream = nil;Task { try? await stream?.stopCapture();await closeInputs() };queue.async { [self] in guard writer != nil else { return };writer?.cancelWriting();writer = nil;input = nil;audioInput = nil;microphoneInput = nil;if let output { try? FileManager.default.removeItem(at:output) };output = nil } }
    func status() -> [String:Any] { ["recording":stream != nil,"duration":started.map { Date().timeIntervalSince($0) } ?? 0] }
}
