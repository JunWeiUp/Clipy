import AVFoundation
import AppKit
import CoreImage

/// Source-time edits become a composition; the original media never changes.
enum VideoTimeline {
    struct Built { let composition:AVMutableComposition; let video:AVMutableCompositionTrack;let effects:[[String:Any]];let temporary:[URL] }
    static func build(asset:AVAsset,start:Double,end:Double,rate:Double,effects:[[String:Any]]) async throws -> Built {
        guard effects.count <= 128 else { throw BridgeFailure(code:"TOO_LARGE",message:"视频效果超过 128 项") }
        let sourceTracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        let composition = AVMutableComposition()
        var tracks:[(AVAssetTrack,AVMutableCompositionTrack)] = []
        for source in sourceTracks {
            guard let target = composition.addMutableTrack(withMediaType:source.mediaType,preferredTrackID:kCMPersistentTrackID_Invalid) else { continue }
            if source.mediaType == .video { target.preferredTransform = try await source.load(.preferredTransform) }
            tracks.append((source,target))
        }
        guard let video = tracks.first(where:{$0.0.mediaType == .video})?.1 else { throw BridgeFailure(code:"INVALID_MEDIA",message:"视频没有画面轨道") }
        let edits = try effects.map { effect -> [String:Any] in
            var effect = effect
            let a = effect["start"] as? Double ?? start,b = effect["end"] as? Double ?? end
            guard a.isFinite,b.isFinite,a >= start,b <= end+0.001,b >= a else { throw BridgeFailure(code:"INVALID_TIMELINE",message:"效果时间必须在裁剪范围内") }
            effect["start"] = a;effect["end"] = b;return effect
        }
        var boundaries = Set([start,end])
        for effect in edits where ["cut","speed","freeze"].contains(kind(effect)) { boundaries.insert(effect["start"] as! Double);boundaries.insert(effect["end"] as! Double) }
        let points = boundaries.sorted()
        var cursor = CMTime.zero
        var spans:[(Double,Double,Double,Double)] = []
        var temporary=[URL](),success=false
        defer{if !success{for file in temporary{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}}}
        for i in 0..<(points.count-1) {
            let a = points[i],b = points[i+1],mid = (a+b)/2
            for effect in edits where kind(effect) == "freeze" && abs((effect["start"] as! Double)-a)<0.0001 {
                let hold = effect["duration"] as? Double ?? 1
                guard hold.isFinite,hold >= 0.25,hold <= 30 else { throw BridgeFailure(code:"INVALID_TIMELINE",message:"定格时长必须为 0.25–30 秒") }
                let stillURL=try await StillVideoWriter.write(asset:asset,time:a,duration:hold);temporary.append(stillURL)
                let still=AVURLAsset(url:stillURL)
                guard let stillVideo=try await still.loadTracks(withMediaType:.video).first else{throw BridgeFailure(code:"INVALID_MEDIA",message:"定格视频没有画面")}
                let holdTime=CMTime(seconds:hold,preferredTimescale:600),holdRange=CMTimeRange(start:.zero,duration:holdTime)
                try video.insertTimeRange(holdRange,of:stillVideo,at:cursor)
                let silent=try await still.loadTracks(withMediaType:.audio).first
                for (_,target) in tracks where target.mediaType == .audio {
                    if let silent{try target.insertTimeRange(holdRange,of:silent,at:cursor)}else{target.insertEmptyTimeRange(CMTimeRange(start:cursor,duration:holdTime))}
                }
                spans.append((a,a,cursor.seconds,cursor.seconds+hold));cursor=CMTimeAdd(cursor,holdTime)

            }
            if edits.contains(where:{kind($0)=="cut" && mid >= ($0["start"] as! Double) && mid < ($0["end"] as! Double)}) { continue }
            let speed = edits.last(where:{kind($0)=="speed" && mid >= ($0["start"] as! Double) && mid < ($0["end"] as! Double)})?["speed"] as? Double ?? 1
            guard speed.isFinite,speed >= 0.25,speed <= 10 else { throw BridgeFailure(code:"INVALID_TIMELINE",message:"分段倍速必须为 0.25–10") }
            let range = CMTimeRange(start:CMTime(seconds:a,preferredTimescale:600),duration:CMTime(seconds:b-a,preferredTimescale:600))
            let resultDuration = CMTimeMultiplyByFloat64(range.duration,multiplier:1/(rate*speed))
            for (source,target) in tracks {
                try target.insertTimeRange(range,of:source,at:cursor)
                target.scaleTimeRange(CMTimeRange(start:cursor,duration:range.duration),toDuration:resultDuration)
            }
            spans.append((a,b,cursor.seconds,cursor.seconds+resultDuration.seconds))
            cursor = CMTimeAdd(cursor,resultDuration)
        }
        for effect in edits where kind(effect)=="freeze"&&abs((effect["start"] as! Double)-end)<0.0001 {
            let hold=effect["duration"] as? Double ?? 1
            guard hold.isFinite,hold>=0.25,hold<=30 else{throw BridgeFailure(code:"INVALID_TIMELINE",message:"定格时长必须为 0.25–30 秒")}
            let url=try await StillVideoWriter.write(asset:asset,time:end,duration:hold);temporary.append(url)
            let still=AVURLAsset(url:url);guard let frame=try await still.loadTracks(withMediaType:.video).first else{throw BridgeFailure(code:"INVALID_MEDIA",message:"定格视频没有画面")}
            let holdTime=CMTime(seconds:hold,preferredTimescale:600),range=CMTimeRange(start:.zero,duration:holdTime)
            try video.insertTimeRange(range,of:frame,at:cursor)
            let silence=try await still.loadTracks(withMediaType:.audio).first
            for (_,target) in tracks where target.mediaType == .audio{if let silence{try target.insertTimeRange(range,of:silence,at:cursor)}else{target.insertEmptyTimeRange(CMTimeRange(start:cursor,duration:holdTime))}}
            spans.append((end,end,cursor.seconds,cursor.seconds+hold));cursor=CMTimeAdd(cursor,holdTime)
        }
        guard cursor.seconds > 0 else { throw BridgeFailure(code:"INVALID_TIMELINE",message:"剪切后没有剩余画面") }
        var mapped:[[String:Any]]=[]
        for effect in edits where ["zoom","mask","text"].contains(kind(effect)) {
            let a=effect["start"] as! Double,b=effect["end"] as! Double
            for span in spans {
                let lo=max(a,span.0),hi=min(b,span.1)
                if span.0 == span.1 {
                    if a <= span.0,b >= span.0 {var item=effect;item["start"]=span.2;item["end"]=span.3;mapped.append(item)}
                } else if hi > lo {
                    let factor=(span.3-span.2)/(span.1-span.0)
                    var item=effect;item["start"]=span.2+(lo-span.0)*factor;item["end"]=span.2+(hi-span.0)*factor;mapped.append(item)
                }
            }
        }
        success=true;return Built(composition:composition,video:video,effects:mapped,temporary:temporary)
    }
    static func kind(_ effect:[String:Any]) -> String {let type=effect["type"] as? String ?? "";return ["剪切":"cut","缩放":"zoom","遮挡":"mask","文字":"text","变速":"speed","定格":"freeze"][type] ?? type}

    @MainActor static func filtered(asset:AVAsset,effects:[[String:Any]],scale:Double,renderSize:CGSize) throws -> AVVideoComposition? {
        let visual = effects.filter { ["zoom","mask","text"].contains(kind($0)) }
        guard !visual.isEmpty else { return nil }
        var overlays:[String:CIImage] = [:]
        for (index,effect) in visual.enumerated() where kind(effect) == "text" {
            let value = String((effect["text"] as? String ?? "文字").prefix(2000))
            let fontSize = max(8,min(200,effect["fontSize"] as? Double ?? 32))
            let text = NSAttributedString(string:value,attributes:[.font:NSFont.systemFont(ofSize:fontSize,weight:.semibold),.foregroundColor:NSColor.white,.strokeColor:NSColor.black,.strokeWidth:-2])
            let size = text.boundingRect(with:CGSize(width:renderSize.width,height:1000),options:[.usesLineFragmentOrigin]).size
            let image = NSImage(size:CGSize(width:ceil(size.width)+8,height:ceil(size.height)+8));image.lockFocus();text.draw(at:NSPoint(x:4,y:4));image.unlockFocus()
            if let data=image.tiffRepresentation,let ci=CIImage(data:data){overlays[String(index)]=ci}
        }
        let capturedOverlays=overlays
        let composition = AVVideoComposition(asset:asset,applyingCIFiltersWithHandler: { request in
            var image=request.sourceImage
            let extent=image.extent,time=request.compositionTime.seconds
            for (index,effect) in visual.enumerated() {
                let start=effect["start"] as? Double ?? 0,end=effect["end"] as? Double ?? .greatestFiniteMagnitude
                guard time >= start,time <= end else {continue}
                let x=max(0,min(1,effect["x"] as? Double ?? 0.1)),y=max(0,min(1,effect["y"] as? Double ?? 0.1))
                let w=max(0.01,min(1,effect["width"] as? Double ?? 0.3)),h=max(0.01,min(1,effect["height"] as? Double ?? 0.2))
                let rect=CGRect(x:extent.minX+x*extent.width,y:extent.maxY-(y+h)*extent.height,width:w*extent.width,height:h*extent.height).intersection(extent)
                switch kind(effect) {
                case "zoom":
                    let zoom=max(1,min(8,effect["zoom"] as? Double ?? 2))
                    let center=CGPoint(x:rect.midX,y:rect.midY)
                    let transform=CGAffineTransform(translationX:extent.midX-center.x*zoom,y:extent.midY-center.y*zoom).scaledBy(x:zoom,y:zoom)
                    image=image.transformed(by:transform).cropped(to:extent)
                case "mask":
                    let mode=effect["mode"] as? String ?? "solid"
                    var cover:CIImage
                    if mode == "blur" {cover=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:20]).cropped(to:rect)}
                    else if mode == "mosaic" {cover=image.applyingFilter("CIPixellate",parameters:[kCIInputScaleKey:18]).cropped(to:rect)}
                    else {cover=CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:rect)}
                    image=cover.composited(over:image)
                case "text":
                    if let overlay=capturedOverlays[String(index)] {let t=CGAffineTransform(translationX:extent.minX+x*extent.width,y:extent.maxY-y*extent.height-overlay.extent.height);image=overlay.transformed(by:t).composited(over:image)}
                default:break
                }
            }
            if scale != 1 {image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))}
            request.finish(with:image,context:nil)
        })
        if scale != 1,let mutable=composition.mutableCopy() as? AVMutableVideoComposition { mutable.renderSize=CGSize(width:floor(renderSize.width*scale/2)*2,height:floor(renderSize.height*scale/2)*2);return mutable }
        return composition
    }
}
