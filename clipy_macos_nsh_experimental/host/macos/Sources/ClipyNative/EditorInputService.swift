import AppKit
import ApplicationServices

/// Pure bounded sample gate, separate from event-monitor ownership for deterministic testing.
struct EditorPressureFilter {
    private(set) var active=false
    private var lastEmission:TimeInterval?
    mutating func configure(enabled:Bool,visible:Bool){let next=enabled&&visible;if next != active{lastEmission=nil};active=next}
    mutating func stop(){active=false;lastEmission=nil}
    mutating func sample(pressure:Double,tilt:CGPoint,screenPoint:CGPoint,timestamp:TimeInterval)->[String:Any]?{
        guard active,pressure.isFinite,tilt.x.isFinite,tilt.y.isFinite,screenPoint.x.isFinite,screenPoint.y.isFinite,timestamp.isFinite,abs(screenPoint.x)<=10_000_000,abs(screenPoint.y)<=10_000_000 else{return nil}
        if let lastEmission,timestamp-lastEmission<1.0/60.0{return nil};lastEmission=timestamp
        return ["pressure":min(1,max(0,pressure)),"tilt":["x":min(1,max(-1,tilt.x)),"y":min(1,max(-1,tilt.y))],"screenPoint":["x":screenPoint.x,"y":screenPoint.y],"coordinateSpace":"cg-global-points","timestamp":timestamp]
    }
}

/// Watches stylus/Force Touch only while the editor is visible and pressure is enabled.
/// Never installs a keyboard event mask or reads NSEvent.characters.
@MainActor final class EditorInputService {
    private let emit:(String,[String:Any])->Void
    private var globalMonitor:Any?
    private var localMonitor:Any?
    private var filter=EditorPressureFilter()
    init(emit:@escaping(String,[String:Any])->Void){self.emit=emit}
    func invoke(_ method:String,_ params:[String:Any])throws->Any{
        switch method{
        case "editor.watchPressure":return try watch(enabled:params["enabled"] as? Bool ?? false,visible:params["visible"] as? Bool ?? false)
        case "editor.stopPressure":close();return status()
        case "editor.pressureStatus":return status()
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"未知编辑器输入接口")
        }
    }
    func watch(enabled:Bool,visible:Bool)throws->[String:Any]{
        guard enabled,visible else{close();return status()};guard globalMonitor==nil,localMonitor==nil else{return status()}
        // Some tablets attach their pressure data to a mouse-drag event with tabletPoint subtype.
        // Such mouse events are discarded without reading coordinates unless that subtype matches.
        let mask:NSEvent.EventTypeMask=[.tabletPoint,.pressure,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:mask){[weak self]event in MainActor.assumeIsolated{self?.receive(event)};return event}
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:mask){[weak self]event in MainActor.assumeIsolated{self?.receive(event)}}
        guard localMonitor != nil,globalMonitor != nil else{close();throw BridgeFailure(code:"PERMISSION_DENIED",message:"无法监听压感事件，请检查输入监控或辅助功能权限；未启动后台监听")}
        filter.configure(enabled:true,visible:true);return status()
    }
    private func receive(_ event:NSEvent){
        let tablet=event.type == .tabletPoint||event.subtype == .tabletPoint
        guard tablet||event.type == .pressure else{return}
        let point:CGPoint
        if let cg=event.cgEvent{point=cg.location}
        else if let window=event.window{let location=window.convertPoint(toScreen:event.locationInWindow);point=CGPoint(x:location.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-location.y)}
        else{let location=NSEvent.mouseLocation;point=CGPoint(x:location.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-location.y)}
        let tilt=tablet ? event.tilt:.zero
        if let value=filter.sample(pressure:Double(event.pressure),tilt:tilt,screenPoint:point,timestamp:event.timestamp){emit("editor.pressure",value)}
    }
    func status()->[String:Any]{["active":filter.active,"editorOnly":true,"maximumHz":60,"inputPermission":CGPreflightListenEventAccess(),"accessibility":AXIsProcessTrusted(),"hardwareValidated":false]}
    func close(){filter.stop();if let globalMonitor{NSEvent.removeMonitor(globalMonitor)};if let localMonitor{NSEvent.removeMonitor(localMonitor)};globalMonitor=nil;localMonitor=nil}
}
