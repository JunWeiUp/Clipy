import AppKit
import Foundation

@MainActor final class ShareService:NSObject,@preconcurrency NSSharingServicePickerDelegate,NSSharingServiceDelegate {
    static var active:[String:ShareService] = [:]
    let id = UUID().uuidString
    let directory:URL
    let file:URL
    let anchor:NSPanel
    var picker:NSSharingServicePicker?
    init(path:String,root:URL) throws {
        let source = URL(fileURLWithPath:path),metadata = try source.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard metadata.isRegularFile == true,(metadata.fileSize ?? Int.max) <= 1024*1024*1024 else { throw BridgeFailure(code:"INVALID_SHARE",message:"请选择不超过 1 GiB 的文件") }
        directory = root.appendingPathComponent("share-drafts").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);file = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at:source,to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let point = NSEvent.mouseLocation;anchor = NSPanel(contentRect:CGRect(x:point.x,y:point.y,width:2,height:2),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init();anchor.isOpaque = false;anchor.backgroundColor = .clear;anchor.level = .floating;anchor.isReleasedWhenClosed = false
    }
    static func open(path:String,root:URL) throws -> [String:Any] {
        guard active.count < 8 else { throw BridgeFailure(code:"BUSY",message:"分享窗口过多，请先关闭") };let session = try ShareService(path:path,root:root);active[session.id] = session
        let picker = NSSharingServicePicker(items:[session.file]);picker.delegate = session;session.picker = picker;NSApp.activate(ignoringOtherApps:true);session.anchor.orderFrontRegardless()
        let view = session.anchor.contentView!;picker.show(relativeTo:view.bounds,of:view,preferredEdge:.minY);return ["presented":true,"id":session.id]
    }
    func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,didChoose service:NSSharingService?) { if service == nil { close() } }
    func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,delegateFor sharingService:NSSharingService) -> NSSharingServiceDelegate? { self }
    func sharingService(_ sharingService:NSSharingService,didShareItems items:[Any]) { BridgeOutput.write(["event":"image.share.finished","payload":["id":id,"shared":true]]);close() }
    func sharingService(_ sharingService:NSSharingService,didFailToShareItems items:[Any],error:Error) { BridgeOutput.write(["event":"image.share.finished","payload":["id":id,"shared":false]]);close() }
    func close() { anchor.close();picker = nil;try? FileManager.default.removeItem(at:directory);Self.active.removeValue(forKey:id) }
    static func closeAll() { for item in Array(active.values) { item.close() } }
}
