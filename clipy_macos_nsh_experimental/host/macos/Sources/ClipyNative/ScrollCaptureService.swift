import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Conservative adjacent-frame matcher. Never appends an unverified gap.
struct ScrollStitcher {
    enum Match:Equatable { case duplicate,append(Int,Int),reject(String) }
    struct Gray { let width:Int;let height:Int;let pixels:[UInt8] }
    static func gray(_ image:CGImage) -> Gray? {
        let width = min(96,image.width),height = image.height
        var bytes = [UInt8](repeating:0,count:width*height)
        let valid = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low;context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        };return valid ? Gray(width:width,height:height,pixels:bytes):nil
    }
    static func match(_ previous:CGImage,_ next:CGImage,freezeHeader:Bool=true) -> Match {
        guard previous.width == next.width,previous.height == next.height,let a = gray(previous),let b = gray(next),a.height >= 64 else { return .reject("区域尺寸变化") }
        let w = a.width,h = a.height
        func rowError(_ y:Int)->Double { var sum = 0,count = 0;for x in stride(from:8,to:w-8,by:3) { sum += abs(Int(a.pixels[y*w+x])-Int(b.pixels[y*w+x]));count += 1 };return Double(sum)/Double(max(1,count)) }
        let unchanged = (0..<h).map { rowError($0) < 1.0 }
        if unchanged.filter({$0}).count > h*98/100 { return .duplicate }
        let staticRows = freezeHeader ? unchanged : [Bool](repeating:false,count:h)
        var footer = 0
        if freezeHeader { for y in stride(from:h-1,through:max(0,h-h/4),by:-1) { if unchanged[y] { footer += 1 } else { break } } }
        let minimumOverlap = max(24,h/10)
        var candidates = [(Int,Double)]()
        for dy in 1..<(h-minimumOverlap) {
            var error = 0,count = 0,textured = 0
            for y in stride(from:0,to:h-dy,by:5) where !staticRows[y] && !staticRows[y+dy] {
                for x in stride(from:8,to:w-8,by:4) {
                    let first = Int(a.pixels[(y+dy)*w+x]),second = Int(b.pixels[y*w+x])
                    error += abs(first-second);count += 1
                    if x+4 < w,abs(second-Int(b.pixels[y*w+x+4])) > 8 { textured += 1 }
                }
            }
            guard count >= w*minimumOverlap/24,textured >= 12 else { continue }
            candidates.append((dy,Double(error)/Double(count)))
        }
        guard let best = candidates.min(by:{$0.1<$1.1}),best.1 < 5.0 else { return .reject("重叠不足或页面仍在变化，请慢慢滚动") }
        let alternative = candidates.filter { abs($0.0-best.0) > 4 }.map(\.1).min() ?? 255
        guard alternative-best.1 > 1.4 else { return .reject("重复图案，无法可靠对齐") }
        let dy = Int((Double(best.0)*Double(previous.height)/Double(h)).rounded())
        guard dy > 0,dy < previous.height else { return .reject("无有效位移") }
        return .append(dy,footer*previous.height/h)
    }
    static func append(canvas:CGImage,frame:CGImage,delta:Int,footer:Int,maxHeight:Int) throws -> CGImage {
        let width = canvas.width,height = canvas.height+delta
        guard width == frame.width,height <= maxHeight,width*height <= 80_000_000,delta > 0,delta+footer <= frame.height else { throw BridgeFailure(code:"SCROLL_LIMIT",message:"长截图已达到尺寸上限") }
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let top = canvas.cropping(to:CGRect(x:0,y:0,width:width,height:canvas.height-footer)),let bottom = frame.cropping(to:CGRect(x:0,y:frame.height-delta-footer,width:width,height:delta+footer)) else { throw BridgeFailure(code:"IMAGE_ERROR",message:"无法拼接图片") }
        context.draw(top,in:CGRect(x:0,y:delta+footer,width:width,height:canvas.height-footer));context.draw(bottom,in:CGRect(x:0,y:0,width:width,height:delta+footer))
        guard let result = context.makeImage() else { throw BridgeFailure(code:"IMAGE_ERROR",message:"无法生成长截图") };return result
    }
}

@MainActor private final class RegionSelectionView:NSView {
    var start:NSPoint?
    var current:NSPoint?
    let finish:(CGRect?)->Void
    init(frame:NSRect,finish:@escaping(CGRect?)->Void) { self.finish = finish;super.init(frame:frame) }
    required init?(coder:NSCoder) { fatalError() }
    override var acceptsFirstResponder:Bool { true }
    override func mouseDown(with event:NSEvent) { start = convert(event.locationInWindow,from:nil);current = start;needsDisplay = true }
    override func mouseDragged(with event:NSEvent) { current = convert(event.locationInWindow,from:nil);needsDisplay = true }
    override func mouseUp(with event:NSEvent) {
        guard let start,let current,let window else { finish(nil);return }
        let rect = CGRect(x:min(start.x,current.x),y:min(start.y,current.y),width:abs(start.x-current.x),height:abs(start.y-current.y));guard rect.width >= 80,rect.height >= 80 else { finish(nil);return }
        finish(window.convertToScreen(rect))
    }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { finish(nil) } }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill();bounds.fill()
        if let start,let current { let rect = CGRect(x:min(start.x,current.x),y:min(start.y,current.y),width:abs(start.x-current.x),height:abs(start.y-current.y));NSColor.controlAccentColor.setStroke();let path = NSBezierPath(rect:rect);path.lineWidth = 2;path.stroke() }
        let text = "拖动选择滚动区域 · Esc 取消" as NSString;text.draw(at:CGPoint(x:24,y:bounds.height-56),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.semibold),.foregroundColor:NSColor.white])
    }
}
@MainActor private final class ScrollSelectionPanel:NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
}
@MainActor enum ScrollRegionSelector {
    static var cancelActive:(()->Void)?
    static func appKitRect(fromCG rect:CGRect,mainTop:CGFloat) -> CGRect { CGRect(x:rect.minX,y:mainTop-rect.maxY,width:rect.width,height:rect.height) }
    static func select() async -> CGRect? {
        guard cancelActive == nil else { return nil }
        return await withCheckedContinuation { continuation in
            var windows = [NSPanel](),finished = false;let previousApp = NSWorkspace.shared.frontmostApplication
            let completion:(CGRect?)->Void = { rect in guard !finished else { return };finished = true;for window in windows { window.orderOut(nil);window.close() };windows.removeAll();cancelActive = nil;previousApp?.activate(options:[.activateIgnoringOtherApps]);continuation.resume(returning:rect) }
            cancelActive = { completion(nil) }
            for screen in NSScreen.screens {
                let panel = ScrollSelectionPanel(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false);panel.level = .screenSaver;panel.isOpaque = false;panel.backgroundColor = .clear;panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
                let view = RegionSelectionView(frame:CGRect(origin:.zero,size:screen.frame.size),finish:completion);panel.contentView = view;panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(view);windows.append(panel)
            }
        }
    }
}
@MainActor final class ScrollCaptureService:NSObject,NSWindowDelegate {
    let root:URL
    var panel:NSPanel?
    let preview = NSImageView()
    let label = NSTextField(labelWithString:"缓慢滚动目标页面")
    var task:Task<Void,Never>?
    var completion:CheckedContinuation<[String:Any],Error>?
    var canvas:CGImage?
    var previous:CGImage?
    var rect:CGRect = .zero
    var maxHeight = 20000
    var selecting = false
    var automatic = false
    var freezeHeader = true
    var scrollStep = 120
    var unchangedAttempts = 0
    init(root:URL) { self.root = root }
    func start(_ p:[String:Any]) async throws -> [String:Any] {
        guard task == nil,completion == nil,canvas == nil,!selecting else { throw BridgeFailure(code:"BUSY",message:"已有长截图进行中") };guard CGPreflightScreenCaptureAccess() else { throw BridgeFailure(code:"PERMISSION_DENIED",message:"长截图需要屏幕录制权限") }
        freezeHeader = p["freezeHeader"] as? Bool ?? p["scrollFreezeHeader"] as? Bool ?? true
        automatic = p["autoScroll"] as? Bool ?? false;scrollStep = min(max(p["scrollSpeed"] as? Int ?? 3,1),10)*40;unchangedAttempts = 0
        if automatic && !AXIsProcessTrusted() { throw BridgeFailure(code:"PERMISSION_DENIED",message:"自动滚动需要辅助功能权限，也可关闭后手动滚动") }
        selecting = true
        let target:CGRect?
        if let raw=p["rect"] as? [String:Double],let x=raw["x"],let y=raw["y"],let width=raw["width"],let height=raw["height"],x.isFinite,y.isFinite,width.isFinite,height.isFinite,width>=80,height>=80 {
            let cg=CGRect(x:x,y:y,width:width,height:height)
            target=ScrollRegionSelector.appKitRect(fromCG:cg,mainTop:NSScreen.screens.first?.frame.maxY ?? 0)
        } else if p["rect"] != nil { selecting=false;throw BridgeFailure(code:"INVALID_REGION",message:"滚动截图选区无效，至少需要 80 × 80 点") }
        else { target = await ScrollRegionSelector.select() }
        selecting = false
        guard let target else { return ["cancelled":true] }
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0;rect = CGRect(x:target.minX,y:mainTop-target.maxY,width:target.width,height:target.height);maxHeight = min(max(p["maxHeight"] as? Int ?? 20000,1000),40000)
        guard let image = capture() else { throw BridgeFailure(code:"CAPTURE_FAILED",message:"无法截取选区") };canvas = image;previous = image;showPanel(target);updatePreview()
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            task = Task { [weak self] in
                var observed:CGImage?
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:350_000_000);guard !Task.isCancelled,let self else { return }
                    guard let current = self.capture() else { self.label.stringValue = "捕获失败，请检查屏幕录制权限";continue }
                    if let observed,ScrollStitcher.match(observed,current,freezeHeader:self.freezeHeader) == .duplicate { self.accept(current) }
                    observed = current
                }
            }
        }
    }
    func capture() -> CGImage? {
        if let panel { return CGWindowListCreateImage(rect,.optionOnScreenBelowWindow,CGWindowID(panel.windowNumber),[.bestResolution]) }
        return CGWindowListCreateImage(rect,.optionOnScreenOnly,kCGNullWindowID,[.bestResolution])
    }
    func accept(_ image:CGImage) {
        guard let previous,let canvas else { return }
        switch ScrollStitcher.match(previous,image,freezeHeader:freezeHeader) {
        case .duplicate:
            if automatic { unchangedAttempts += 1;if unchangedAttempts >= 4 { automatic = false;label.stringValue = "页面已停止增长，请完成保存" } else { scrollPage() } }
        case .reject(let reason):label.stringValue = reason
        case .append(let delta,let footer):
            do { self.canvas = try ScrollStitcher.append(canvas:canvas,frame:image,delta:delta,footer:footer,maxHeight:maxHeight);self.previous = image;unchangedAttempts = 0;updatePreview();if automatic { scrollPage() } }
            catch { label.stringValue = "已到长截图尺寸上限，请完成保存";task?.cancel();task = nil }
        }
    }
    func scrollPage() {
        let event = CGEvent(scrollWheelEvent2Source:CGEventSource(stateID:.combinedSessionState),units:.pixel,wheelCount:1,wheel1:Int32(-scrollStep),wheel2:0,wheel3:0);event?.location = CGPoint(x:rect.midX,y:rect.midY);event?.post(tap:.cghidEventTap)
    }
    func updatePreview() {
        guard let canvas else { return };preview.image = NSImage(cgImage:canvas,size:CGSize(width:canvas.width,height:canvas.height));label.stringValue = "\(canvas.width) × \(canvas.height) · 停稳后自动拼接"
        BridgeOutput.write(["event":"capture.scroll.progress","payload":["width":canvas.width,"height":canvas.height]])
    }
    func showPanel(_ target:CGRect) {
        let visible = NSScreen.screens.first(where:{$0.frame.intersects(target)})?.visibleFrame ?? NSScreen.main!.visibleFrame
        let panel = NSPanel(contentRect:CGRect(x:min(visible.maxX-250,target.maxX+12),y:max(visible.minY,target.minY),width:240,height:380),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);panel.title = "滚动截图";panel.level = .floating;panel.delegate = self;panel.isReleasedWhenClosed = false
        let stack = NSStackView();stack.orientation = .vertical;stack.spacing = 12;stack.edgeInsets = NSEdgeInsets(top:12,left:12,bottom:12,right:12)
        preview.imageScaling = .scaleProportionallyUpOrDown;preview.setContentHuggingPriority(.defaultLow,for:.vertical);preview.heightAnchor.constraint(equalToConstant:270).isActive = true;label.font = .systemFont(ofSize:11);label.lineBreakMode = .byWordWrapping;label.maximumNumberOfLines = 3
        let actions = NSStackView();actions.orientation = .horizontal;let done = NSButton(title:"完成",target:self,action:#selector(finishCapture)),cancel = NSButton(title:"取消",target:self,action:#selector(cancelCapture));done.keyEquivalent = "\r";cancel.keyEquivalent = "\u{1b}";actions.addArrangedSubview(cancel);actions.addArrangedSubview(done)
        stack.addArrangedSubview(preview);stack.addArrangedSubview(label);stack.addArrangedSubview(actions);panel.contentView = stack;self.panel = panel;panel.orderFrontRegardless()
    }
    @objc func finishCapture() {
        guard let canvas,let completion else { return };self.completion = nil;task?.cancel();task = nil;panel?.delegate = nil;panel?.close();panel = nil;self.canvas = nil;previous = nil;preview.image = nil
        do { let directory = root.appendingPathComponent("scroll-captures");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let url = directory.appendingPathComponent(UUID().uuidString+".png")
            guard let writer = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw BridgeFailure(code:"WRITE_FAILED",message:"无法保存长截图") };CGImageDestinationAddImage(writer,canvas,nil);guard CGImageDestinationFinalize(writer) else { throw BridgeFailure(code:"WRITE_FAILED",message:"长截图保存失败") };try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);completion.resume(returning:["path":url.path,"width":canvas.width,"height":canvas.height,"cancelled":false])
        } catch { completion.resume(throwing:error) }
    }
    @objc func cancelCapture() { ScrollRegionSelector.cancelActive?();let completion = self.completion;self.completion = nil;task?.cancel();task = nil;panel?.delegate = nil;panel?.close();panel = nil;canvas = nil;previous = nil;preview.image = nil;completion?.resume(returning:["cancelled":true]) }
    func windowWillClose(_ notification:Notification) { cancelCapture() }
}
