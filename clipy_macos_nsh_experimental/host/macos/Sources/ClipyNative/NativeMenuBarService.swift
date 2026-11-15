import AppKit
import Foundation

/// The fixed Swift host owns this status item; TSX still owns the popup UI.
/// No status-item ordering or ControlCenter/global preference is changed here.
@MainActor final class NativeMenuBarService:NSObject {
    private var item:NSStatusItem?
    private let emit:(String,[String:Any])->Void
    private let root:URL
    init(root:URL,emit:@escaping(String,[String:Any])->Void) { self.root=root;self.emit = emit;super.init() }

    func invoke(_ method:String,_ params:[String:Any]) throws -> [String:Any] {
        switch method {
        case "menubar.install":install();return status()
        case "menubar.status":return status()
        case "menubar.remove":remove();return status()
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"未知菜单栏操作")
        }
    }
    private func install() {
        let status:NSStatusItem
        if let item { status = item }
        else {
            status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            status.autosaveName = "ClipyTSXMenuBar"
            item = status
        }
        if let button = status.button {
            let image = NSImage(systemSymbolName:"clipboard",accessibilityDescription:"Clipy TSX") ?? NSImage(systemSymbolName:"doc.on.clipboard",accessibilityDescription:"Clipy TSX")
            image?.isTemplate = true;image?.size = NSSize(width:18,height:18)
            button.image = image;button.title = "Clipy";button.imagePosition = .imageLeft
            button.font = NSFont.menuBarFont(ofSize:0)
            button.toolTip = "Clipy TSX";button.setAccessibilityLabel("Clipy TSX")
            button.target = self;button.action = #selector(clicked(_:))
            button.sendAction(on:.leftMouseUp)
        }
        status.isVisible = true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.writeStatus() }
    }
    private func writeStatus(){guard let data=try? JSONSerialization.data(withJSONObject:status(),options:[.sortedKeys])else{return};let url=root.appendingPathComponent("menubar-state.json");try? data.write(to:url,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    @objc private func clicked(_ sender:NSStatusBarButton) {
        guard let item,item.isVisible else { return }
        if let event = NSApp.currentEvent,event.modifierFlags.contains(.control) { return }
        writeStatus()
        emit("menubar.click",["bounds":bounds(item) as Any? ?? NSNull()])
    }
    private func bounds(_ item:NSStatusItem) -> [String:Any]? {
        guard let button = item.button,let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds,to:nil))
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return ["origin":["x":rect.minX,"y":mainTop-rect.maxY],"size":["width":rect.width,"height":rect.height]]
    }
    func status() -> [String:Any] {
        guard let item else { return ["installed":false,"visible":false,"imageLoaded":false,"bounds":NSNull()] }
        return ["installed":true,"visible":item.isVisible,"imageLoaded":item.button?.image != nil,"autosaveName":item.autosaveName as Any? ?? NSNull(),"bounds":bounds(item) as Any? ?? NSNull(),"windowNumber":item.button?.window?.windowNumber ?? -1,"windowFrame":item.button?.window.map { NSStringFromRect($0.frame) } ?? "nil","mainTop":NSScreen.screens.first?.frame.maxY ?? 0]
    }
    func remove() {
        guard let item else { return }
        item.button?.target = nil;item.button?.action = nil
        NSStatusBar.system.removeStatusItem(item);self.item = nil
    }
}
