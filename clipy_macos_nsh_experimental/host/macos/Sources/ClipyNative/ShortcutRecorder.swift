import AppKit

@MainActor final class ShortcutRecorder:NSObject,NSWindowDelegate {
    static var active:ShortcutRecorder?
    var panel:RecorderPanel!
    var result:CheckedContinuation<[String:Any],Never>?
    var previous:NSRunningApplication?
    static func record() async throws -> [String:Any] {
        guard active == nil else {throw BridgeFailure(code:"BUSY",message:"快捷键录入窗口已打开")}
        let recorder=ShortcutRecorder();active=recorder
        return await withCheckedContinuation { continuation in
            recorder.result=continuation;recorder.previous=NSWorkspace.shared.frontmostApplication
            let panel=RecorderPanel(contentRect:NSRect(x:0,y:0,width:400,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            recorder.panel=panel;panel.owner=recorder;panel.title="录入快捷键";panel.delegate=recorder;panel.isReleasedWhenClosed=false
            let label=NSTextField(wrappingLabelWithString:"按下新的快捷键\n请包含 ⌘、⌃ 或 ⌥，按 Esc 取消。")
            label.alignment = .center;label.font=NSFont.systemFont(ofSize:15);label.frame=NSRect(x:20,y:76,width:360,height:70)
            panel.contentView?.addSubview(label)
            let clear=NSButton(title:"清除快捷键",target:recorder,action:#selector(clear));clear.frame=NSRect(x:28,y:24,width:150,height:32);panel.contentView?.addSubview(clear)
            let cancel=NSButton(title:"取消",target:recorder,action:#selector(cancel));cancel.frame=NSRect(x:254,y:24,width:110,height:32);panel.contentView?.addSubview(cancel)
            panel.center();NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(panel)
        }
    }
    func finish(_ value:[String:Any]) {guard let result else{return};self.result=nil;panel.orderOut(nil);panel.delegate=nil;panel.close();Self.active=nil;result.resume(returning:value);previous?.activate(options:.activateIgnoringOtherApps)}
    @objc func clear(){finish(["shortcut":""])}
    @objc func cancel(){finish(["cancelled":true])}
    func windowWillClose(_ notification:Notification){finish(["cancelled":true])}
    func capture(_ event:NSEvent) {
        if event.keyCode==53 {cancel();return}
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command,.control,.option]).isEmpty else {NSSound.beep();return}
        let special:[UInt16:String]=[36:"enter",48:"tab",49:"space",51:"backspace",53:"escape",117:"delete",123:"left",124:"right",125:"down",126:"up",115:"home",119:"end",116:"pageup",121:"pagedown",122:"f1",120:"f2",99:"f3",118:"f4",96:"f5",97:"f6",98:"f7",100:"f8",101:"f9",109:"f10",103:"f11",111:"f12"]
        let key=special[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard key.count==1 || special[event.keyCode] != nil else {NSSound.beep();return}
        var parts=[String]();if flags.contains(.control){parts.append("ctrl")};if flags.contains(.option){parts.append("alt")};if flags.contains(.command){parts.append("mod")};if flags.contains(.shift){parts.append("shift")};parts.append(key=="=" ? "plus":key=="-" ? "minus":key)
        let shortcut=parts.joined(separator:"+")
        guard !["mod+q","mod+h","mod+m","ctrl+mod+f"].contains(shortcut) else {NSSound.beep();return}
        finish(["shortcut":shortcut])
    }
}
@MainActor final class RecorderPanel:NSPanel {
    weak var owner:ShortcutRecorder?
    override var canBecomeKey:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    override func keyDown(with event:NSEvent){owner?.capture(event)}
    override func performKeyEquivalent(with event:NSEvent)->Bool{owner?.capture(event);return true}
}
