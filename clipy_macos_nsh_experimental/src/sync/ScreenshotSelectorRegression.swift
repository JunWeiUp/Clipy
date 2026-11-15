import Foundation
import AppKit
struct BridgeFailure:Error{let code:String;let message:String}
@main struct SelectorRegression{
 @MainActor static func main()throws{
  let primary=CGRect(x:0,y:0,width:1512,height:982),local=CGRect(x:100,y:200,width:300,height:150);let cg=NativeScreenshotSelector.cgRect(local,screen:primary,mainTop:982);guard cg==CGRect(x:100,y:632,width:300,height:150),NativeScreenshotSelector.appRect(cg,screen:primary,mainTop:982)==local else{fatalError("primary coordinate conversion")}
  let left=CGRect(x:-1920,y:100,width:1920,height:1080),second=CGRect(x:10,y:20,width:500,height:400);let mapped=NativeScreenshotSelector.cgRect(second,screen:left,mainTop:982);guard mapped==CGRect(x:-1910,y:462,width:500,height:400),NativeScreenshotSelector.appRect(mapped,screen:left,mainTop:982)==second else{fatalError("negative/mixed monitor conversion")}
  // A clicked window spanning two displays keeps its full global rect and ID.
  let crossWindow=CGRect(x:1400,y:-100,width:900,height:700),visibleLocal=CGRect(x:1400,y:382,width:112,height:500)
  let clicked=NativeScreenshotSelector.confirmed(local:visibleLocal,screen:primary,mainTop:982,displayId:11,windowId:77,windowRect:crossWindow)
  guard clicked.windowId==77,clicked.rect==crossWindow,clicked.rect.width==900 else{fatalError("cross-display window was clipped")}
  let draggedWindowMode=NativeScreenshotSelector.confirmed(local:visibleLocal,screen:primary,mainTop:982,displayId:11,windowId:nil,windowRect:crossWindow)
  guard draggedWindowMode.windowId==nil,draggedWindowMode.rect==NativeScreenshotSelector.cgRect(visibleLocal,screen:primary,mainTop:982)else{fatalError("manual region kept a window ID")}
  let nativeWindow=try NativeScreenshotSelector.pixelSize(contentRect:crossWindow,pointPixelScale:2)
  guard nativeWindow.width==1800,nativeWindow.height==1400 else{fatalError("window filter native pixel scale")}
  let fractional=try NativeScreenshotSelector.pixelSize(contentRect:CGRect(x:-300,y:0,width:901,height:701),pointPixelScale:1.5)
  guard fractional.width==1352,fractional.height==1052 else{fatalError("fractional filter scale rounding")}
  do{_=try NativeScreenshotSelector.pixelSize(contentRect:crossWindow,pointPixelScale:0);fatalError("invalid scale accepted")}catch{}
  let bounds=CGRect(x:0,y:0,width:200,height:100);let square=NativeScreenshotSelector.dragged(from:CGPoint(x:20,y:20),to:CGPoint(x:90,y:40),square:true,bounds:bounds);guard square.width==70,square.height==70 else{fatalError("shift square")};let clipped=NativeScreenshotSelector.dragged(from:CGPoint(x:190,y:90),to:CGPoint(x:400,y:400),square:true,bounds:bounds);guard clipped.width==10,clipped.height==10,bounds.contains(clipped)else{fatalError("edge square clipping")};let reverse=NativeScreenshotSelector.dragged(from:CGPoint(x:150,y:70),to:CGPoint(x:40,y:10),square:false,bounds:bounds);guard reverse==CGRect(x:40,y:10,width:110,height:60)else{fatalError("reverse drag")};let moved=NativeScreenshotSelector.moved(CGRect(x:20,y:20,width:60,height:40),by:CGPoint(x:1000,y:-1000),bounds:bounds);guard moved==CGRect(x:140,y:0,width:60,height:40)else{fatalError("space move clamp")}
  _=NSApplication.shared;guard let screen=NSScreen.main,let context=CGContext(data:nil,width:400,height:300,bitsPerComponent:8,bytesPerRow:1600,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{fatalError("fixture context")};context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:400,height:300));let owner=ScreenshotSelectionOwner(mode:"region",snapping:false,magnifier:false);let canvas=ScreenshotSelectionCanvas(frame:CGRect(x:0,y:0,width:400,height:300),screen:screen,displayId:0,snapshot:context.makeImage(),owner:owner);let panel=ScreenshotSelectionPanel(contentRect:canvas.bounds,styleMask:[.borderless],backing:.buffered,defer:false);panel.isReleasedWhenClosed=false;panel.contentView=canvas;canvas.selection=CGRect(x:50,y:50,width:100,height:200);guard let bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)else{fatalError("fixture bitmap")};canvas.cacheDisplay(in:canvas.bounds,to:bitmap);let scale=Double(bitmap.pixelsWide)/400;guard let inside=bitmap.colorAt(x:Int(100*scale),y:Int(150*scale))?.usingColorSpace(.deviceRGB),let outside=bitmap.colorAt(x:Int(300*scale),y:Int(150*scale))?.usingColorSpace(.deviceRGB),inside.redComponent>0.95,outside.redComponent<0.8 else{fatalError("selection shade/hole pixels")}
  let tab=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48)!;canvas.keyDown(with:tab);guard owner.snapping else{fatalError("tab did not toggle snap")}
  let clickedOwner=ScreenshotSelectionOwner(mode:"window",snapping:true,magnifier:false)
  let windowLocal=CGRect(x:50,y:50,width:500,height:200),windowGlobal=NativeScreenshotSelector.cgRect(windowLocal,screen:screen.frame,mainTop:clickedOwner.mainTop)
  clickedOwner.candidates=[ScreenshotSelectionOwner.WindowCandidate(rect:windowGlobal,pid:123456,windowId:777)];canvas.owner=clickedOwner;canvas.selection=nil;canvas.hover=nil
  func mouse(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent{NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!}
  canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:80,y:100)));canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:80,y:100)))
  guard canvas.selectionWindowId==777,canvas.selection?.width==350 else{fatalError("clicked candidate lost window ID")}
  canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:80,y:100)));canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:90,y:110)));canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:90,y:110)))
  guard canvas.selectionWindowId==nil else{fatalError("manual movement kept whole-window ID")}
  panel.contentView=nil;panel.close();print("PASS: native canvas fixture selected-area pixels stay undimmed, outside shaded, Tab state toggles; fixture only")
  print("PASS: clicked window ID preserves full cross-display bounds, manual regions have no ID, filter native/fractional pixel dimensions and invalid-scale rejection")
  print("PASS: screenshot CG/AppKit multi-monitor roundtrip, Retina point geometry, Shift square including edge clamp, reverse drag and Space movement bounds; no desktop pixels exported")
 }
}
