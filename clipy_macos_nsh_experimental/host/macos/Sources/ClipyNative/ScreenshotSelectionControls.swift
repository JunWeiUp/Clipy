import AppKit

@MainActor class ScreenshotOverlayHUD:NSVisualEffectView {
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect);NSColor(calibratedWhite:0.08,alpha:0.88).setFill();NSBezierPath(roundedRect:bounds,xRadius:12,yRadius:12).fill()}
}
@MainActor final class ScreenshotSelectionControls:ScreenshotOverlayHUD {
    weak var canvas:ScreenshotSelectionCanvas?
    let selected:Bool
    init(canvas:ScreenshotSelectionCanvas,selected:Bool) {
        self.canvas=canvas;self.selected=selected
        super.init(frame:.zero)
        appearance=NSAppearance(named:.darkAqua);material = .hudWindow;state = .active;blendingMode = .withinWindow
        wantsLayer=true;layer?.cornerRadius=14;layer?.masksToBounds=true
        let stack=NSStackView();stack.orientation = .horizontal;stack.spacing=7;stack.edgeInsets=NSEdgeInsets(top:7,left:9,bottom:7,right:9)
        stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor),stack.trailingAnchor.constraint(equalTo:trailingAnchor),stack.topAnchor.constraint(equalTo:topAnchor),stack.bottomAnchor.constraint(equalTo:bottomAnchor)])
        let items:[(String,String,String)]
        if selected && canvas.owner?.selectionOnly == true {items=[("添加到画布","plus.rectangle.on.rectangle","append"),("取消","xmark","cancel")]}
        else if selected {items=[("标注","pencil.tip","annotate"),("贴图","pin","pin"),("识别文字","text.viewfinder","ocr"),("翻译","character.bubble","translate"),("滚动截图","scroll","scroll"),("录屏","record.circle","recording"),("编辑窗口","square.and.pencil","editor"),("分享","square.and.arrow.up","share"),("保存","square.and.arrow.down","save"),("复制","doc.on.doc","copy"),("取消","xmark","cancel")]}
        else {items=[("区域","square.dashed","region"),("窗口","macwindow","window"),("全屏","display","fullscreen"),("取消","xmark","cancel")]}
        for (title,symbol,action) in items {
            let button=NSButton(title:title,target:self,action:#selector(pressed(_:)));button.identifier=NSUserInterfaceItemIdentifier(action)
            button.isBordered=false;button.font = .systemFont(ofSize:11,weight:action=="copy" || action=="append" ? .semibold:.regular);button.contentTintColor = .white
            button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:title);button.imagePosition = .imageAbove;button.toolTip=title;button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant:action=="append" ? 100:action=="editor" || action=="ocr" || action=="scroll" ? 66:50).isActive=true;button.heightAnchor.constraint(equalToConstant:42).isActive=true
            if action=="copy" || action=="append" { button.wantsLayer=true;button.layer?.backgroundColor=NSColor.controlAccentColor.cgColor;button.layer?.cornerRadius=9 }
            stack.addArrangedSubview(button)
        }
    }
    required init?(coder:NSCoder){nil}
    @objc func pressed(_ sender:NSButton) {
        guard let canvas,let action=sender.identifier?.rawValue else{return}
        if action=="cancel" { canvas.owner?.finish(nil) }
        else if selected { canvas.confirm(action:action) }
        else { canvas.changeMode(action) }
    }
}
@MainActor final class ScreenshotSizeControls:ScreenshotOverlayHUD {
    weak var canvas:ScreenshotSelectionCanvas?
    let widthField=NSTextField(string:""),heightField=NSTextField(string:"")
    let aspect=NSPopUpButton(),resolution=NSPopUpButton()
    let pixels=NSTextField(labelWithString:"")
    init(canvas:ScreenshotSelectionCanvas) {
        self.canvas=canvas;super.init(frame:.zero)
        appearance=NSAppearance(named:.darkAqua);material = .hudWindow;state = .active;blendingMode = .withinWindow;wantsLayer=true;layer?.cornerRadius=9;layer?.masksToBounds=true
        let stack=NSStackView();stack.orientation = .horizontal;stack.spacing=5;stack.edgeInsets=NSEdgeInsets(top:5,left:8,bottom:5,right:8);stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor),stack.trailingAnchor.constraint(equalTo:trailingAnchor),stack.topAnchor.constraint(equalTo:topAnchor),stack.bottomAnchor.constraint(equalTo:bottomAnchor)])
        let formatter=NumberFormatter();formatter.minimum=2;formatter.maximum=100000;formatter.maximumFractionDigits=0;formatter.allowsFloats=false
        for field in [widthField,heightField] { field.formatter=formatter;field.font = .monospacedDigitSystemFont(ofSize:12,weight:.semibold);field.alignment = .center;field.isBezeled=false;field.drawsBackground=false;field.textColor = .white;field.widthAnchor.constraint(equalToConstant:48).isActive=true;field.target=self;field.action=#selector(sizeChanged(_:)) }
        widthField.setAccessibilityLabel("选区宽度（点）");heightField.setAccessibilityLabel("选区高度（点）")
        let times=NSTextField(labelWithString:"×");times.textColor = .secondaryLabelColor
        aspect.addItems(withTitles:["自由","1:1","4:3","16:9"]);aspect.target=self;aspect.action=#selector(aspectChanged(_:));aspect.controlSize = .small;aspect.setAccessibilityLabel("宽高比")
        resolution.addItems(withTitles:["分辨率","1280 × 720","1920 × 1080","自定义…"]);resolution.menu?.autoenablesItems=false;resolution.target=self;resolution.action=#selector(resolutionChanged(_:));resolution.controlSize = .small;resolution.setAccessibilityLabel("分辨率预设（像素）")
        pixels.font = .systemFont(ofSize:11);pixels.textColor = .secondaryLabelColor;pixels.setAccessibilityLabel("原生像素尺寸");pixels.widthAnchor.constraint(greaterThanOrEqualToConstant:115).isActive=true
        [widthField,times,heightField,aspect,resolution,pixels].forEach{stack.addArrangedSubview($0)}
    }
    required init?(coder:NSCoder){nil}
    func update(_ rect:CGRect,scale:CGFloat) { if let canvas { resolution.item(at:1)?.isEnabled=canvas.bounds.width*canvas.pixelScale>=1280 && canvas.bounds.height*canvas.pixelScale>=720;resolution.item(at:2)?.isEnabled=canvas.bounds.width*canvas.pixelScale>=1920 && canvas.bounds.height*canvas.pixelScale>=1080 };pixels.stringValue="\(Int((rect.width*scale).rounded())) × \(Int((rect.height*scale).rounded())) px";if window?.firstResponder is NSTextView{return};widthField.stringValue=String(Int(rect.width.rounded()));heightField.stringValue=String(Int(rect.height.rounded())) }
    @objc func sizeChanged(_ sender:NSTextField) { canvas?.applySize(width:widthField.doubleValue,height:heightField.doubleValue,changedWidth:sender === widthField) }
    @objc func aspectChanged(_ sender:NSPopUpButton) { let ratios:[CGFloat?]=[nil,1,CGFloat(4)/3,CGFloat(16)/9];canvas?.setAspect(ratios[max(0,sender.indexOfSelectedItem)]) }
    func customResolution() {
        guard let window,let canvas,let rect=canvas.selection else{return}
        let alert=NSAlert();alert.messageText="自定义分辨率";alert.informativeText="请输入原生像素尺寸；超出屏幕范围时按比例缩小。";alert.addButton(withTitle:"应用");alert.addButton(withTitle:"取消");alert.window.appearance=NSAppearance(named:.darkAqua);alert.window.level=NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+1)
        let row=NSStackView();row.orientation = .horizontal;row.spacing=8
        let w=NSTextField(string:String(Int((rect.width*canvas.pixelScale).rounded()))),h=NSTextField(string:String(Int((rect.height*canvas.pixelScale).rounded())))
        for field in [w,h] {let formatter=NumberFormatter();formatter.minimum=2;formatter.maximum=100000;formatter.maximumFractionDigits=0;field.formatter=formatter;field.widthAnchor.constraint(equalToConstant:90).isActive=true};w.setAccessibilityLabel("宽度像素");h.setAccessibilityLabel("高度像素")
        row.addArrangedSubview(w);row.addArrangedSubview(NSTextField(labelWithString:"×"));row.addArrangedSubview(h);row.addArrangedSubview(NSTextField(labelWithString:"px"));row.frame=CGRect(x:0,y:0,width:260,height:28);alert.accessoryView=row
        alert.beginSheetModal(for:window){[weak canvas] response in if response == .alertFirstButtonReturn,w.doubleValue>=2,h.doubleValue>=2 {canvas?.applyPixelSize(width:w.doubleValue,height:h.doubleValue)} }
    }
    @objc func resolutionChanged(_ sender:NSPopUpButton) { switch sender.indexOfSelectedItem {case 1:canvas?.applyPixelSize(width:1280,height:720);case 2:canvas?.applyPixelSize(width:1920,height:1080);case 3:customResolution();default:break} }
}
