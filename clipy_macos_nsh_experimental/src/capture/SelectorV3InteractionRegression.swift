import AppKit
import Foundation
struct BridgeFailure:Error {let code:String;let message:String}
@main struct SelectorV3Regression {
 @MainActor static func main()throws {
  _=NSApplication.shared
  guard let screen=NSScreen.main else{fatalError("screen metadata unavailable")}
  let bounds=CGRect(x:0,y:0,width:1200,height:800)
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:800,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  let previousContext=NSGraphicsContext.current;NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
  NSColor(calibratedRed:0.2,green:0.32,blue:0.52,alpha:1).setFill();bounds.fill()
  NSColor(calibratedWhite:0.97,alpha:1).setFill();NSBezierPath(roundedRect:CGRect(x:80,y:95,width:1040,height:620),xRadius:12,yRadius:12).fill()
  NSColor(calibratedWhite:0.9,alpha:1).setFill();CGRect(x:80,y:665,width:1040,height:50).fill()
  ("fixture.example / overview" as NSString).draw(at:CGPoint(x:420,y:680),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.darkGray])
  for (i,title) in ["Devices 1,024","Success 99.8%","Latency 120ms"].enumerated(){NSColor.white.setFill();NSBezierPath(roundedRect:CGRect(x:280+i*250,y:510,width:230,height:120),xRadius:10,yRadius:10).fill();(title as NSString).draw(at:CGPoint(x:300+i*250,y:560),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.semibold),.foregroundColor:NSColor.darkGray])}
  for i in 0..<7{NSColor(calibratedWhite:i%2==0 ? 0.91:0.95,alpha:1).setFill();CGRect(x:280,y:410-i*38,width:760,height:34).fill()}
  NSGraphicsContext.restoreGraphicsState();NSGraphicsContext.current=previousContext
  let encodedFixture=bitmap.representation(using:.png,properties:[:])!
  let immutableFixture=NSBitmapImageRep(data:encodedFixture)!.cgImage!
  let owner=ScreenshotSelectionOwner(mode:"region",snapping:true,magnifier:false);owner.restoreFocus=false
  let canvas=ScreenshotSelectionCanvas(frame:bounds,screen:screen,displayId:0,snapshot:immutableFixture,owner:owner)
  let panel=ScreenshotSelectionPanel(contentRect:bounds,styleMask:[.borderless],backing:.buffered,defer:false);panel.isReleasedWhenClosed=false;panel.contentView=canvas
  func mouse(_ type:NSEvent.EventType,_ point:CGPoint,flags:NSEvent.ModifierFlags=[])->NSEvent{NSEvent.mouseEvent(with:type,location:point,modifierFlags:flags,timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!}
  func key(_ code:UInt16)->NSEvent{NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
  guard let frozen=NativeScreenshotSelector.frozenCrop(bitmap.cgImage!,localRect:CGRect(x:100,y:200,width:300,height:100),viewSize:bounds.size),frozen.width==300,frozen.height==100 else{fatalError("frozen crop point/pixel geometry")}
  assert(NativeScreenshotSelector.frozenCrop(bitmap.cgImage!,localRect:CGRect(x:2000,y:2000,width:20,height:20),viewSize:bounds.size)==nil)
  let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CLIPY_SELECTOR_FIXTURE_DIR"] ?? "/tmp/clipy-selector-v3-fixtures",isDirectory:true);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  func save(_ name:String)throws{
    canvas.layoutSubtreeIfNeeded();canvas.displayIfNeeded()
    let rep=canvas.bitmapImageRepForCachingDisplay(in:bounds)!;canvas.cacheDisplay(in:bounds,to:rep)
    guard let data=rep.representation(using:.png,properties:[:])else{fatalError("PNG fixture")};try data.write(to:output.appendingPathComponent(name))
  }
  canvas.hover=CGRect(x:280,y:244,width:760,height:386);try save("idle.png")
  canvas.selection=CGRect(x:290,y:300,width:760,height:220);canvas.changed();try save("selected.png")
  let saved=canvas.selection!
  canvas.selection=nil;canvas.hover=CGRect(x:320,y:330,width:180,height:50);canvas.hoverWindowId=nil
  canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:350,y:350)));canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:350,y:350)))
  assert(canvas.selection==CGRect(x:320,y:330,width:180,height:50) && canvas.selectionWindowId==nil,"click discarded AX element snap")
  canvas.selection=saved;canvas.changed()
  canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:40,y:150)));canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:140,y:180)));canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:140,y:180)));assert(canvas.selection==saved,"outside click replaced selected region")
  for handle in ScreenshotResizeHandle.allCases {
    let p=handle.point(in:saved);assert(ScreenshotSelectionGeometry.handle(at:p,rect:saved)==handle)
    let result=ScreenshotSelectionGeometry.resized(saved,handle:handle,to:CGPoint(x:p.x+(handle.axes.0<0.5 ? -20:20),y:p.y+(handle.axes.1<0.5 ? -20:20)),ratio:nil,bounds:bounds)
    assert(bounds.contains(result) && result.width>0 && result.height>0)
  }
  canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:saved.maxX,y:saved.maxY)));canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:saved.maxX+40,y:saved.maxY+40)));canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:saved.maxX+40,y:saved.maxY+40)));assert(canvas.selection!.width==800 && canvas.selection!.height==260,"handle not wired to canvas")
  canvas.setAspect(1);assert(abs(canvas.selection!.width/canvas.selection!.height-1)<0.001,"aspect clamp lost ratio")
  canvas.applySize(width:400,height:100,changedWidth:true);assert(canvas.selection!.width==400 && canvas.selection!.height==400)
  canvas.applyPixelSize(width:1280,height:720);assert(abs(canvas.selection!.width/canvas.selection!.height-16/9)<0.001)
  canvas.selection=nil;canvas.anchor=nil
  canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:200,y:200)));canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:400,y:350)));let drawn=canvas.selection!;canvas.keyDown(with:key(49));canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:430,y:370)));assert(canvas.selection!.size==drawn.size && canvas.selection!.origin==CGPoint(x:230,y:220),"Space must move without resizing")
  let up=NSEvent.keyEvent(with:.keyUp,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!;canvas.keyUp(with:up);canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:450,y:400)));assert(canvas.selection==CGRect(x:230,y:220,width:220,height:180),"resize after Space jumped")
  canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:450,y:400)))
  canvas.keyDown(with:key(3));assert(canvas.selection==bounds,"F fullscreen not wired")
  let allButtons=canvas.actionControls.subviews.flatMap{$0.subviews}.compactMap{$0 as? NSButton}
  assert(Set(allButtons.compactMap{$0.identifier?.rawValue})==Set(["annotate","copy","save","pin","editor","ocr","translate","scroll","recording","share","cancel"]),"selected action strip missing controls")
  for action in ["annotate","copy","save","pin","editor","ocr","translate","scroll","recording","share"] {
    let testOwner=ScreenshotSelectionOwner(mode:"region",snapping:false,magnifier:false);testOwner.restoreFocus=false;canvas.owner=testOwner;canvas.selection=saved
    let button=allButtons.first{$0.identifier?.rawValue==action}!;canvas.actionControls.pressed(button)
    assert(testOwner.completed && testOwner.result?.action==action,"action result not returned")
  }
  let quick=ScreenshotSelectionOwner(mode:"region",snapping:false,magnifier:false);quick.restoreFocus=false;canvas.owner=quick;canvas.selection=saved;canvas.keyDown(with:key(36));assert(quick.result?.frozenImage != nil,"region confirmation lost frozen source");assert(quick.completed && quick.result?.action==nil,"Enter must preserve default quick action")
  let cancel=ScreenshotSelectionOwner(mode:"region",snapping:false,magnifier:false);cancel.restoreFocus=false;canvas.owner=cancel;canvas.keyDown(with:key(53));assert(cancel.completed && cancel.result==nil)
  let appendOwner=ScreenshotSelectionOwner(mode:"region",snapping:false,magnifier:false,selectionOnly:true);appendOwner.restoreFocus=false
  let appendCanvas=ScreenshotSelectionCanvas(frame:bounds,screen:screen,displayId:canvas.displayId,snapshot:bitmap.cgImage,owner:appendOwner);appendCanvas.selection=saved
  let appendButtons=appendCanvas.actionControls.subviews.flatMap{$0.subviews}.compactMap{$0 as? NSButton}
  assert(Set(appendButtons.compactMap{$0.identifier?.rawValue})==Set(["append","cancel"]),"selection-only must not expose unrelated capture actions")
  let idleButtons=appendCanvas.idleControls.subviews.flatMap{$0.subviews}.compactMap{$0 as? NSButton}
  assert(Set(idleButtons.compactMap{$0.identifier?.rawValue})==Set(["region","window","fullscreen","cancel"]))
  appendCanvas.actionControls.pressed(appendButtons.first{$0.identifier?.rawValue=="append"}!)
  assert(appendOwner.completed && appendOwner.result?.action=="append")
  panel.contentView=nil;panel.close()
  print("PASS: selected outside-ignore, 8 handles, ratio/size/pixel presets, Space move/resume, F fullscreen, 11 real action controls, selection-only append, Enter/Esc; synthetic-only fixtures saved")
 }
}
