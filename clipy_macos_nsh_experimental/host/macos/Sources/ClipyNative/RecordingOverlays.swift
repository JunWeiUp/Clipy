import AppKit
import ApplicationServices
import Carbon

/// These observers, windows and timer exist only during an active recording.
@MainActor final class RecordingOverlays:NSObject {
    var hud:NSPanel?
    var keyPanel:NSPanel?
    var clickPanels:[NSPanel] = []
    var monitors:[Any] = []
    var timer:Timer?
    var fadeTask:Task<Void,Never>?
    let started = Date()
    let elapsed = NSTextField(labelWithString:"00:00")
    let keys = NSTextField(labelWithString:"")
    let stop:()->Void
    let screen:NSScreen
    init(parameters:[String:Any],displayId:CGDirectDisplayID,stop:@escaping()->Void) throws {
        self.stop = stop
        screen = NSScreen.screens.first(where:{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayId }) ?? NSScreen.main!
        super.init()
        let clicks = parameters["highlightClicks"] as? Bool ?? parameters["recordClicks"] as? Bool ?? false,showKeys = parameters["showKeys"] as? Bool ?? parameters["recordKeys"] as? Bool ?? false
        if (clicks || showKeys) && !(CGPreflightListenEventAccess() || AXIsProcessTrusted()) { throw BridgeFailure(code:"PERMISSION_DENIED",message:"点击高亮和按键显示需要输入监控或辅助功能权限") }
        if parameters["hideHUD"] as? Bool != true { showHUD() }
        if clicks,let observer = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown],handler:{ [weak self] _ in Task { @MainActor in self?.showClick() } }) { monitors.append(observer) }
        if showKeys,let observer = NSEvent.addGlobalMonitorForEvents(matching:.keyDown,handler:{ [weak self] event in
            Task { @MainActor in guard !IsSecureEventInputEnabled() else { return };let flags = event.modifierFlags.intersection([.command,.control,.option,.shift]);let onlyShortcuts = parameters["keyMode"] as? String != "all"
                guard !onlyShortcuts || !flags.intersection([.command,.control,.option]).isEmpty else { return }
                var text = flags.contains(.control) ? "⌃":"";if flags.contains(.option) { text += "⌥" };if flags.contains(.shift) { text += "⇧" };if flags.contains(.command) { text += "⌘" }
                switch event.keyCode { case 36:text += "↩";case 53:text += "⎋";case 51:text += "⌫";case 48:text += "⇥";case 49:text += "Space";case 123:text += "←";case 124:text += "→";case 125:text += "↓";case 126:text += "↑";default:text += String((event.charactersIgnoringModifiers ?? "").prefix(8)).uppercased() };self?.showKey(text)
            }
        }) { monitors.append(observer) }
    }
    func panel(_ rect:CGRect) -> NSPanel {
        let window = NSPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);window.level = .floating;window.isOpaque = false;window.backgroundColor = .clear;window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary];window.isReleasedWhenClosed = false;return window
    }
    func showHUD() {
        let visible = screen.visibleFrame
        let window = panel(CGRect(x:visible.midX-90,y:visible.maxY-72,width:180,height:42));window.isMovableByWindowBackground = true
        let stack = NSStackView();stack.orientation = .horizontal;stack.spacing = 12;stack.edgeInsets = NSEdgeInsets(top:8,left:14,bottom:8,right:14);stack.wantsLayer = true;stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor;stack.layer?.cornerRadius = 18
        let dot = NSTextField(labelWithString:"●");dot.textColor = .systemRed;elapsed.textColor = .white;elapsed.font = .monospacedDigitSystemFont(ofSize:14,weight:.medium)
        let button = NSButton(title:"结束",target:self,action:#selector(stopPressed));button.bezelStyle = .rounded;stack.addArrangedSubview(dot);stack.addArrangedSubview(elapsed);stack.addArrangedSubview(button);window.contentView = stack;hud = window;window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in guard let self else { return };let duration = Int(Date().timeIntervalSince(self.started));self.elapsed.stringValue = String(format:"%02d:%02d",duration/60,duration%60);BridgeOutput.write(["event":"recording.progress","payload":["duration":duration]]) } }
    }
    @objc func stopPressed() { stop() }
    func showClick() {
        let location = NSEvent.mouseLocation,size:CGFloat = 38
        if clickPanels.count >= 8 { clickPanels.removeFirst().close() }
        let window = panel(CGRect(x:location.x-size/2,y:location.y-size/2,width:size,height:size));window.ignoresMouseEvents = true
        let view = NSView();view.wantsLayer = true;view.layer?.cornerRadius = size/2;view.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor;view.layer?.borderWidth = 2;view.layer?.borderColor = NSColor.systemOrange.cgColor;window.contentView = view;clickPanels.append(window);window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.35;window.animator().alphaValue = 0 },completionHandler:{ [weak self,weak window] in Task { @MainActor in guard let window else { return };window.close();self?.clickPanels.removeAll(where:{$0 === window}) } })
    }
    func showKey(_ text:String) {
        guard !text.isEmpty else { return };fadeTask?.cancel()
        if keyPanel == nil { let window = panel(CGRect(x:screen.visibleFrame.midX-120,y:screen.visibleFrame.minY+44,width:240,height:46));window.ignoresMouseEvents = true;keys.alignment = .center;keys.font = .systemFont(ofSize:22,weight:.semibold);keys.textColor = .white;keys.drawsBackground = true;keys.backgroundColor = NSColor.black.withAlphaComponent(0.8);window.contentView = keys;keyPanel = window }
        keys.stringValue = text;keyPanel?.orderFrontRegardless();fadeTask = Task { [weak self] in try? await Task.sleep(nanoseconds:1_200_000_000);guard !Task.isCancelled else { return };self?.keyPanel?.orderOut(nil) }
    }
    func close() { timer?.invalidate();timer = nil;fadeTask?.cancel();fadeTask = nil;for monitor in monitors { NSEvent.removeMonitor(monitor) };monitors.removeAll();hud?.close();hud = nil;keyPanel?.close();keyPanel = nil;for panel in clickPanels { panel.close() };clickPanels.removeAll() }
}
