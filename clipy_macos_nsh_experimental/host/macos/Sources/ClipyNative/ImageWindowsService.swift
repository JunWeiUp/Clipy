import AppKit
import Foundation
import ImageIO
import CoreImage

@MainActor final class ImageWindowsService: NSObject, NSWindowDelegate {
    static let shared = ImageWindowsService()
    static var translationProvider:((String,String)async throws->String)?
    static var translationProviderWithBackend:((String,String,String)async throws->String)?
    static var allowLegacyTranslationProviderForTesting=false
    static var cancelTranslation:(()->Void)?
    static var actionHandler:((String,String)->Void)?
    private static var english = false
    static func setLocale(_ language: String) { english = language.lowercased().hasPrefix("en") }
    static func localized(_ text: String) -> String {
        guard english else { return text }
        return ["文字与二维码识别":"Text & QR recognition","系统翻译":"System (on device)","模型翻译":"Model (external endpoint)","模型翻译仅在点击翻译后将原文发送到你配置的接口":"Model translation sends text to your configured endpoint only when you press Translate.","系统翻译在设备端处理，不会转用模型接口":"System translation runs on this device and never falls back to a model endpoint.","系统翻译需要macOS26，请明确选择模型翻译":"System translation requires macOS 26. Select Model explicitly if needed.","系统翻译服务暂不可用":"System translation is currently unavailable.","正在使用模型翻译…":"Translating with the selected model…","正在设备端翻译…":"Translating on this device…","简体中文":"Simplified Chinese","繁體中文":"Traditional Chinese","字符":"characters","保存":"Save","编辑":"Edit","贴图":"Pin","在编辑器中打开":"Open in editor","贴到屏幕":"Pin to screen","分享":"Share","向左旋转":"Rotate left","向右旋转":"Rotate right","水平翻转":"Flip horizontally","垂直翻转":"Flip vertically","显示应用副本":"Show application copy","删除缩略图":"Delete thumbnail","全部保存到文件夹…":"Save all to folder…","删除全部缩略图":"Delete all thumbnails","保存全部":"Save all","图片操作失败":"Image operation failed","图片操作暂不可用，请重新打开窗口":"Image action unavailable. Reopen the window.","无法读取图片":"Could not read image","无法变换图片":"Could not transform image","无法生成图片":"Could not encode image","词":"words", "复制":"Copy", "可修改识别结果后再复制":"Edit recognized text before copying", "二维码":"QR codes", "截图结果":"Capture result", "复制图片":"Copy image", "另存为…":"Save as…", "在 Finder 中显示":"Show in Finder", "关闭贴图":"Close pinned image","识别原文":"Recognized text","翻译为":"Translate to","翻译":"Translate","取消翻译":"Cancel translation","复制原文":"Copy original","复制译文":"Copy translation","打开链接":"Open link","搜索原文":"Search original","正在翻译…":"Translating…","翻译完成":"Translation complete","翻译已取消":"Translation cancelled","原文已修改，请重新翻译":"Text changed. Translate again.","目标语言已更改，请点击翻译":"Target changed. Press Translate.","翻译支持1–10000字，可修改或选择部分原文":"Translation supports 1–10,000 characters.","请先在API设置中配置翻译接口":"Configure a translation endpoint in API settings first.","翻译失败，请检查API设置后重试":"Translation failed. Check API settings and retry.","已复制":"Copied","复制失败":"Copy failed","无法打开链接":"Could not open link","请选择2000字以内的原文后搜索":"Select up to 2,000 characters to search."][text] ?? text
    }
    static func translationError(_ error:Error)->String{guard english else{return (error as? BridgeFailure)?.message ?? localized("翻译失败，请检查API设置后重试")};switch (error as? BridgeFailure)?.code{case "SYSTEM_TRANSLATION_UNAVAILABLE":return "On-device system translation requires macOS 26 or later. Select Model explicitly if needed.";case "LANGUAGE_NOT_INSTALLED":return "Download the source and target languages in System Settings > General > Language & Region > Translation Languages, then retry. Nothing was sent to a model endpoint.";case "UNSUPPORTED_SOURCE_LANGUAGE":return "Apple translation does not support this source language.";case "UNSUPPORTED_TARGET_LANGUAGE":return "Apple translation does not support this target language.";case "UNSUPPORTED_LANGUAGE_PAIR":return "Apple translation does not support this language pair.";case "SOURCE_LANGUAGE_UNIDENTIFIED":return "Could not identify the source language. Choose it explicitly.";case "NOTHING_TO_TRANSLATE":return "There is no text to translate.";case "SYSTEM_TRANSLATION_CANCELLED":return "System translation cancelled.";case "SYSTEM_TRANSLATION_FAILED":return "On-device translation failed. Check the installed language packs and retry.";case "INVALID_LANGUAGE":return "Choose a valid source and target language.";case "NOT_CONFIGURED":return "Configure a translation endpoint in API settings first.";case "INVALID_ARGUMENT":return "Enter a model and 1–10,000 characters, then retry.";case "HTTP_ERROR":return "The translation endpoint returned an HTTP error. Check the URL and API key.";case "INVALID_RESPONSE":return "The endpoint did not return a valid translation.";case "TOO_LARGE":return "The translation response exceeded the size limit.";default:return "Translation failed. Check API settings and retry."}}
    private var windows: [String: NSWindow] = [:]
    private var images: [String: String] = [:]
    private var thumbnailIds: [String] = []
    private var ownedDirectories: [String: URL] = [:]
    private var ocrControllers:[String:OCRResultController]=[:]

    static func open(kind: String, params: [String: Any]) throws -> [String: Any] {
        try shared.open(kind: kind, params: params)
    }
    private func open(kind: String, params: [String: Any]) throws -> [String: Any] {
        if kind=="ocr"{for old in Array(ocrControllers.keys){windows[old]?.close()}}
        if kind=="thumbnail",params["stack"] as? Bool==false{Self.closeThumbnails()}
        if kind=="thumbnail",thumbnailIds.count>=8,let oldest=thumbnailIds.first{windows[oldest]?.close()}
        let id = UUID().uuidString
        guard windows.count < 12 else { throw BridgeFailure(code: "WINDOW_LIMIT", message: "最多同时打开 12 个图片结果窗口") }
        if kind=="ocr" {
            let text=params["text"] as? String ?? "";guard text.utf8.count<=1024*1024 else{throw BridgeFailure(code:"TEXT_LIMIT",message:"识别结果过长")}
            let controller=OCRResultController(text:text,codes:params["codes"] as? [String] ?? [],translation:params["translation"] as? String ?? "",target:params["target"] as? String ?? "简体中文",backend:params["backend"] as? String)
            let window=NSWindow(contentRect:CGRect(x:0,y:0,width:720,height:700),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false);window.minSize=CGSize(width:600,height:controller.codes.isEmpty ? 530:650);window.title=Self.localized("文字与二维码识别");window.contentViewController=controller;window.identifier=NSUserInterfaceItemIdentifier(id);window.delegate=self;window.isReleasedWhenClosed=false;windows[id]=window;ocrControllers[id]=controller
            window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);if params["translate"] as? Bool==true{controller.startTranslation()};return ["id":id]
        }
        guard let originalPath = params["path"] as? String,
              let provider = CGImageSourceCreateWithURL(URL(fileURLWithPath: originalPath) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(provider, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 120000, height <= 120000, Int64(width) * Int64(height) <= 80_000_000 else { throw BridgeFailure(code: "INVALID_IMAGE", message: "无法读取图片或像素数超过上限") }
        let ownedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-tsx-image-window-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let extensionName = String(URL(fileURLWithPath: originalPath).pathExtension.prefix(12))
        let ownedPath = ownedDirectory.appendingPathComponent("image." + (extensionName.isEmpty ? "png" : extensionName))
        do { try FileManager.default.copyItem(atPath: originalPath, toPath: ownedPath.path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownedPath.path) }
        catch { try? FileManager.default.removeItem(at: ownedDirectory); throw error }
        guard let displaySource=CGImageSourceCreateWithURL(ownedPath as CFURL,nil),let thumbnail=CGImageSourceCreateThumbnailAtIndex(displaySource,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:kind=="thumbnail" ? 512:1280,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)else{try? FileManager.default.removeItem(at:ownedDirectory);throw BridgeFailure(code:"INVALID_IMAGE",message:"无法解码图片")};let image=NSImage(cgImage:thumbnail,size:CGSize(width:thumbnail.width,height:thumbnail.height))
        ownedDirectories[id] = ownedDirectory
        let path = ownedPath.path
        let requestedScale = params["scale"] as? Double ?? 1
        guard requestedScale.isFinite, requestedScale >= 0.5, requestedScale <= 2 else {try? FileManager.default.removeItem(at:ownedDirectory);ownedDirectories.removeValue(forKey:id);throw BridgeFailure(code:"INVALID_SCALE",message:"缩略图尺寸必须为 0.5–2 倍")}
        let targetWidth:CGFloat = kind == "thumbnail" ? 240 * requestedScale : 640
        let targetHeight:CGFloat = kind == "thumbnail" ? 180 * requestedScale : 480
        let scale = min(1, targetWidth / max(1, image.size.width), targetHeight / max(1, image.size.height))
        let size = NSSize(width: max(kind=="thumbnail" ? 112:80, image.size.width * scale), height: max(kind=="thumbnail" ? 72:60, image.size.height * scale))
        let panel = PinPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: kind == "thumbnail" ? [.borderless,.nonactivatingPanel] : [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = Self.localized("截图结果"); panel.level = .floating; panel.isMovableByWindowBackground = true; panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinnedImageView(frame: NSRect(origin: .zero, size: size)); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown; view.imagePath = path;view.isThumbnail = kind=="thumbnail";view.configureHoverActions()
        panel.contentView = view; panel.identifier = NSUserInterfaceItemIdentifier(id); panel.delegate = self; panel.isReleasedWhenClosed = false
        images[id] = path; windows[id] = panel
        if kind == "thumbnail", let screen = NSScreen.main {
            if params["stack"] as? Bool == false {for previous in Array(thumbnailIds){windows[previous]?.close()}}
            if thumbnailIds.count >= 8, let oldest = thumbnailIds.first { windows[oldest]?.close() }
            let offset = CGFloat(thumbnailIds.count) * 18
            thumbnailIds.append(id)
            let position=params["position"] as? String ?? "bottomRight",left=position.lowercased().contains("left"),top=position.lowercased().contains("top")
            let x=left ? screen.visibleFrame.minX+24+offset : screen.visibleFrame.maxX-size.width-24-offset
            let y=top ? screen.visibleFrame.maxY-size.height-24-offset : screen.visibleFrame.minY+24+offset
            panel.setFrameOrigin(NSPoint(x:x,y:y))
        } else { panel.center() }
        if kind=="thumbnail"{panel.orderFrontRegardless()}else{panel.makeKeyAndOrderFront(nil)};panel.makeFirstResponder(view)
        return ["id": id]
    }
    static func owns(path:String)->Bool{let url=URL(fileURLWithPath:path).standardizedFileURL;guard let attrs=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),attrs.isRegularFile==true,attrs.isSymbolicLink != true else{return false};let resolved=url.resolvingSymlinksInPath().path;return shared.images.values.contains{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path==resolved}||shared.ownedDirectories.values.contains{$0.appendingPathComponent("rendered.png").resolvingSymlinksInPath().path==resolved}}
    static func closeThumbnails(){for id in Array(shared.thumbnailIds){shared.windows[id]?.close()}}
    static func dispatch(_ action:String,path:String)throws{guard owns(path:path),let handler=actionHandler else{throw BridgeFailure(code:"ACTION_UNAVAILABLE",message:localized("图片操作暂不可用，请重新打开窗口"))};handler(action,path)}
    static func saveThumbnails(){let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false;panel.prompt=localized("保存全部");panel.begin{response in guard response == .OK,let directory=panel.url else{return};do{for id in Array(shared.thumbnailIds){if let view=shared.windows[id]?.contentView as? PinnedImageView{try view.save(to:directory.appendingPathComponent("Screenshot-"+UUID().uuidString+".png"))}}}catch{showError(error)}}}
    static func showError(_ error:Error){let alert=NSAlert();alert.messageText=localized("图片操作失败");alert.informativeText=(error as? BridgeFailure)?.message ?? error.localizedDescription;alert.runModal()}
    @objc private func copyOCR(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let window = windows[id], let scroll = window.contentView?.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView, let editor = scroll.documentView as? NSTextView else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(editor.string, forType: .string)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        ocrControllers.removeValue(forKey:id)?.close();windows.removeValue(forKey: id); images.removeValue(forKey: id); thumbnailIds.removeAll { $0 == id }; if let directory = ownedDirectories.removeValue(forKey: id) {if let view=window.contentView as? PinnedImageView{view.prepareForClose();if view.draggingActive{view.afterDragCleanup={try? FileManager.default.removeItem(at:directory)}}else{try? FileManager.default.removeItem(at:directory)}}else{try? FileManager.default.removeItem(at:directory)}}
    }
    static func closeAll() { for controller in shared.ocrControllers.values{controller.close()};shared.ocrControllers.removeAll();let list = Array(shared.windows.values); for window in list { window.close() }; shared.windows.removeAll(); shared.images.removeAll(); shared.thumbnailIds.removeAll(); for directory in shared.ownedDirectories.values { try? FileManager.default.removeItem(at: directory) }; shared.ownedDirectories.removeAll() }
}

@MainActor private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PinnedImageView:NSImageView,NSDraggingSource {
    var imagePath="",isThumbnail=false,draggingActive=false
    var afterDragCleanup:(()->Void)?
    private var current:CGImage?,modified=false,savePanel:NSSavePanel?,tracking:NSTrackingArea?,down:NSEvent?
    private let hover=NSVisualEffectView()
    override var acceptsFirstResponder:Bool{true}
    func configureHoverActions(){guard isThumbnail else{return};hover.material = .hudWindow;hover.blendingMode = .withinWindow;hover.state = .active;hover.wantsLayer=true;hover.layer?.cornerRadius=8;hover.alphaValue=0;addSubview(hover);for(index,item)in [("copy","复制","doc.on.doc"),("save","保存","square.and.arrow.down"),("edit","编辑","pencil"),("pin","贴图","pin")].enumerated(){let button=NSButton();button.title=ImageWindowsService.localized(item.1);button.toolTip=button.title;button.setAccessibilityLabel(button.title);button.image=NSImage(systemSymbolName:item.2,accessibilityDescription:button.title);button.imagePosition = .imageOnly;button.isBordered=false;button.identifier=NSUserInterfaceItemIdentifier(item.0);button.target=self;button.action=#selector(hoverAction(_:));button.frame=CGRect(x:index*26+2,y:2,width:24,height:24);hover.addSubview(button)};needsLayout=true;layoutSubtreeIfNeeded()}
    override func layout(){super.layout();hover.frame=CGRect(x:max(2,(bounds.width-108)/2),y:8,width:108,height:28)}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)};if isThumbnail{let next=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self);tracking=next;addTrackingArea(next)}}
    override func mouseEntered(with event:NSEvent){hover.alphaValue=1}
    override func mouseExited(with event:NSEvent){hover.alphaValue=0}
    override func mouseDown(with event:NSEvent){if isThumbnail{down=event;return};if event.clickCount==2{window?.close()}else{window?.performDrag(with:event)}}
    override func mouseDragged(with event:NSEvent){guard isThumbnail,!draggingActive,let down,hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 else{return};do{let path=try renderedPath();let item=NSDraggingItem(pasteboardWriter:URL(fileURLWithPath:path) as NSURL);item.setDraggingFrame(bounds,contents:image);draggingActive=true;hover.alphaValue=0;beginDraggingSession(with:[item],event:down,source:self)}catch{ImageWindowsService.showError(error)}}
    override func mouseUp(with event:NSEvent){if isThumbnail,!draggingActive,down != nil{perform("edit")};down=nil}
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation{.copy}
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation){draggingActive=false;down=nil;afterDragCleanup?();afterDragCleanup=nil}
    override func scrollWheel(with event:NSEvent){guard let window else{return};if event.modifierFlags.contains(.command){window.alphaValue=min(1,max(0.15,window.alphaValue-event.scrollingDeltaY/300));return};let factor=pow(1.01,-event.scrollingDeltaY);window.setContentSize(CGSize(width:min(2400,max(80,window.frame.width*factor)),height:min(1800,max(60,window.frame.height*factor))))}
    override func keyDown(with event:NSEvent){if event.keyCode==53{window?.close();return};if event.charactersIgnoringModifiers?.lowercased()=="r"{perform("right");return};if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers?.lowercased()=="c"{perform("copy");return};super.keyDown(with:event)}
    func currentImage()throws->CGImage{if let current{return current};guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:imagePath) as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil)else{throw BridgeFailure(code:"INVALID_IMAGE",message:ImageWindowsService.localized("无法读取图片"))};current=image;return image}
    func transformed(_ orientation:CGImagePropertyOrientation)throws{guard !draggingActive else{return};let image=CIImage(cgImage:try currentImage()).oriented(orientation);guard let result=CIContext(options:[.cacheIntermediates:false]).createCGImage(image,from:image.extent)else{throw BridgeFailure(code:"IMAGE_TRANSFORM",message:ImageWindowsService.localized("无法变换图片"))};current=result;modified=true;self.image=NSImage(cgImage:result,size:CGSize(width:result.width,height:result.height));if [.right,.left].contains(orientation),let window{let center=CGPoint(x:window.frame.midX,y:window.frame.midY),size=window.contentView?.bounds.size ?? bounds.size;window.setContentSize(CGSize(width:size.height,height:size.width));window.setFrameOrigin(CGPoint(x:center.x-window.frame.width/2,y:center.y-window.frame.height/2))}}
    func renderedPNG()throws->Data{guard let bytes=NSBitmapImageRep(cgImage:try currentImage()).representation(using:.png,properties:[:])else{throw BridgeFailure(code:"ENCODING",message:ImageWindowsService.localized("无法生成图片"))};return bytes}
    func renderedPath()throws->String{guard modified else{return imagePath};let url=URL(fileURLWithPath:imagePath).deletingLastPathComponent().appendingPathComponent("rendered.png");try save(to:url);return url.path}
    func copyImage(to board:NSPasteboard = .general)throws{let data=try renderedPNG();board.clearContents();guard board.setData(data,forType:.png)else{throw BridgeFailure(code:"CLIPBOARD",message:ImageWindowsService.localized("复制失败"))}}
    func save(to url:URL)throws{try renderedPNG().write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    func prepareForClose(){savePanel?.cancel(nil);savePanel=nil}
    @objc private func hoverAction(_ sender:NSButton){perform(sender.identifier?.rawValue ?? "")}
    @objc private func menuAction(_ sender:NSMenuItem){perform(sender.representedObject as? String ?? "")}
    func perform(_ action:String){do{switch action{case "copy":try copyImage();case "save":saveImage();case "left":try transformed(.left);case "right":try transformed(.right);case "flipH":try transformed(.upMirrored);case "flipV":try transformed(.downMirrored);case "close":window?.close();case "closeAll":ImageWindowsService.closeThumbnails();case "saveAll":ImageWindowsService.saveThumbnails();case "reveal":NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:try renderedPath())]);case "edit","ocr","share","pin":try ImageWindowsService.dispatch(action,path:renderedPath());default:break}}catch{ImageWindowsService.showError(error)}}
    private func saveImage(){guard savePanel==nil else{return};let panel=NSSavePanel();savePanel=panel;panel.nameFieldStringValue="Clipy.png";let completion:(NSApplication.ModalResponse)->Void={[weak self]response in guard let self else{return};self.savePanel=nil;guard response == .OK,let url=panel.url else{return};do{try self.save(to:url)}catch{ImageWindowsService.showError(error)}};if let window{panel.beginSheetModal(for:window,completionHandler:completion)}else{panel.begin(completionHandler:completion)}}
    override func menu(for event:NSEvent)->NSMenu?{let menu=NSMenu();var items=[("copy","复制图片"),("save","另存为…"),("edit","在编辑器中打开"),("pin","贴到屏幕"),("ocr","文字与二维码识别"),("share","分享"),("left","向左旋转"),("right","向右旋转"),("flipH","水平翻转"),("flipV","垂直翻转"),("reveal","显示应用副本"),("close",isThumbnail ? "删除缩略图":"关闭贴图")];if isThumbnail{items += [("saveAll","全部保存到文件夹…"),("closeAll","删除全部缩略图")]};for(action,title)in items{let item=NSMenuItem(title:ImageWindowsService.localized(title),action:#selector(menuAction(_:)),keyEquivalent:"");item.target=self;item.representedObject=action;menu.addItem(item)};return menu}
}

@MainActor private final class OCRResultController:NSViewController,NSTextViewDelegate {
    let source=NSTextView(),translated=NSTextView(),target=NSPopUpButton(),backend=NSPopUpButton(),status=NSTextField(labelWithString:""),counts=NSTextField(labelWithString:"")
    let translateButton=NSButton(),copyTranslation=NSButton(),cancelButton=NSButton()
    let originalText:String,codes:[String],initialTranslation:String,initialTarget:String,initialBackend:String?
    let targets=[("简体中文","zh-CN"),("繁體中文","zh-TW"),("English","en"),("日本語","ja"),("한국어","ko")]
    var task:Task<Void,Never>?,generation=0,closed=false
    init(text:String,codes:[String],translation:String,target:String,backend:String?=nil){initialBackend=backend;originalText=text;self.codes=Array(codes.filter{$0.utf8.count<=8192}.prefix(32));initialTranslation=translation;initialTarget=target;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){nil}
    override func loadView(){
        let root=NSView(frame:CGRect(x:0,y:0,width:720,height:700)),column=NSStackView();column.orientation = .vertical;column.alignment = .leading;column.spacing=10;column.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(column);NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:18),column.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),column.topAnchor.constraint(equalTo:root.topAnchor,constant:16),column.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-16)])
        func row(_ views:[NSView])->NSStackView{let stack=NSStackView(views:views);stack.orientation = .horizontal;stack.spacing=8;stack.alignment = .centerY;return stack}
        func add(_ view:NSView){column.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:column.widthAnchor).isActive=true}
        counts.textColor = .secondaryLabelColor;let search=button("搜索原文",#selector(searchSource));add(row([NSTextField(labelWithString:ImageWindowsService.localized("识别原文")),counts,NSView(),search]))
        let original=editor(source,editable:true);source.string=originalText;source.delegate=self;add(original)
        if !codes.isEmpty{let qr=NSScrollView(frame:CGRect(x:0,y:0,width:680,height:min(120,codes.count*32)));qr.hasVerticalScroller=true;let document=NSView(frame:CGRect(x:0,y:0,width:680,height:codes.count*32));document.autoresizingMask=[.width];for(index,code)in codes.enumerated(){let y=(codes.count-index-1)*32;let text=NSTextField(labelWithString:code);text.lineBreakMode = .byTruncatingMiddle;text.toolTip=code;text.frame=CGRect(x:0,y:y+6,width:480,height:20);text.autoresizingMask=[.width];let open=button("打开链接",#selector(openQR(_:)));open.tag=index;open.frame=CGRect(x:490,y:y,width:90,height:28);open.autoresizingMask=[.minXMargin];open.isEnabled=Self.webURL(code) != nil;let copy=button("复制",#selector(copyQR(_:)));copy.tag=index;copy.frame=CGRect(x:588,y:y,width:80,height:28);copy.autoresizingMask=[.minXMargin];document.addSubview(text);document.addSubview(open);document.addSubview(copy)};qr.documentView=document;add(qr);qr.heightAnchor.constraint(equalToConstant:CGFloat(min(120,codes.count*32))).isActive=true}
        backend.addItems(withTitles:[ImageWindowsService.localized("系统翻译"),ImageWindowsService.localized("模型翻译")]);backend.selectItem(at:initialBackend=="model" ? 1:0);if #unavailable(macOS 26.0){backend.item(at:0)?.isEnabled=false};backend.target=self;backend.action=#selector(backendChanged)
        target.addItems(withTitles:targets.map{ImageWindowsService.localized($0.0)});if let index=targets.firstIndex(where:{$0.0==initialTarget||$0.1==initialTarget}){target.selectItem(at:index)};target.target=self;target.action=#selector(targetChanged)
        configure(translateButton,"翻译",#selector(translatePressed));configure(cancelButton,"取消翻译",#selector(cancelPressed));cancelButton.isEnabled=false;add(row([backend,NSTextField(labelWithString:ImageWindowsService.localized("翻译为")),target,translateButton,cancelButton,NSView()]))
        translated.string=initialTranslation;let translation=editor(translated,editable:false);add(translation);original.heightAnchor.constraint(equalTo:translation.heightAnchor).isActive=true;original.heightAnchor.constraint(greaterThanOrEqualToConstant:150).isActive=true;translation.heightAnchor.constraint(greaterThanOrEqualToConstant:140).isActive=true
        status.textColor = .secondaryLabelColor;status.lineBreakMode = .byWordWrapping;status.maximumNumberOfLines=2;add(status)
        let copy=button("复制原文",#selector(copySource));configure(copyTranslation,"复制译文",#selector(copyTranslated));copyTranslation.isEnabled = !initialTranslation.isEmpty;add(row([NSTextField(labelWithString:ImageWindowsService.localized("可修改识别结果后再复制")),NSView(),copy,copyTranslation]))
        view=root;updateCounts()
    }
    func editor(_ field:NSTextView,editable:Bool)->NSScrollView{let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;field.isEditable=editable;field.isRichText=false;field.font=NSFont.systemFont(ofSize:15);field.textContainerInset=CGSize(width:8,height:8);field.minSize = .zero;field.maxSize=CGSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);field.frame=CGRect(x:0,y:0,width:640,height:180);field.backgroundColor = .textBackgroundColor;field.textColor = .textColor;field.isVerticallyResizable=true;field.isHorizontallyResizable=false;field.autoresizingMask=[.width];field.textContainer?.widthTracksTextView=true;scroll.documentView=field;return scroll}
    func button(_ title:String,_ action:Selector)->NSButton{let item=NSButton();configure(item,title,action);return item}
    func configure(_ button:NSButton,_ title:String,_ action:Selector){button.title=ImageWindowsService.localized(title);button.bezelStyle = .rounded;button.target=self;button.action=action}
    func updateCounts(){counts.stringValue="\(source.string.count) \(ImageWindowsService.localized("字符")) · \(source.string.split(whereSeparator:{$0.isWhitespace}).count) \(ImageWindowsService.localized("词"))"}
    func textDidChange(_ notification:Notification){updateCounts();if task != nil{cancel()};translated.string="";copyTranslation.isEnabled=false;status.stringValue=ImageWindowsService.localized("原文已修改，请重新翻译")}
    @objc func backendChanged(){if task != nil{cancel()};translated.string="";copyTranslation.isEnabled=false;status.stringValue=ImageWindowsService.localized(backend.indexOfSelectedItem==1 ? "模型翻译仅在点击翻译后将原文发送到你配置的接口":"系统翻译在设备端处理，不会转用模型接口")}
    @objc func targetChanged(){if task != nil{cancel()};translated.string="";copyTranslation.isEnabled=false;status.stringValue=ImageWindowsService.localized("目标语言已更改，请点击翻译")}
    @objc func translatePressed(){startTranslation()}
    func startTranslation(){_ = view;guard !closed else{return};let selection=source.selectedRange();let text=selection.length>0 ? (source.string as NSString).substring(with:selection):source.string;guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=10000 else{status.stringValue=ImageWindowsService.localized("翻译支持1–10000字，可修改或选择部分原文");return};let selectedBackend=backend.indexOfSelectedItem==1 ? "model":"system";let legacy=ImageWindowsService.allowLegacyTranslationProviderForTesting && ImageWindowsService.translationProviderWithBackend==nil
        if selectedBackend=="system",!legacy{if #unavailable(macOS 26.0){status.stringValue=ImageWindowsService.localized("系统翻译需要macOS26，请明确选择模型翻译");return}}
        let provider:((String,String)async throws->String)
        if let current=ImageWindowsService.translationProviderWithBackend{provider={text,target in try await current(text,target,selectedBackend)}}else if legacy,let old=ImageWindowsService.translationProvider{provider=old}else{status.stringValue=ImageWindowsService.localized(selectedBackend=="model" ? "请先在API设置中配置翻译接口":"系统翻译服务暂不可用");return};cancel();generation+=1;let ticket=generation;translateButton.isEnabled=false;cancelButton.isEnabled=true;status.stringValue=ImageWindowsService.localized(selectedBackend=="model" ? "正在使用模型翻译…":"正在设备端翻译…");let language=targets[max(0,target.indexOfSelectedItem)].0
        task=Task{@MainActor [weak self]in do{let result=try await provider(text,language);guard let self,!self.closed,self.generation==ticket,!Task.isCancelled else{return};self.translated.string=result;self.copyTranslation.isEnabled = !result.isEmpty;self.status.stringValue=ImageWindowsService.localized("翻译完成")}catch{guard let self,!self.closed,self.generation==ticket else{return};self.status.stringValue=ImageWindowsService.translationError(error)};guard let self,self.generation==ticket else{return};self.translateButton.isEnabled=true;self.cancelButton.isEnabled=false;self.task=nil}
    }
    func cancel(){generation+=1;if task != nil{task?.cancel();task=nil;ImageWindowsService.cancelTranslation?()};translateButton.isEnabled=true;cancelButton.isEnabled=false}
    func close(){closed=true;cancel()}
    @objc func cancelPressed(){cancel();status.stringValue=ImageWindowsService.localized("翻译已取消")}
    @objc func copySource(){write(source.string)}
    @objc func copyTranslated(){write(translated.string)}
    @objc func copyQR(_ sender:NSButton){guard codes.indices.contains(sender.tag)else{return};write(codes[sender.tag])}
    func write(_ value:String){NSPasteboard.general.clearContents();status.stringValue=ImageWindowsService.localized(NSPasteboard.general.setString(value,forType:.string) ? "已复制":"复制失败")}
    static func webURL(_ text:String)->URL?{guard let url=URL(string:text),["https","http"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,url.user==nil,url.password==nil else{return nil};return url}
    @objc func openQR(_ sender:NSButton){guard codes.indices.contains(sender.tag),let url=Self.webURL(codes[sender.tag])else{return};if !NSWorkspace.shared.open(url){status.stringValue=ImageWindowsService.localized("无法打开链接")}}
    @objc func searchSource(){let selected=source.selectedRange();let value=selected.length>0 ? (source.string as NSString).substring(with:selected):source.string;guard !value.isEmpty,value.count<=2000 else{status.stringValue=ImageWindowsService.localized("请选择2000字以内的原文后搜索");return};var url=URLComponents(string:"https://www.google.com/search")!;url.queryItems=[URLQueryItem(name:"q",value:value)];if let target=url.url{NSWorkspace.shared.open(target)}}
}
