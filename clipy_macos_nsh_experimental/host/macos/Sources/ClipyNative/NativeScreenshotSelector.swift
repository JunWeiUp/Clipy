import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Independent AppKit selector. It returns point geometry; the capture owner exports native pixels.
@MainActor enum NativeScreenshotSelector {
    struct Selection {let rect:CGRect;let displayId:CGDirectDisplayID;var windowId:CGWindowID? = nil;var action:String? = nil;var frozenImage:CGImage? = nil}
    static var active:ScreenshotSelectionOwner?
    static func select(mode:String="region",snapping:Bool=true,magnifier:Bool=true,elementSnapping:Bool=true,selectionOnly:Bool=false)async throws->Selection?{
        guard active==nil else{throw BridgeFailure(code:"BUSY",message:"截图选区已打开")}
        let owner=ScreenshotSelectionOwner(mode:mode,snapping:snapping,magnifier:magnifier,elementSnapping:elementSnapping,selectionOnly:selectionOnly);active=owner
        defer{active=nil}
        do { let result=try await owner.begin();if result != nil{try await Task.sleep(nanoseconds:100_000_000)};return result } catch { throw CaptureAccessPolicy.mapped(error) }
    }
    static func cancel(){active?.finish(nil)}
    /// AppKit's bottom-left global space → CoreGraphics top-left global space.
    static func cgRect(_ local:CGRect,screen:CGRect,mainTop:CGFloat)->CGRect{let global=local.offsetBy(dx:screen.minX,dy:screen.minY);return CGRect(x:global.minX,y:mainTop-global.maxY,width:global.width,height:global.height)}
    static func appRect(_ rect:CGRect,screen:CGRect,mainTop:CGFloat)->CGRect{CGRect(x:rect.minX-screen.minX,y:mainTop-rect.maxY-screen.minY,width:rect.width,height:rect.height)}
    static func dragged(from anchor:CGPoint,to point:CGPoint,square:Bool,bounds:CGRect)->CGRect{var dx=point.x-anchor.x,dy=point.y-anchor.y;if square{let availableX=dx<0 ? anchor.x-bounds.minX:bounds.maxX-anchor.x,availableY=dy<0 ? anchor.y-bounds.minY:bounds.maxY-anchor.y;let side=max(0,min(max(abs(dx),abs(dy)),availableX,availableY));dx=dx<0 ? -side:side;dy=dy<0 ? -side:side};let result=CGRect(x:min(anchor.x,anchor.x+dx),y:min(anchor.y,anchor.y+dy),width:abs(dx),height:abs(dy)).intersection(bounds);return result.isNull ? .zero:result}
    static func confirmed(local:CGRect,screen:CGRect,mainTop:CGFloat,displayId:CGDirectDisplayID,windowId:CGWindowID?,windowRect:CGRect?) -> Selection {
        if let windowId,let windowRect,!windowRect.isNull,windowRect.width>=2,windowRect.height>=2 { return Selection(rect:windowRect,displayId:displayId,windowId:windowId) }
        return Selection(rect:cgRect(local,screen:screen,mainTop:mainTop),displayId:displayId)
    }
    static func frozenCrop(_ image:CGImage,localRect:CGRect,viewSize:CGSize) -> CGImage? {
        guard viewSize.width>0,viewSize.height>0 else{return nil}
        let clipped=localRect.intersection(CGRect(origin:.zero,size:viewSize));guard !clipped.isNull,clipped.width>=2,clipped.height>=2 else{return nil}
        let sx=CGFloat(image.width)/viewSize.width,sy=CGFloat(image.height)/viewSize.height
        let x=(clipped.minX*sx).rounded(),y=((viewSize.height-clipped.maxY)*sy).rounded()
        let width=min(CGFloat(image.width)-x,(clipped.width*sx).rounded()),height=min(CGFloat(image.height)-y,(clipped.height*sy).rounded())
        guard width>=2,height>=2 else{return nil};return image.cropping(to:CGRect(x:x,y:y,width:width,height:height))
    }
    static func pixelSize(contentRect:CGRect,pointPixelScale:CGFloat) throws -> (width:Int,height:Int) {
        let width=contentRect.width*pointPixelScale,height=contentRect.height*pointPixelScale
        guard width.isFinite,height.isFinite,pointPixelScale>0,width>=2,height>=2,width*height<=80_000_000 else { throw BridgeFailure(code:"INVALID_REGION",message:"截图区域无效或超过 80 MP") }
        return (Int(width.rounded()),Int(height.rounded()))
    }
    static func moved(_ rect:CGRect,by delta:CGPoint,bounds:CGRect)->CGRect{var next=rect.offsetBy(dx:delta.x,dy:delta.y);next.origin.x=min(max(bounds.minX,next.minX),max(bounds.minX,bounds.maxX-next.width));next.origin.y=min(max(bounds.minY,next.minY),max(bounds.minY,bounds.maxY-next.height));return next}
}

@MainActor final class ScreenshotSelectionOwner {
    struct WindowCandidate {let rect:CGRect;let pid:pid_t;let windowId:CGWindowID}
    var mode:String
    var snapping:Bool
    let magnifier:Bool
    let elementSnapping:Bool
    let selectionOnly:Bool
    let previous=NSWorkspace.shared.frontmostApplication
    let mainTop=NSScreen.screens.first?.frame.maxY ?? 0
    var windows:[ScreenshotSelectionPanel]=[]
    var candidates:[WindowCandidate]=[]
    var continuation:CheckedContinuation<NativeScreenshotSelector.Selection?,Error>?
    var completed=false
    private(set) var result:NativeScreenshotSelector.Selection?
    var restoreFocus=true
    var generation=0
    struct AXRequest { let point:CGPoint;let pid:pid_t;let window:CGRect;let ticket:Int;weak var view:ScreenshotSelectionCanvas? }
    var pendingAX:AXRequest?
    var axWorker:Task<Void,Never>?
    var windowScales:[CGWindowID:CGFloat]=[:]
    var lastAX=Date.distantPast
    init(mode:String,snapping:Bool,magnifier:Bool,elementSnapping:Bool=true,selectionOnly:Bool=false){self.mode=mode;self.snapping=snapping;self.magnifier=magnifier;self.elementSnapping=elementSnapping;self.selectionOnly=selectionOnly}
    func begin()async throws->NativeScreenshotSelector.Selection?{
        // Hide only this experiment's own runtime, never another app or the
        // separately maintained formal client. JS still owns restore/navigation.
        if let parent=NSRunningApplication(processIdentifier:getppid()),parent.bundleIdentifier?.hasPrefix("dev.clipy.tsx")==true { _ = parent.hide();try await Task.sleep(nanoseconds:80_000_000) }
        if mode=="fullscreen"||mode=="screen"{guard let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}),let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{return nil};return .init(rect:NativeScreenshotSelector.cgRect(CGRect(origin:.zero,size:screen.frame.size),screen:screen.frame,mainTop:mainTop),displayId:id.uint32Value)}
        let info=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        candidates=info.compactMap{value in guard let layer=value[kCGWindowLayer as String] as? Int,layer>=0,layer<=10,let pid=value[kCGWindowOwnerPID as String] as? pid_t,pid != getpid(),let dictionary=value[kCGWindowBounds as String] as? [String:Any],let rect=CGRect(dictionaryRepresentation:dictionary as CFDictionary),let windowId=value[kCGWindowNumber as String] as? CGWindowID,rect.width>=4,rect.height>=4 else{return nil};return WindowCandidate(rect:rect,pid:pid,windowId:windowId)}
        let snapshots=try await freezeScreens();guard !completed else{return nil}
        return try await withTaskCancellationHandler(operation:{try await withCheckedThrowingContinuation{continuation in self.continuation=continuation;NSApp.activate(ignoringOtherApps:true);for screen in NSScreen.screens{guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{continue};let panel=ScreenshotSelectionPanel(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false);panel.level = .screenSaver;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isReleasedWhenClosed=false;let view=ScreenshotSelectionCanvas(frame:CGRect(origin:.zero,size:screen.frame.size),screen:screen,displayId:number.uint32Value,snapshot:snapshots[number.uint32Value],owner:self);panel.contentView=view;view.mouse=CGPoint(x:NSEvent.mouseLocation.x-screen.frame.minX,y:NSEvent.mouseLocation.y-screen.frame.minY);view.pointerInside=view.bounds.contains(view.mouse);if view.pointerInside{self.snap(view.mouse,view:view)};windows.append(panel);panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(view)};if let pointerWindow=windows.first(where:{$0.frame.contains(NSEvent.mouseLocation)}){pointerWindow.makeKey();pointerWindow.makeFirstResponder(pointerWindow.contentView)};if windows.isEmpty{finish(nil)}}},onCancel:{Task{@MainActor in self.finish(nil)}})
    }
    func freezeScreens()async throws->[CGDirectDisplayID:CGImage]{
        guard #available(macOS 14.0,*)else{return [:]};let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true);var result:[CGDirectDisplayID:CGImage]=[:]
        for window in content.windows { windowScales[window.windowID]=CGFloat(SCContentFilter(desktopIndependentWindow:window).pointPixelScale) }
        for display in content.displays{try Task.checkCancellation();let configuration=SCStreamConfiguration();let scale=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==display.displayID})?.backingScaleFactor ?? 1;configuration.width=Int((display.frame.width*scale).rounded());configuration.height=Int((display.frame.height*scale).rounded());configuration.showsCursor=false;let filter=SCContentFilter(display:display,excludingApplications:content.applications.filter{$0.processID==getppid()},exceptingWindows:[]);result[display.displayID]=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)};return result
    }
    func finish(_ result:NativeScreenshotSelector.Selection?){guard !completed else{return};completed=true;self.result=result;generation+=1;pendingAX=nil;axWorker?.cancel();axWorker=nil;for panel in windows{panel.orderOut(nil);panel.contentView=nil;panel.close()};windows.removeAll();if restoreFocus,let previous,!previous.isTerminated,previous.processIdentifier != getppid(){previous.activate(options:[])};continuation?.resume(returning:result);continuation=nil}
    func selected(_ local:CGRect,screen:NSScreen,id:CGDirectDisplayID,windowId:CGWindowID?=nil,action:String?=nil,snapshot:CGImage?=nil,viewSize:CGSize?=nil){
        guard local.width>=2,local.height>=2 else{return}
        let candidate=candidates.first{$0.windowId==windowId}
        var result=NativeScreenshotSelector.confirmed(local:local,screen:screen.frame,mainTop:mainTop,displayId:id,windowId:candidate?.windowId,windowRect:candidate?.rect);result.action=action;if candidate==nil,let snapshot,let viewSize{result.frozenImage=NativeScreenshotSelector.frozenCrop(snapshot,localRect:local,viewSize:viewSize)};finish(result)
    }
    func window(at global:CGPoint)->WindowCandidate?{candidates.first{$0.rect.contains(global)}}
    func snap(_ point:CGPoint,view:ScreenshotSelectionCanvas){
        generation+=1
        guard snapping,view.selection==nil else{view.hover=nil;view.hoverWindowId=nil;view.needsDisplay=true;return}
        let global=CGPoint(x:point.x+view.screen.frame.minX,y:mainTop-(point.y+view.screen.frame.minY));guard let window=window(at:global)else{view.hover=nil;view.hoverWindowId=nil;view.needsDisplay=true;return}
        view.hover=NativeScreenshotSelector.appRect(window.rect,screen:view.screen.frame,mainTop:mainTop).intersection(view.bounds);view.hoverWindowId=window.windowId;view.needsDisplay=true
        guard elementSnapping,mode != "window",AXIsProcessTrusted(),window.pid != getpid(),window.pid != getppid() else{return}
        if let app=NSRunningApplication(processIdentifier:window.pid),app.bundleIdentifier?.hasPrefix("dev.clipy.tsx")==true{return}
        pendingAX=AXRequest(point:global,pid:window.pid,window:window.rect,ticket:generation,view:view)
        guard axWorker==nil else{return}
        axWorker=Task<Void,Never>{@MainActor [weak self] in
            defer { self?.axWorker=nil }
            while let self,!self.completed,!Task.isCancelled,self.pendingAX != nil {
                let wait=max(0,0.12-Date().timeIntervalSince(self.lastAX));if wait>0{try? await Task.sleep(nanoseconds:UInt64(wait*1_000_000_000))}
                guard !Task.isCancelled,!self.completed,let request=self.pendingAX else{return};self.pendingAX=nil;self.lastAX=Date()
                let rect=await Task.detached(priority:.userInitiated){Self.elementRect(pid:request.pid,point:request.point,window:request.window)}.value
                guard !Task.isCancelled,!self.completed else{return}
                if self.generation==request.ticket,let view=request.view,view.selection==nil,let rect {
                    view.hover=NativeScreenshotSelector.appRect(rect,screen:view.screen.frame,mainTop:self.mainTop).intersection(view.bounds);view.hoverWindowId=nil;view.needsDisplay=true
                }
            }
        }
    }
    nonisolated private static func elementRect(pid:pid_t,point:CGPoint,window:CGRect)->CGRect?{
        guard pid != getpid(),pid != getppid()else{return nil};let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.06);var element:AXUIElement?;guard AXUIElementCopyElementAtPosition(app,Float(point.x),Float(point.y),&element) == .success,let element else{return nil};AXUIElementSetMessagingTimeout(element,0.06);var position:CFTypeRef?,size:CFTypeRef?;guard AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success,AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success,let position,let size,CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID()else{return nil};var origin=CGPoint.zero,dimensions=CGSize.zero;guard AXValueGetValue(position as! AXValue,.cgPoint,&origin),AXValueGetValue(size as! AXValue,.cgSize,&dimensions)else{return nil};let rect=CGRect(origin:origin,size:dimensions);guard rect.width>=4,rect.height>=4,rect.contains(point),window.contains(rect)else{return nil};return rect
    }
}
@MainActor final class ScreenshotSelectionPanel:NSPanel {
    override var canBecomeKey:Bool{true};override var canBecomeMain:Bool{false}
    override func cancelOperation(_ sender:Any?) { (contentView as? ScreenshotSelectionCanvas)?.owner?.finish(nil) }
}
@MainActor final class ScreenshotSelectionCanvas:NSView {
    let screen:NSScreen
    let displayId:CGDirectDisplayID
    let snapshot:CGImage?
    weak var owner:ScreenshotSelectionOwner?
    var anchor:CGPoint?
    var mouse=CGPoint.zero
    var pointerInside=false
    var selection:CGRect?
    var hover:CGRect?
    var hoverWindowId:CGWindowID?
    var selectionWindowId:CGWindowID?
    var tracking:NSTrackingArea?
    var space=false
    var moveStart:CGPoint?
    var original:CGRect?
    var resizeHandle:ScreenshotResizeHandle?
    var spaceStart:CGPoint?
    var spaceRect:CGRect?
    var spaceAnchor:CGPoint?
    var aspectRatio:CGFloat?
    var ignoredMouseDown=false
    lazy var idleControls=ScreenshotSelectionControls(canvas:self,selected:false)
    lazy var actionControls=ScreenshotSelectionControls(canvas:self,selected:true)
    lazy var sizeControls=ScreenshotSizeControls(canvas:self)
    init(frame:CGRect,screen:NSScreen,displayId:CGDirectDisplayID,snapshot:CGImage?,owner:ScreenshotSelectionOwner){self.screen=screen;self.displayId=displayId;self.snapshot=snapshot;self.owner=owner;super.init(frame:frame);addSubview(idleControls);addSubview(actionControls);addSubview(sizeControls);updateControls()}
    required init?(coder:NSCoder){nil}
    var pixelScale:CGFloat { guard let snapshot,bounds.width>0 else{return screen.backingScaleFactor};return CGFloat(snapshot.width)/bounds.width }
    override var acceptsFirstResponder:Bool{true}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.crosshair);if let rect=selection{addCursorRect(rect,cursor:.openHand);for handle in ScreenshotResizeHandle.allCases{let p=handle.point(in:rect);addCursorRect(CGRect(x:p.x-7,y:p.y-7,width:14,height:14),cursor:handle.axes.0==0.5 ? .resizeUpDown:.resizeLeftRight)}}}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)};let next=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil);tracking=next;addTrackingArea(next);window?.acceptsMouseMovedEvents=true}
    override func layout(){super.layout();updateControls()}
    func updateControls(){
        let selected=selection != nil;idleControls.isHidden=selected;actionControls.isHidden = !selected;sizeControls.isHidden = !selected
        let bar=selected ? actionControls:idleControls,barWidth:CGFloat=selected ? 694:232
        bar.frame=CGRect(x:max(8,(bounds.width-barWidth)/2),y:28,width:min(barWidth,bounds.width-16),height:56)
        if let rect=selection {
            let width:CGFloat=min(600,bounds.width-16),y=rect.maxY+10+34<=bounds.maxY-8 ? rect.maxY+10:max(96,rect.minY-44)
            sizeControls.frame=CGRect(x:min(max(8,rect.minX),bounds.maxX-width-8),y:min(y,bounds.height-42),width:width,height:34)
            let measured=selectionWindowId.flatMap{id in owner?.candidates.first{$0.windowId==id}?.rect} ?? rect;let scale=selectionWindowId.flatMap{owner?.windowScales[$0]} ?? pixelScale;sizeControls.update(measured,scale:scale)
        }
    }
    func changed(){updateControls();needsDisplay=true;window?.invalidateCursorRects(for:self)}
    override func mouseMoved(with event:NSEvent){pointerInside=true;if window?.isKeyWindow != true{window?.makeKey()};mouse=convert(event.locationInWindow,from:nil);owner?.snap(mouse,view:self);needsDisplay=true}
    override func mouseExited(with event:NSEvent){pointerInside=false;needsDisplay=true}
    override func mouseDown(with event:NSEvent){
        pointerInside=true;mouse=convert(event.locationInWindow,from:nil);ignoredMouseDown=false
        if let selected=selection {
            if event.clickCount>=2,selected.contains(mouse){confirm(action:nil);return}
            if let handle=ScreenshotSelectionGeometry.handle(at:mouse,rect:selected){resizeHandle=handle;original=selected;return}
            if selected.contains(mouse){moveStart=mouse;original=selected;return}
            // Selected-state outside clicks must not replace the user's region.
            ignoredMouseDown=true;return
        }
        anchor=mouse;if hover?.contains(mouse) != true {owner?.snap(mouse,view:self)};changed()
    }
    override func mouseDragged(with event:NSEvent){
        guard !ignoredMouseDown else{return};let point=ScreenshotSelectionGeometry.clamped(convert(event.locationInWindow,from:nil),to:bounds);mouse=point
        let ratio=event.modifierFlags.contains(.shift) ? CGFloat(1):aspectRatio
        if let handle=resizeHandle,let original {selection=ScreenshotSelectionGeometry.resized(original,handle:handle,to:point,ratio:ratio,bounds:bounds);selectionWindowId=nil}
        else if let moveStart,let original {selection=NativeScreenshotSelector.moved(original,by:CGPoint(x:point.x-moveStart.x,y:point.y-moveStart.y),bounds:bounds);selectionWindowId=nil}
        else if let anchor {
            if space,let start=spaceStart,let rect=spaceRect,let originalAnchor=spaceAnchor {
                let moved=NativeScreenshotSelector.moved(rect,by:CGPoint(x:point.x-start.x,y:point.y-start.y),bounds:bounds);selection=moved;self.anchor=CGPoint(x:originalAnchor.x+moved.minX-rect.minX,y:originalAnchor.y+moved.minY-rect.minY)
            } else {selection=ScreenshotSelectionGeometry.drawn(from:anchor,to:point,ratio:ratio,bounds:bounds)}
            selectionWindowId=nil
        };changed()
    }
    override func mouseUp(with event:NSEvent){
        guard !ignoredMouseDown else{ignoredMouseDown=false;return};mouse=ScreenshotSelectionGeometry.clamped(convert(event.locationInWindow,from:nil),to:bounds)
        if let anchor,hypot(mouse.x-anchor.x,mouse.y-anchor.y)<3,selection==nil {selection=hover;selectionWindowId=hoverWindowId}
        if let selection,(selection.width<2 || selection.height<2){self.selection=original;selectionWindowId=nil}
        anchor=nil;moveStart=nil;original=nil;resizeHandle=nil;spaceRect=nil;spaceStart=nil;spaceAnchor=nil;space=false;changed()
    }
    override func keyDown(with event:NSEvent){
        switch event.keyCode {
        case 53:owner?.finish(nil)
        case 36,76:confirm(action:nil)
        case 48:owner?.snapping.toggle();hover=nil;hoverWindowId=nil;owner?.snap(mouse,view:self);changed()
        case 3:if event.modifierFlags.intersection([.command,.control,.option]).isEmpty{selectFullscreen()}
        case 49:
            if !space {space=true;if anchor != nil,let selection{spaceStart=mouse;spaceRect=selection;spaceAnchor=anchor}else if let selection{moveStart=mouse;original=selection}}
        default:break
        }
    }
    override func keyUp(with event:NSEvent){if event.keyCode==49,space{space=false;spaceStart=nil;spaceRect=nil;spaceAnchor=nil;if anchor==nil{moveStart=nil;original=nil}}}
    func confirm(action:String?){if let rect=selection ?? hover{owner?.selected(rect,screen:screen,id:displayId,windowId:selection==nil ? hoverWindowId:selectionWindowId,action:action,snapshot:snapshot,viewSize:bounds.size)}}
    func changeMode(_ mode:String){
        owner?.mode=mode;selection=nil;selectionWindowId=nil;anchor=nil;resizeHandle=nil
        if mode=="fullscreen"{selectFullscreen();return}
        owner?.snapping=mode=="window";hover=nil;hoverWindowId=nil;owner?.snap(mouse,view:self);window?.makeFirstResponder(self);changed()
    }
    func selectFullscreen(){selection=bounds;selectionWindowId=nil;hover=nil;hoverWindowId=nil;anchor=nil;changed()}
    func setAspect(_ ratio:CGFloat?){aspectRatio=ratio;if let rect=selection,let ratio{selection=ScreenshotSelectionGeometry.aspectFitted(rect,width:rect.width,height:rect.width/ratio,ratio:ratio,bounds:bounds);selectionWindowId=nil};window?.makeFirstResponder(self);changed()}
    func applySize(width:CGFloat,height:CGFloat,changedWidth:Bool){guard let rect=selection,width.isFinite,height.isFinite,width>0,height>0 else{changed();return};var w=width,h=height;if let ratio=aspectRatio{if changedWidth{h=w/ratio}else{w=h*ratio}};selection=ScreenshotSelectionGeometry.aspectFitted(rect,width:w,height:h,ratio:aspectRatio,bounds:bounds);selectionWindowId=nil;window?.makeFirstResponder(self);changed()}
    func applyPixelSize(width:CGFloat,height:CGFloat){guard selection != nil else{return};aspectRatio=nil;sizeControls.aspect.selectItem(at:0);let ratio=width/height;let rect=selection!;selection=ScreenshotSelectionGeometry.aspectFitted(rect,width:width/pixelScale,height:height/pixelScale,ratio:ratio,bounds:bounds);selectionWindowId=nil;window?.makeFirstResponder(self);changed()}
    override func draw(_ dirtyRect:NSRect){
        if let snapshot{NSImage(cgImage:snapshot,size:bounds.size).draw(in:bounds)}else{NSColor.clear.setFill();bounds.fill()}
        let candidate=selection ?? hover,hole=candidate.flatMap{$0.width>=2 && $0.height>=2 && !$0.isNull ? $0:nil}
        let shade=NSBezierPath(rect:bounds);if let hole{shade.appendRect(hole)};shade.windingRule = .evenOdd;NSColor.black.withAlphaComponent(0.48).setFill();shade.fill()
        if let hole {
            NSColor.white.setStroke();let border=NSBezierPath(rect:hole.insetBy(dx:0.5,dy:0.5));border.lineWidth=1;border.stroke()
            if selection != nil {for h in ScreenshotResizeHandle.allCases{let p=h.point(in:hole),r=CGRect(x:p.x-4,y:p.y-4,width:8,height:8);NSColor.white.setFill();NSBezierPath(roundedRect:r,xRadius:1.5,yRadius:1.5).fill();NSColor.controlAccentColor.setStroke();NSBezierPath(roundedRect:r,xRadius:1.5,yRadius:1.5).stroke()}}
            if selection==nil {drawLabel("点击窗口 · 拖拽自定义区域 · F 全屏",at:CGPoint(x:max(12,(bounds.width-320)/2),y:108))}
            let id=selection==nil ? hoverWindowId:selectionWindowId
            let measured=id.flatMap{value in owner?.candidates.first{$0.windowId==value}?.rect} ?? hole
            let scale=id.flatMap{owner?.windowScales[$0]} ?? pixelScale
            let text="\(Int(measured.width)) × \(Int(measured.height)) pt · \(Int((measured.width*scale).rounded())) × \(Int((measured.height*scale).rounded())) px"
            if selection==nil{drawLabel(text,at:CGPoint(x:min(max(8,hole.minX),max(8,bounds.width-350)),y:min(bounds.height-32,hole.maxY+8)))}
        } else {drawLabel("点击窗口 · 拖拽自定义区域 · F 全屏",at:CGPoint(x:max(12,(bounds.width-320)/2),y:108))}
        drawLabel("Space 移动 · ⇧ 正方形 · Tab 吸附 \(owner?.snapping==true ? "开":"关") · ↩ 快速截图 · Esc 取消",at:CGPoint(x:max(12,(bounds.width-530)/2),y:bounds.height-38))
        if pointerInside,bounds.contains(mouse),selection==nil,owner?.magnifier==true,let snapshot{drawMagnifier(snapshot)}
    }
    private func drawLabel(_ text:String,at point:CGPoint){let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.white];let size=(text as NSString).size(withAttributes:attributes);let box=CGRect(x:point.x-8,y:point.y-5,width:size.width+16,height:size.height+10);NSColor.black.withAlphaComponent(0.82).setFill();NSBezierPath(roundedRect:box,xRadius:7,yRadius:7).fill();(text as NSString).draw(at:point,withAttributes:attributes)}
    private func drawMagnifier(_ image:CGImage){let side:CGFloat=124,zoom:CGFloat=3,scale=CGFloat(image.width)/bounds.width,sample=side/zoom*scale;let crop=CGRect(x:mouse.x*scale-sample/2,y:(bounds.height-mouse.y)*scale-sample/2,width:sample,height:sample).intersection(CGRect(x:0,y:0,width:image.width,height:image.height));guard crop.width>0,crop.height>0,let part=image.cropping(to:crop.integral)else{return};let rect=CGRect(x:min(max(8,mouse.x+24),bounds.width-side-8),y:min(max(8,mouse.y+24),bounds.height-side-8),width:side,height:side);NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12).addClip();NSGraphicsContext.current?.imageInterpolation = .none;NSImage(cgImage:part,size:rect.size).draw(in:rect);NSGraphicsContext.restoreGraphicsState();NSColor.white.setStroke();let border=NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12);border.lineWidth=2;border.stroke();let cross=NSBezierPath();cross.move(to:CGPoint(x:rect.midX-10,y:rect.midY));cross.line(to:CGPoint(x:rect.midX+10,y:rect.midY));cross.move(to:CGPoint(x:rect.midX,y:rect.midY-10));cross.line(to:CGPoint(x:rect.midX,y:rect.midY+10));NSColor.systemRed.setStroke();cross.lineWidth=1;cross.stroke()}
}
