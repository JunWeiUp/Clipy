import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// System media operations. No encoder crates, subprocesses or whole-file JS buffers.
@MainActor enum MediaService {
    static var exports: [String: AVAssetExportSession] = [:]
    static var cancelled = Set<String>()
    static var active = Set<String>()
    static var transcodes:[String:Task<Void,Error>]=[:]
    static var builders:[String:Task<VideoTimeline.Built,Error>]=[:]
    static func invoke(_ method: String, _ p: [String:Any], root: URL) async throws -> Any {
        switch method {
        case "files.stageMedia":
            let source = try sourceURL(p)
            let size = try source.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
            guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 1024*1024*1024 else { throw failure("请选择不超过 1 GiB 的媒体文件") }
            let folder = root.appendingPathComponent("imports",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let paths = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey])
            let used = paths.reduce(0) { $0 + ((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
            guard used + (size.fileSize ?? 0) <= 4*1024*1024*1024 else { throw failure("媒体暂存已达 4 GiB，请清理后再导入") }
            let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at:source,to:destination)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            return ["path":destination.path]
        case "files.saveCopy":
            let source = try sourceURL(p)
            let panel = NSSavePanel(); panel.nameFieldStringValue = source.lastPathComponent
            NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
            guard await panel.begin() == .OK, let destination = panel.url else { return ["cancelled":true] }
            guard source.standardizedFileURL != destination.standardizedFileURL else { return ["path":source.path] }
            // Save panel authorizes replacement. FileManager's replacement leaves source intact.
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".clipy-"+UUID().uuidString)
            try FileManager.default.copyItem(at:source,to:temporary)
            do { if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary) } else { try FileManager.default.moveItem(at:temporary,to:destination) } }
            catch { try? FileManager.default.removeItem(at:temporary); throw error }
            return ["path":destination.path]
        case "video.info":
            let asset = AVURLAsset(url:try sourceURL(p))
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            guard let track = tracks.first else { throw failure("视频中没有画面轨道") }
            let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
            let rect = CGRect(origin:.zero,size:size).applying(transform)
            return ["duration":duration.seconds,"width":abs(rect.width),"height":abs(rect.height),"fps":try await track.load(.nominalFrameRate),"audioTracks":try await asset.loadTracks(withMediaType:.audio).count]
        case "video.cancel":
            if let id = p["id"] as? String { exports[id]?.cancelExport();transcodes[id]?.cancel();builders[id]?.cancel();cancelled.insert(id) }
            else { for session in exports.values { session.cancelExport() };for task in transcodes.values{task.cancel()};for task in builders.values{task.cancel()};cancelled.formUnion(active) }
            return true
        case "video.export":return try await export(p,root:root)
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"尚未实现媒体操作：\(method)")
        }
    }
    static func sourceURL(_ p:[String:Any]) throws -> URL {
        guard let path = p["path"] as? String,!path.isEmpty,FileManager.default.fileExists(atPath:path) else { throw failure("请先选择现有媒体文件") }
        return URL(fileURLWithPath:path)
    }
    static func failure(_ text:String) -> BridgeFailure { BridgeFailure(code:"INVALID_MEDIA",message:text) }
    static func export(_ p:[String:Any],root:URL) async throws -> Any {
        guard active.isEmpty else { throw BridgeFailure(code:"BUSY",message:"已有视频正在导出") }
        let id=p["id"] as? String ?? UUID().uuidString;active.insert(id);defer{active.remove(id);cancelled.remove(id)}
        let source = try sourceURL(p), asset = AVURLAsset(url:source)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric,duration.seconds > 0,duration.seconds <= 14400 else { throw failure("视频时长无效或超过 4 小时") }
        let start = (p["start"] as? Double ?? 0), end = p["end"] as? Double ?? duration.seconds
        let rate = p["speed"] as? Double ?? 1
        guard start.isFinite,end.isFinite,rate.isFinite,start >= 0,end > start,end <= duration.seconds+0.01,rate >= 0.25,rate <= 10 else { throw failure("请检查入点、出点与播放速度") }
        if Task.isCancelled||cancelled.contains(id){throw BridgeFailure(code:"CANCELLED",message:"已取消视频导出")}
        let effects = p["effects"] as? [[String:Any]] ?? []
        let builder=Task{try await VideoTimeline.build(asset:asset,start:start,end:end,rate:rate,effects:effects)};builders[id]=builder
        let built:VideoTimeline.Built
        do{built=try await withTaskCancellationHandler(operation:{try await builder.value},onCancel:{builder.cancel()})}catch{builders.removeValue(forKey:id);if error is CancellationError||cancelled.contains(id){throw BridgeFailure(code:"CANCELLED",message:"已取消视频导出")};throw error};builders.removeValue(forKey:id)
        let composition = built.composition,track = built.video
        defer{for file in built.temporary{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}}
        let directory = root.appendingPathComponent("exports",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let format = (p["format"] as? String ?? "mp4").lowercased()
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format == "gif" ? "gif" : "mp4")
        if format == "gif" { var settings=p;settings["effects"]=built.effects;return try await exportGIF(composition,settings,id,output) }
        guard format == "mp4" else { throw failure("请选择 MP4 或 GIF") }
        guard let session = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality) else { throw failure("系统无法创建导出会话") }
        session.outputURL = output;session.outputFileType = .mp4;session.shouldOptimizeForNetworkUse = true
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin:.zero,size:natural).applying(transform)
        let width = abs(bounds.width),height = abs(bounds.height)
        let scale = p["scale"] as? Double ?? 1
        guard scale.isFinite,scale > 0,scale <= 1 else { throw failure("导出缩放必须大于 0 且不超过 1") }
        if let filters = try VideoTimeline.filtered(asset:composition,effects:built.effects,scale:scale,renderSize:CGSize(width:width,height:height)) { session.videoComposition=filters }
        else if scale != 1 {
            let vc = AVMutableVideoComposition();vc.renderSize = CGSize(width:floor(width*scale/2)*2,height:floor(height*scale/2)*2);vc.frameDuration = CMTime(value:1,timescale:30)
            let instruction = AVMutableVideoCompositionInstruction();instruction.timeRange = CMTimeRange(start:.zero,duration:composition.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack:track);layer.setTransform(transform.concatenating(CGAffineTransform(scaleX:scale,y:scale)),at:.zero);instruction.layerInstructions = [layer];vc.instructions = [instruction];session.videoComposition = vc
        }
        if Task.isCancelled||cancelled.contains(id){throw BridgeFailure(code:"CANCELLED",message:"已取消视频导出")}
        let quality=(p["quality"] as? String ?? "high").lowercased()
        if quality=="medium" || quality=="low" {
            let compositionSettings=session.videoComposition
            let dimensions=compositionSettings?.renderSize ?? CGSize(width:width,height:height)
            let task=Task.detached(priority:.userInitiated){try await VideoTranscoder.encode(asset:composition,videoComposition:compositionSettings,size:dimensions,output:output,quality:quality,id:id)}
            transcodes[id]=task;defer{transcodes.removeValue(forKey:id)}
            try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            return try await resultInfo(output,id:id,quality:quality)
        }
        exports[id] = session
        defer { exports.removeValue(forKey:id);cancelled.remove(id) }
        await withTaskCancellationHandler(operation:{await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in session.exportAsynchronously { continuation.resume() } }},onCancel:{session.cancelExport()})
        guard session.status == .completed else { try? FileManager.default.removeItem(at:output);if session.status == .cancelled { throw BridgeFailure(code:"CANCELLED",message:"已取消导出") };throw session.error ?? failure("系统导出失败") }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        return try await resultInfo(output,id:id,quality:"high")
    }
    static func resultInfo(_ path:URL,id:String,quality:String) async throws -> [String:Any]{
        let asset=AVURLAsset(url:path);let duration=try await asset.load(.duration);guard let track=try await asset.loadTracks(withMediaType:.video).first else{throw failure("导出视频缺少画面")};let size=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform);let rect=CGRect(origin:.zero,size:size).applying(transform);let fps=try await track.load(.nominalFrameRate);let bytes=(try FileManager.default.attributesOfItem(atPath:path.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ["id":id,"path":path.path,"format":"mp4","quality":quality,"duration":duration.seconds,"width":abs(rect.width),"height":abs(rect.height),"fps":fps,"bytes":bytes]
    }
    static func exportGIF(_ asset:AVAsset,_ p:[String:Any],_ id:String,_ output:URL) async throws -> Any {
        let quality=(p["quality"] as? String ?? "high").lowercased()
        let fps = min(20,max(1,p["fps"] as? Double ?? (quality=="low" ? 6:quality=="medium" ? 10:15)))
        let duration = try await asset.load(.duration).seconds
        let count = Int(ceil(duration*fps))
        guard count <= 1200 else { throw failure("GIF 超过 1200 帧，请缩短裁剪范围或降低帧率") }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,UTType.gif.identifier as CFString,count,nil) else { throw failure("无法创建 GIF") }
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform = true
        if let track=try await asset.loadTracks(withMediaType:.video).first{let natural=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform);let bounds=CGRect(origin:.zero,size:natural).applying(transform);let factor=p["scale"] as? Double ?? 1;guard factor.isFinite,factor>0,factor<=1 else{throw failure("GIF 缩放参数无效")};let requested=CGSize(width:abs(bounds.width)*factor,height:abs(bounds.height)*factor);let bounded=min(1,2048/max(requested.width,requested.height));generator.maximumSize=CGSize(width:max(1,requested.width*bounded),height:max(1,requested.height*bounded))}
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        if let video = try await asset.loadTracks(withMediaType:.video).first { let size=try await video.load(.naturalSize);generator.videoComposition=try VideoTimeline.filtered(asset:asset,effects:p["effects"] as? [[String:Any]] ?? [],scale:1,renderSize:size) }
        defer { cancelled.remove(id) }
        do {
            for i in 0..<count {
                if cancelled.contains(id) || Task.isCancelled { generator.cancelAllCGImageGeneration();throw BridgeFailure(code:"CANCELLED",message:"已取消 GIF 导出") }
                let time = CMTime(seconds:Double(i)/fps,preferredTimescale:600)
                let image = try await generator.image(at:time).image
                CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1/fps]] as CFDictionary)
                if i % 10 == 0 { BridgeOutput.write(["event":"video.progress","payload":["id":id,"progress":Double(i+1)/Double(count)]]);await Task.yield() }
            }
            guard CGImageDestinationFinalize(destination) else { throw failure("GIF 写入失败") }
            let source=CGImageSourceCreateWithURL(output as CFURL,nil);let properties=source.flatMap{CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [CFString:Any]}
            let width=(properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height=(properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let bytes=(try FileManager.default.attributesOfItem(atPath:output.path)[.size] as? NSNumber)?.int64Value ?? 0
            let result:[String:Any]=["id":id,"path":output.path,"format":"gif","duration":Double(count)/fps,"fps":fps,"width":width,"height":height,"bytes":bytes]
            return result
        } catch { try? FileManager.default.removeItem(at:output);throw error }
    }
}
