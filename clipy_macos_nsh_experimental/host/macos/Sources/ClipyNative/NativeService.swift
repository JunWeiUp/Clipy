import AppKit
import Foundation
import Vision
import Security
import IOKit.pwr_mgt
import AVFoundation
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct BridgeFailure: Error { let code: String; let message: String }
@MainActor final class NativeService {
    let root: URL
    let pasteboard:NSPasteboard = CommandLine.arguments.contains("--test-pasteboard") ? NSPasteboard(name:NSPasteboard.Name("dev.clipy.tsx.test."+UUID().uuidString)) : .general
    var awake: IOPMAssertionID = 0
    var clipboardTimer: Timer?
    var lastChange = -1
    var excludedApps = Set<String>()
    var activeBundleId = ""
    var blockedClipboardChange:Int?
    let speech = NSSpeechSynthesizer()
    let relay: RelayBridge
    let vision: CaptureVisionService
    let language: LanguageService
    var ocrTranslation: LanguageService?
    var ocrAppleTranslation: AppleTranslationService?
    let recording:RecordingService
    let system:SystemService
    let menuBar:NativeMenuBarService
    let scroller:ScrollCaptureService
    let storage:HistoryStorageService
    let diagnostics:DiagnosticsService
    let editorInput:EditorInputService
    var capturing = false
    var imageWorkBusy = false
    var previewGeneration = 0
    var previewWork:Task<[String:Any],Error>?
    var ownedEditedOutputs = Set<String>()
    var editedOutputUsers:[String:Int] = [:]
    var pickerOpen = false
    var activeDialog:NSSavePanel?
    var applicationObserver:NSObjectProtocol?
    var screenObservers:[NSObjectProtocol] = []
    var pasteTarget:NSRunningApplication?
    var selectedFiles = Set<String>()
    let lan:LANService
    let lanIdentityError:String?
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.prepareEditedCache(root:root)
        relay = RelayBridge(root: root)
        language = LanguageService(account:root.path)
        vision = CaptureVisionService(root:root)
        recording = RecordingService(root:root)
        system = SystemService(root:root)
        menuBar = NativeMenuBarService(root:root,emit:{ event,payload in BridgeOutput.write(["event":event,"payload":payload]) })
        scroller = ScrollCaptureService(root:root)
        diagnostics = DiagnosticsService(root:root)
        editorInput = EditorInputService(emit:{ event,payload in BridgeOutput.write(["event":event,"payload":payload]) })
        storage = try HistoryStorageService(root:root,authorizePath:{ URL(fileURLWithPath:$0).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") })
        do { lan = try Self.makeLAN(root:root);lanIdentityError = nil }
        catch { lanIdentityError = "原局域网身份文件不可读取或已损坏，已保留原文件，请恢复备份";lan = LANService(emit:{ _,_ in },peerId:"identity-unavailable",receiveDirectory:root.appendingPathComponent("received"),stateDirectory:root.appendingPathComponent("lan-state")) }
        relay.lan = lanIdentityError == nil ? lan:nil
        ImageWindowsService.translationProvider = { [weak self] text,target in
            guard let self else { throw CancellationError() }
            // OCR translations have their own cancellable request owner; closing
            // the OCR window must not cancel a dictionary/model window request.
            let service = LanguageService(account:self.root.path)
            self.ocrTranslation?.session?.invalidateAndCancel()
            self.ocrTranslation = service
            defer { if self.ocrTranslation === service { self.ocrTranslation = nil } }
            guard let result = try await service.invoke("model.translate",["text":text,"target":target]) as? [String:Any],let translated = result["text"] as? String else { throw BridgeFailure(code:"INVALID_RESPONSE",message:"模型未返回译文") }
            return translated
        }
        ImageWindowsService.translationProviderWithBackend = { [weak self] text,target,backend in
            guard let self else {throw CancellationError()}
            if backend == "model" {
                self.ocrAppleTranslation?.cancel();self.ocrAppleTranslation=nil
                guard let provider=ImageWindowsService.translationProvider else {throw CancellationError()}
                return try await provider(text,target)
            }
            guard backend == "system" else {throw BridgeFailure(code:"INVALID_ARGUMENT",message:"请选择系统或模型翻译")}
            self.ocrTranslation?.session?.invalidateAndCancel();self.ocrTranslation=nil
            let apple=AppleTranslationService();self.ocrAppleTranslation=apple
            defer {if self.ocrAppleTranslation === apple {self.ocrAppleTranslation=nil}}
            guard let result=try await apple.invoke("translate",["text":text,"target":target]) as? [String:Any],let translated=result["text"] as? String else {throw BridgeFailure(code:"INVALID_RESPONSE",message:"系统翻译未返回译文")}
            return translated
        }
        ImageWindowsService.actionHandler = { [weak self] action,path in
            guard let self else { return }
            do { let staged = try self.stagePreviewAction(action:action,path:path)
                self.emit("image.action",["action":action,"path":staged])
            } catch { self.emit("image.actionError",["message":"无法准备图片操作，请关闭不再使用的预览后重试"]) }
        }
        ImageWindowsService.cancelTranslation = { [weak self] in
            self?.ocrTranslation?.session?.invalidateAndCancel()
            self?.ocrTranslation = nil
            self?.ocrAppleTranslation?.cancel();self?.ocrAppleTranslation=nil
        }
        for name in ["com.apple.screenIsLocked","com.apple.screenIsUnlocked"] {
            screenObservers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main) { [weak self] _ in Task { @MainActor in await self?.lan.broadcastScreenState() } })
        }
        lan.screenStateProvider = { [weak self] in
            guard let self,let state = try? await self.system.invoke("screenControl.status",[:]) as? [String:Any] else { return ["configured":false,"locked":NSNull(),"helper":false] }
            return ["configured":state["configured"] ?? false,"locked":state["locked"] ?? NSNull(),"helper":state["accessibility"] ?? false]
        }
        lan.screenCommandHandler = { [weak self] action in
            guard let self else { return "unavailable" };let desired = action == "lock"
            if let locked = self.system.lockState(),locked == desired { return "ok" }
            do {
                _ = try await self.system.invoke("screenControl."+action,[:])
                for _ in 0..<20 { try Task.checkCancellation();if let locked = self.system.lockState(),locked == desired { return "ok" };try await Task.sleep(nanoseconds:500_000_000) };return "notConfirmed"
            } catch let failure as BridgeFailure {
                switch failure.code { case "NOT_CONFIGURED":return "notConfigured";case "PERMISSION_DENIED":return "accessibilityRequired";case "SESSION_MISMATCH","NO_LOGIN_WINDOW":return "sessionUnavailable";case "SECURE_FIELD_UNAVAILABLE":return "secureFieldUnavailable";case "UNLOCK_DENIED":return "secureFieldWriteFailed";case "NOT_READY":return "credentialUnavailable";default:return "notConfirmed" }
            } catch is CancellationError { return "cancelled" } catch { return "notConfirmed" }
        }
        activeBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        rememberTarget(NSWorkspace.shared.frontmostApplication)
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return };let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication;let next = app?.bundleIdentifier ?? ""
                if self.excludedApps.contains(self.activeBundleId) || self.excludedApps.contains(next) { self.lastChange = self.pasteboard.changeCount;self.blockedClipboardChange = self.lastChange }
                self.activeBundleId = next;self.rememberTarget(app)
            }
        }
    }
    func emit(_ event: String, _ payload: Any) { BridgeOutput.write(["event":event,"payload":payload]) }
    func close() {
        clipboardTimer?.invalidate(); clipboardTimer = nil
        activeDialog?.cancel(nil);activeDialog = nil
        ShortcutRecorder.active?.cancel()
        if CommandLine.arguments.contains("--test-pasteboard") { pasteboard.clearContents();pasteboard.releaseGlobally() }
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver);self.applicationObserver = nil }
        for observer in screenObservers { DistributedNotificationCenter.default().removeObserver(observer) };screenObservers.removeAll()
        closeImagePreviews()
        for path in Array(ownedEditedOutputs) { try? releaseEditedOutput(path) }
        menuBar.remove()
        system.close()
        editorInput.close()
        diagnostics.close()
        storage.close()
        recording.cancel()
        scroller.cancelCapture()
        ocrTranslation?.session?.invalidateAndCancel();ocrTranslation = nil
        ocrAppleTranslation?.cancel();ocrAppleTranslation=nil
        ImageWindowsService.closeAll()
        ShareService.closeAll()
        lan.stopAll()
        speech.stopSpeaking(); if awake != 0 { IOPMAssertionRelease(awake); awake = 0 }
        NativeScreenshotSelector.cancel()
        Task { await relay.shutdown() }
    }
    func text(_ p: [String:Any], _ key: String) throws -> String {
        guard let value = p[key] as? String, !value.isEmpty else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"缺少参数 \(key)") }; return value
    }
    func invoke(_ method: String, _ p: [String:Any]) async throws -> Any {
        if ["menubar.install","menubar.status","menubar.remove"].contains(method) { return try menuBar.invoke(method,p) }
        let editedUse = method == "files.saveCopy" ? (p["path"] as? String):nil
        if let editedUse,ownedEditedOutputs.contains(editedUse) { editedOutputUsers[editedUse,default:0] += 1 }
        defer { if let editedUse,let count = editedOutputUsers[editedUse] { if count <= 1 { editedOutputUsers.removeValue(forKey:editedUse) } else { editedOutputUsers[editedUse] = count-1 } } }
        let heavyImage = ["image.render","image.compose","image.redact","image.smartHighlight","ocr.recognize"].contains(method)
        if heavyImage { guard !imageWorkBusy else { throw BridgeFailure(code:"BUSY",message:"图像正在处理，请稍候") };imageWorkBusy = true }
        defer { if heavyImage { imageWorkBusy = false } }
        if ["editor.watchPressure","editor.stopPressure","editor.pressureStatus"].contains(method) { return try editorInput.invoke(method,p) }
        if method.hasPrefix("logs.") || method == "system.diagnostics" { return try await diagnostics.invoke(method,p) }
        if method.hasPrefix("lan."),let lanIdentityError {
            if method == "lan.status" { return ["identityError":lanIdentityError,"peers":[],"listening":false] as [String:Any] };throw BridgeFailure(code:"IDENTITY_CORRUPT",message:lanIdentityError)
        }
        if method.hasPrefix("storage.") || method.hasPrefix("media.") || method.hasPrefix("history.") {
            if method == "media.import" { guard allowed(p["path"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择媒体") } }
            return try await storage.invoke(method,p)
        }
        if method.hasPrefix("screenControl.") || ["system.loginItem","system.loginItemStatus","system.hiddenIcons","system.openHiddenIcon","system.notify","permissions.input","permissions.inputRequest","permissions.notifications","permissions.notificationsRequest"].contains(method) { let result = try await system.invoke(method,p);if ["screenControl.configure","screenControl.disable","screenControl.lock","screenControl.unlock"].contains(method) { await lan.broadcastScreenState() };return result }
        if method.hasPrefix("video.") || ["files.saveCopy","files.stageMedia"].contains(method) {
            if method != "video.cancel" { guard allowed(p["path"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择媒体文件") } }
            return try await MediaService.invoke(method,p,root:root)
        }
        if method.hasPrefix("model.") || method == "lookup.query" { return try await language.invoke(method,p) }
        if method.hasPrefix("relay.") { return try await relay.invoke(String(method.dropFirst(6)), p) }
        switch method {
        case "lan.scan":return try await lan.scan(port:p["port"] as? Int)
        case "lan.cancelScan":lan.cancelScan();return true
        case "lan.authorize":
            if let peer = p["peerId"] as? String { return try lan.authorize(peerId:peer,clipboard:p["clipboard"] as? Bool ?? false,notifications:p["notifications"] as? Bool ?? false) };return try lan.setAuthorizedPeers(p["peers"] as? [String] ?? [])
        case "lan.broadcast":return try lan.broadcast(text:try text(p,"text"))
        case "lan.notification":return try lan.notification(peerId:try text(p,"peerId"),type:try text(p,"type"),payload:p["payload"] as? [String:Any] ?? [:],hash:p["hash"] as? String ?? "")
        case "lan.replayHistory":return try await lan.replayHistory(peerId:try text(p,"peerId"),texts:p["texts"] as? [String] ?? [])
        case "lan.start":return try lan.start(port:p["port"] as? Int ?? 5567,deviceName:p["deviceName"] as? String ?? Host.current().localizedName ?? "Mac")
        case "lan.connect":return try await lan.connect(host:try text(p,"host"),port:p["port"] as? Int ?? 5566)
        case "lan.sendFile":
            let path = try text(p,"path");guard allowed(path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择文件") };return try await lan.sendFile(peerId:try text(p,"peerId"),path:path)
        case "lan.sendText":return try await lan.sendText(peerId:try text(p,"peerId"),text:try text(p,"text"))
        case "lan.ack":try lan.acknowledge(messageId:try text(p,"messageId"));return true
        case "lan.status":return lan.status()
        case "lan.stop":lan.stopLAN();return true
        case "recording.start":
            guard !capturing,!scroller.selecting,scroller.completion == nil else { throw BridgeFailure(code:"BUSY",message:"已有截图选区正在进行") };return try await withTaskCancellationHandler(operation:{ try await recording.start(p) },onCancel:{ Task { @MainActor in self.recording.cancel() } })
        case "recording.stop":return try await recording.stop()
        case "recording.status":return recording.status()
        case "recording.cancel":recording.cancel();return true
        case "shortcuts.record":return try await ShortcutRecorder.record()
        case "system.listApps":return AppCatalogService.list()
        case "system.appInfo":return AppCatalogService.appInfo(paths:p["paths"] as? [String] ?? [])
        case "system.appIcon":return try AppCatalogService.icon(root:root,bundleId:try text(p,"bundleId")) as Any? ?? NSNull()
        case "system.appearance":
            switch p["theme"] as? String ?? "system" { case "light":NSApp.appearance = NSAppearance(named:.aqua);case "dark":NSApp.appearance = NSAppearance(named:.darkAqua);case "system":NSApp.appearance = nil;default:throw BridgeFailure(code:"INVALID_ARGUMENT",message:"外观选项无效") };return true
        case "system.locale":ImageWindowsService.setLocale(p["language"] as? String ?? p["locale"] as? String ?? "zh-CN");return true
        case "files.revealReceived":
            let received = root.appendingPathComponent("received",isDirectory:true);try FileManager.default.createDirectory(at:received,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);NSWorkspace.shared.open(received);return ["path":received.path]
        case "capture.sound":return NSSound(named:NSSound.Name("Tink"))?.play() ?? false
        case "capture.export":
            guard allowed(p["path"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择截图") };return try CaptureOutputService.export(p)
        case "system.info": return ["platform":"macos","version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "preview","build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown","osVersion":ProcessInfo.processInfo.operatingSystemVersionString,"helperVersion":1,"lanIdentityError":lanIdentityError as Any? ?? NSNull(),"receivedDirectory":root.appendingPathComponent("received").path,"bundleUrl":Bundle.main.bundleURL.path,"bundleId":Bundle.main.bundleIdentifier ?? "","pid":ProcessInfo.processInfo.processIdentifier,"dataDirectory":root.path,"relaySDK":"common-relay Swift 0.1.5"]
        case "system.close": close(); DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { NSApp.terminate(nil) }; return true
        case "clipboard.concealChange":
            guard let expected = p["changeCount"] as? Int,expected == pasteboard.changeCount else { return ["concealed":false] }
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType");pasteboard.addTypes([concealed],owner:nil);let marked = pasteboard.setData(Data(),forType:concealed)
            lastChange = pasteboard.changeCount;blockedClipboardChange = lastChange;return ["concealed":marked,"changeCount":lastChange]
        case "clipboard.readText":
            guard !excludedApps.contains(activeBundleId),!clipboardIsConcealed(),blockedClipboardChange != pasteboard.changeCount else { return "" };let value = pasteboard.string(forType:.string) ?? "";return value.utf8.count <= 512*1024 ? value:""
        case "clipboard.read": return clipboard()
        case "clipboard.write":
            let written = try writeClipboard(p)
            guard written else { throw BridgeFailure(code:"COPY_FAILED",message:"剪贴板拒绝写入，未完成复制") }
            if p["sensitive"] as? Bool == true { let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType");pasteboard.addTypes([concealed],owner:nil);pasteboard.setData(Data(),forType:concealed);lastChange = pasteboard.changeCount;blockedClipboardChange = lastChange }
            if p["paste"] as? Bool == true { return try await invoke("clipboard.paste",[:]) };return written
        case "clipboard.watch":
            if let apps = p["excludedApps"] as? [String] { excludedApps = Set(apps.prefix(512)) }
            else if let apps = p["excludedApps"] as? [[String:Any]] { excludedApps = Set(apps.prefix(512).compactMap { $0["bundleId"] as? String }) }
            if excludedApps.contains(activeBundleId) { blockedClipboardChange = pasteboard.changeCount }
            clipboardTimer?.invalidate();clipboardTimer = nil
            if p["enabled"] as? Bool == true {
                lastChange = pasteboard.changeCount
                clipboardTimer = Timer.scheduledTimer(withTimeInterval:0.6,repeats:true) { [weak self] _ in Task { @MainActor in guard let self, self.lastChange != self.pasteboard.changeCount else { return };self.lastChange = self.pasteboard.changeCount;if self.excludedApps.contains(self.activeBundleId) { self.blockedClipboardChange = self.lastChange;return };self.emit("clipboard.changed", self.clipboard()) } }
            }; return ["enabled":clipboardTimer != nil]
        case "files.authorizeSelection":
            let paths = p["paths"] as? [String] ?? [];guard paths.count <= 32,paths.allSatisfy({ $0.utf8.count <= 4096 && $0.hasPrefix("/") && FileManager.default.fileExists(atPath:$0) }) else { throw BridgeFailure(code:"INVALID_SELECTION",message:"文件选择无效") }
            if selectedFiles.count + paths.count > 512 { selectedFiles.removeAll() };selectedFiles.formUnion(paths.map { URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath().path });return paths
        case "files.pick":
            guard !pickerOpen else { throw BridgeFailure(code:"BUSY",message:"文件选择器已打开") }; pickerOpen = true; defer { pickerOpen = false }
            let panel = NSOpenPanel();panel.canChooseDirectories = p["directories"] as? Bool ?? false;panel.canChooseFiles = true;panel.allowsMultipleSelection = p["multiple"] as? Bool ?? true
            let previousApp = NSWorkspace.shared.frontmostApplication;activeDialog = panel;NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
            defer { panel.orderOut(nil);activeDialog = nil;previousApp?.activate(options:[.activateIgnoringOtherApps]) }
            let response = await withTaskCancellationHandler(operation:{ await panel.begin() },onCancel:{ Task { @MainActor in panel.cancel(nil) } }); let paths = response == .OK ? panel.urls.map(\.path) : []
            if selectedFiles.count+paths.count > 512 { selectedFiles.removeAll() };selectedFiles.formUnion(paths.map{URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath().path});return paths
        case "files.readText":
            let path = try text(p,"path");guard allowed(path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择文件") }
            let maximum = min(max(p["maxBytes"] as? Int ?? 1024*1024,1),8*1024*1024)
            let handle = try FileHandle(forReadingFrom:URL(fileURLWithPath:path));defer { try? handle.close() };let bytes = try handle.read(upToCount:maximum+1) ?? Data()
            guard bytes.count <= maximum,let content = String(data:bytes,encoding:.utf8) else { throw BridgeFailure(code:"INVALID_FILE",message:"文件过大或不是 UTF-8 文本") };return content
        case "files.writeText":
            let content = p["content"] as? String ?? "";guard content.utf8.count <= 8*1024*1024 else { throw BridgeFailure(code:"TOO_LARGE",message:"文本超过 8 MiB") }
            guard !pickerOpen else { throw BridgeFailure(code:"BUSY",message:"文件选择器已打开") };pickerOpen = true;defer { pickerOpen = false }
            let panel = NSSavePanel();panel.nameFieldStringValue = p["name"] as? String ?? "clipy-snippets.json"
            let previousApp = NSWorkspace.shared.frontmostApplication;activeDialog = panel;NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
            defer { panel.orderOut(nil);activeDialog = nil;previousApp?.activate(options:[.activateIgnoringOtherApps]) }
            let response = await withTaskCancellationHandler(operation:{ await panel.begin() },onCancel:{ Task { @MainActor in panel.cancel(nil) } })
            guard response == .OK,let url = panel.url else { return ["cancelled":true] }
            try Data(content.utf8).write(to:url,options:.atomic);return ["path":url.path,"cancelled":false]
        case "files.reveal":
            let path = try text(p,"path");guard FileManager.default.fileExists(atPath:path) else { throw BridgeFailure(code:"NOT_FOUND",message:"文件不存在") };NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]);return true
        case "permissions.status":
            var result = permissions();if let state = try? await system.invoke("permissions.notifications",[:]) as? [String:Any] { result["notifications"] = state["granted"] ?? false };return result
        case "permissions.request":
            switch try text(p,"kind") {
            case "screen": return CGRequestScreenCaptureAccess()
            case "accessibility": return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
            case "microphone":
                guard Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] as? String != nil else { throw BridgeFailure(code:"PACKAGED_APP_REQUIRED",message:"请在完整预览应用中请求麦克风权限") };return await AVCaptureDevice.requestAccess(for:.audio)
            case "camera":
                guard Bundle.main.infoDictionary?["NSCameraUsageDescription"] as? String != nil else { throw BridgeFailure(code:"PACKAGED_APP_REQUIRED",message:"请在完整预览应用中请求摄像头权限") };return await AVCaptureDevice.requestAccess(for:.video)
            case "input":return try await system.invoke("permissions.inputRequest",p)
            case "notifications":return try await system.invoke("permissions.notificationsRequest",p)
            default: throw BridgeFailure(code:"UNSUPPORTED",message:"不支持此权限")
            }
        case "awake.set":
            let enabled = p["enabled"] as? Bool ?? false
            if enabled && awake == 0 { let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),"Clipy TSX 用户开启保持唤醒" as CFString,&awake);guard status == kIOReturnSuccess else { throw BridgeFailure(code:"SYSTEM_ERROR",message:"无法开启保持唤醒") } }
            if !enabled && awake != 0 { IOPMAssertionRelease(awake);awake = 0 };return ["enabled":awake != 0]
        case "capture.scroll":
            guard !capturing,!recording.starting,recording.stream == nil else { throw BridgeFailure(code:"BUSY",message:"已有截图或录屏正在进行") };return try await withTaskCancellationHandler(operation:{ try await scroller.start(p) },onCancel:{ Task { @MainActor in self.scroller.cancelCapture() } })
        case "capture.scroll.cancel":scroller.cancelCapture();return true
        case "capture.scroll.finish":scroller.finishCapture();return true
        case "capture.translateLine":
            let source = try text(p,"text"),target = try text(p,"target")
            guard !source.isEmpty,source.count<=500,target.count<=128 else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"图上翻译每行最多500字") }
            if (p["backend"] as? String ?? "system") == "system" {
                let service=AppleTranslationService()
                return try await withTaskCancellationHandler(operation:{try await service.invoke("translate",p)},onCancel:{Task{@MainActor in service.cancel()}})
            }
            guard p["backend"] as? String == "model" else {throw BridgeFailure(code:"INVALID_ARGUMENT",message:"请选择系统或模型翻译")}
            let service = LanguageService(account:root.path)
            return try await withTaskCancellationHandler(operation:{ try await service.invoke("model.translate",p) },onCancel:{ Task { @MainActor in service.session?.invalidateAndCancel() } })
        case "capture.screen":return try await withTaskCancellationHandler(operation:{ try await captureScreen(p) },onCancel:{ Task { @MainActor in NativeScreenshotSelector.cancel() } })
        case "image.closePreviews":closeImagePreviews();return true
        case "image.releaseOutput":try releaseEditedOutput(try text(p,"path"));return true
        case "files.discardStagedMedia","files.discardCaptureSource":
            let path=URL(fileURLWithPath:try text(p,"path")).standardizedFileURL
            let imports=root.appendingPathComponent(method == "files.discardCaptureSource" ? "captures":"imports").resolvingSymlinksInPath()
            let name=path.lastPathComponent.replacingOccurrences(of:"Preview-",with:"")
            if method == "files.discardCaptureSource",path.pathExtension.lowercased() != "png" {throw BridgeFailure(code:"ACCESS_DENIED",message:"仅能清理应用生成的PNG副本")}
            guard path.deletingLastPathComponent().resolvingSymlinksInPath()==imports,UUID(uuidString:String(name.prefix(36))) != nil else {throw BridgeFailure(code:"ACCESS_DENIED",message:"仅能清理应用生成的暂存副本")}
            if FileManager.default.fileExists(atPath:path.path) {
                let values=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true else {throw BridgeFailure(code:"ACCESS_DENIED",message:"暂存副本不是普通文件")}
                try FileManager.default.removeItem(at:path)
            };return true
        case "image.info":
            let path=try text(p,"path");guard allowed(path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") }
            guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,width>0,height>0,width<=120000,height<=120000,Int64(width)*Int64(height)<=80_000_000 else { throw BridgeFailure(code:"INVALID_IMAGE",message:"图片无效或超过8000万像素") }
            let attrs=try FileManager.default.attributesOfItem(atPath:path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,let bytes=attrs[.size] as? NSNumber else { throw BridgeFailure(code:"INVALID_IMAGE",message:"图片不是普通文件") }
            return ["width":width,"height":height,"bytes":bytes]
        case "image.compose":
            guard let paths=p["paths"] as? [String],paths.count==2,paths.allSatisfy({allowed($0)}) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择要拼接的图片") }
            let directory=root.appendingPathComponent("edited-images")
            let work=Task.detached(priority:.userInitiated) { try autoreleasepool { try ImageEditorService.compose(p,directory:directory) } }
            let result=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
            if let path=result["path"] as? String {try trackEditedOutput(path)};return result
        case "image.resize":
            guard allowed(p["path"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") };var options = p;options["directory"] = root.appendingPathComponent("processed").path;options["format"] = "png";return try CaptureOutputService.export(options)
        case "image.share":
            let path = try text(p,"path");guard allowed(path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") };return try ShareService.open(path:path,root:root)
        case "image.pin","image.thumbnail":
            guard allowed(p["path"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") };return try ImageWindowsService.open(kind:method == "image.pin" ? "pin":"thumbnail",params:p)
        case "image.ocrResult":return try ImageWindowsService.open(kind:"ocr",params:p)
        case "image.smartHighlight","image.redact":
            guard allowed(p["imagePath"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") }
            return try await vision.invoke(method,p)
        case "image.sample":
            guard allowed(p["imagePath"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") };return try ImageEditorService.sample(p)
        case "image.render":
            guard allowed(p["imagePath"] as? String ?? "") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") }
            if let annotations=p["annotations"] as? [[String:Any]] { for row in annotations { if let stampPath=row["imagePath"] as? String,!allowed(stampPath) { throw BridgeFailure(code:"ACCESS_DENIED",message:"图章来源已关闭或未授权") } } }
            let directory = root.appendingPathComponent("edited-images"),generation = previewGeneration,isPreview = p["preview"] as? Bool == true
            let work = Task.detached(priority:.userInitiated) { try autoreleasepool { try ImageEditorService.render(p,directory:directory) } }
            if isPreview { previewWork = work };defer { if isPreview,generation == previewGeneration { previewWork = nil } }
            let result = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
            if Task.isCancelled || (isPreview && generation != previewGeneration) {
                if let path = result["path"] as? String { try? releaseEditedOutput(path) };throw BridgeFailure(code:"CANCELLED",message:"图像预览已关闭")
            }
            if !isPreview,let path = result["path"] as? String { try trackEditedOutput(path) }
            return result
        case "ocr.recognize":
            let path=try text(p,"path");guard allowed(path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择图片") }
            return try await vision.invoke(method,p)
        case "speech.speak":
            let content = try text(p,"text"),language = (p["language"] as? String ?? "zh-CN").replacingOccurrences(of:"-",with:"_")
            guard content.count <= 10000 else { throw BridgeFailure(code:"TOO_LARGE",message:"朗读文本超过限制") }
            guard let voice = NSSpeechSynthesizer.availableVoices.first(where:{ (NSSpeechSynthesizer.attributes(forVoice:$0)[.localeIdentifier] as? String)?.replacingOccurrences(of:"-",with:"_").hasPrefix(language) == true }) else { throw BridgeFailure(code:"VOICE_UNAVAILABLE",message:"系统尚未安装所选语言的声音") }
            speech.stopSpeaking();speech.setVoice(voice);guard speech.startSpeaking(content) else { throw BridgeFailure(code:"SPEECH_FAILED",message:"系统声音暂时无法朗读") };return true
        case "speech.stop":speech.stopSpeaking();return true
        case "clipboard.paste":
            guard AXIsProcessTrusted() else { throw BridgeFailure(code:"PERMISSION_DENIED",message:"自动粘贴需要辅助功能权限") }
            guard let target = pasteTarget,!target.isTerminated else { throw BridgeFailure(code:"TARGET_UNAVAILABLE",message:"尚无粘贴目标，请先切换到目标应用，再返回 Clipy") }
            if let text = p["text"] as? String { pasteboard.clearContents();pasteboard.setString(text,forType:.string) }
            guard target.activate(options:[.activateIgnoringOtherApps]) else { throw BridgeFailure(code:"TARGET_UNAVAILABLE",message:"无法激活粘贴目标") }
            try await Task.sleep(nanoseconds:180_000_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { throw BridgeFailure(code:"TARGET_CHANGED",message:"目标应用未获得焦点，内容已复制") }
            let source = CGEventSource(stateID:.combinedSessionState);let down = CGEvent(keyboardEventSource:source,virtualKey:9,keyDown:true);let up = CGEvent(keyboardEventSource:source,virtualKey:9,keyDown:false);down?.flags = .maskCommand;up?.flags = .maskCommand
            down?.post(tap:.cghidEventTap);up?.post(tap:.cghidEventTap);return true
        default: throw BridgeFailure(code:"UNSUPPORTED",message:"尚未实现系统能力：\(method)")
        }
    }
    static func isGeneratedEditedFile(_ url:URL) -> Bool {
        guard url.pathExtension.lowercased() == "png" else { return false }
        let base = url.deletingPathExtension().lastPathComponent
        for prefix in ["Preview-","Clipy-"] where base.hasPrefix(prefix) { if UUID(uuidString:String(base.dropFirst(prefix.count))) != nil { return true } };return false
    }
    static func prepareEditedCache(root:URL) throws {
        let directory = root.appendingPathComponent("edited-images"),manifest = directory.appendingPathComponent(".generated-outputs.json")
        guard FileManager.default.fileExists(atPath:directory.path) else { return }
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else { throw BridgeFailure(code:"CACHE_PATH_INVALID",message:"图像缓存目录不能指向应用外部") }
        if ((try? manifest.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? Int.max) <= 65536,let data = try? Data(contentsOf:manifest),let names = try? JSONSerialization.jsonObject(with:data) as? [String] {
            for name in names.prefix(128) where !name.contains("/") { let url = directory.appendingPathComponent(name);if isGeneratedEditedFile(url),let values = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),values.isRegularFile == true,values.isSymbolicLink != true { try? FileManager.default.removeItem(at:url) } }
        }
        for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) where url.lastPathComponent.hasPrefix("Preview-") && isGeneratedEditedFile(url) {
            let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]);if values.isRegularFile == true,values.isSymbolicLink != true { try FileManager.default.removeItem(at:url) }
        }
        try Data("[]".utf8).write(to:manifest,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
    }
    func closeImagePreviews() {
        vision.cancelAll()
        NativeScreenshotSelector.cancel();activeDialog?.cancel(nil);activeDialog=nil
        ImageEditorService.closeCaches()
        previewGeneration += 1;previewWork?.cancel();previewWork = nil
        let directory = root.appendingPathComponent("edited-images")
        guard let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("Preview-") && Self.isGeneratedEditedFile(file) {
            guard let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),values.isRegularFile == true,values.isSymbolicLink != true else { continue };try? FileManager.default.removeItem(at:file)
        }
    }
    func releaseEditedOutput(_ path:String) throws {
        let file = URL(fileURLWithPath:path).standardizedFileURL,directory = root.appendingPathComponent("edited-images").standardizedFileURL
        guard file.deletingLastPathComponent() == directory,Self.isGeneratedEditedFile(file),directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else { throw BridgeFailure(code:"ACCESS_DENIED",message:"只能释放应用生成的图像缓存") }
        if FileManager.default.fileExists(atPath:file.path) { let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]);guard values.isRegularFile == true,values.isSymbolicLink != true else { throw BridgeFailure(code:"ACCESS_DENIED",message:"缓存文件类型无效") };try FileManager.default.removeItem(at:file) }
        ownedEditedOutputs.remove(file.path);try saveEditedManifest()
    }
    func trackEditedOutput(_ path:String) throws {
        ownedEditedOutputs.insert(path)
        let urls = ownedEditedOutputs.map { URL(fileURLWithPath:$0) }
        var total = urls.reduce(0) { $0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        let candidates = urls.filter { $0.path != path && editedOutputUsers[$0.path] == nil }.sorted { ((try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast) }
        for url in candidates where ownedEditedOutputs.count > 16 || total > 1024*1024*1024 {
            total -= (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0;try releaseEditedOutput(url.path)
        }
        guard ownedEditedOutputs.count <= 16,total <= 1024*1024*1024 else { try? releaseEditedOutput(path);throw BridgeFailure(code:"CACHE_QUOTA",message:"图像导出缓存已满，请先完成其他保存窗口") }
        do { try saveEditedManifest() } catch { try? releaseEditedOutput(path);throw error }
    }
    func saveEditedManifest() throws {
        let directory = root.appendingPathComponent("edited-images");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let manifest = directory.appendingPathComponent(".generated-outputs.json"),names = ownedEditedOutputs.map { URL(fileURLWithPath:$0).lastPathComponent }
        try JSONSerialization.data(withJSONObject:names).write(to:manifest,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
    }
    static func makeLAN(root:URL) throws -> LANService {
        let file = root.appendingPathComponent("lan-identity.json")
        let peerId:String
        if FileManager.default.fileExists(atPath:file.path) {
            let bytes = try Data(contentsOf:file)
            guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let saved = object["peerId"] as? String,UUID(uuidString:saved) != nil else { throw BridgeFailure(code:"IDENTITY_CORRUPT",message:"本机局域网身份文件损坏，已保留原文件，请恢复备份") };peerId = saved
        } else {
            peerId = UUID().uuidString;let bytes = try JSONSerialization.data(withJSONObject:["peerId":peerId]);try bytes.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        return LANService(emit:{ event,payload in BridgeOutput.write(["event":event,"payload":payload]) },peerId:peerId,receiveDirectory:root.appendingPathComponent("received"),stateDirectory:root.appendingPathComponent("lan-state"))
    }
    func rememberTarget(_ app:NSRunningApplication?) {
        guard let app,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let bundle = app.bundleIdentifier ?? "",path = app.executableURL?.path ?? ""
        guard !bundle.hasPrefix("dev.clipy.tsx"),!bundle.hasPrefix("com.example.clipytsx"),!path.contains("nsh-macos"),!path.contains("Clipy TSX") else { return };pasteTarget = app
    }
    func stagePreviewAction(action:String,path:String)throws->String {
        guard ["edit","ocr","share","pin"].contains(action),ImageWindowsService.owns(path:path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"图片预览已关闭") }
        let manager=FileManager.default,source=URL(fileURLWithPath:path)
        let attrs=try manager.attributesOfItem(atPath:source.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,let size=(attrs[.size] as? NSNumber)?.int64Value,size<=128*1024*1024 else { throw BridgeFailure(code:"IMAGE_LIMIT",message:"图片超出操作上限") }
        let directory=root.appendingPathComponent("imports",isDirectory:true)
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let pending=try manager.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey]).filter{$0.lastPathComponent.hasPrefix("Preview-")}
        let bytes=try pending.reduce(Int64(0)) { $0+Int64(try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) }
        guard pending.count<16,bytes+size<=1024*1024*1024 else { throw BridgeFailure(code:"CACHE_QUOTA",message:"图片操作暂存已满") }
        let ext=["png","jpg","jpeg","heic","tiff","gif","bmp"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased():"png"
        let target=directory.appendingPathComponent("Preview-"+UUID().uuidString+"."+ext)
        do { try manager.copyItem(at:source,to:target);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path) }
        catch { try? manager.removeItem(at:target);throw error }
        return target.path
    }
    func allowed(_ path: String) -> Bool { let normalized=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path;return normalized.hasPrefix(root.resolvingSymlinksInPath().path+"/") || selectedFiles.contains(normalized) }
    func writeClipboard(_ p:[String:Any]) throws -> Bool {
        let type = p["type"] as? String ?? "",plain = p["plain"] as? Bool ?? false
        if !plain,let paths = p["files"] as? [String] ?? p["paths"] as? [String],!paths.isEmpty {
            guard paths.count <= 32,paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && FileManager.default.fileExists(atPath:$0) }) else { throw BridgeFailure(code:"NOT_FOUND",message:"原文件已不存在") };pasteboard.clearContents();return pasteboard.writeObjects(paths.map { URL(fileURLWithPath:$0) as NSURL })
        }
        if !plain,let path = p["mediaPath"] as? String ?? p["imagePath"] as? String ?? p["path"] as? String {
            if ["file","files"].contains(type) { guard path.hasPrefix("/"),FileManager.default.fileExists(atPath:path) else { throw BridgeFailure(code:"NOT_FOUND",message:"原文件已不存在") };pasteboard.clearContents();return pasteboard.writeObjects([URL(fileURLWithPath:path) as NSURL]) }
            guard allowed(path) else { throw BridgeFailure(code:"ACCESS_DENIED",message:"请先选择媒体") }
            if type == "richText" || type == "rich" || ["rtf","html"].contains(URL(fileURLWithPath:path).pathExtension.lowercased()) {
                let bytes = try Data(contentsOf:URL(fileURLWithPath:path));guard bytes.count <= 8*1024*1024 else { throw BridgeFailure(code:"TOO_LARGE",message:"富文本超过 8 MiB") };let richType:NSPasteboard.PasteboardType = URL(fileURLWithPath:path).pathExtension.lowercased() == "rtf" ? .rtf:.html
                pasteboard.clearContents();if let text = p["text"] as? String { pasteboard.setString(text,forType:.string) };return pasteboard.setData(bytes,forType:richType)
            }
            if type == "pdf" || URL(fileURLWithPath:path).pathExtension.lowercased() == "pdf" { let bytes = try Data(contentsOf:URL(fileURLWithPath:path));guard bytes.count <= 32*1024*1024 else { throw BridgeFailure(code:"TOO_LARGE",message:"PDF 超过 32 MiB") };pasteboard.clearContents();return pasteboard.setData(bytes,forType:.pdf) }
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,width > 0,height > 0,width*height <= 80_000_000 else { throw BridgeFailure(code:"INVALID_IMAGE",message:"图片无效或超过 80 MP") }
            guard let image = NSImage(contentsOfFile:path),image.isValid else { throw BridgeFailure(code:"INVALID_IMAGE",message:"无法读取图片") };pasteboard.clearContents();return pasteboard.writeObjects([image])
        }
        let text = p["text"] as? String ?? p["content"] as? String ?? "";guard text.utf8.count <= 1024*1024 else { throw BridgeFailure(code:"TOO_LARGE",message:"文本超过 1 MiB") };pasteboard.clearContents();return pasteboard.setString(text,forType:.string)
    }
    func clipboardIsConcealed() -> Bool {
        let types = Set(pasteboard.types ?? []);return ["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType"].contains { types.contains(NSPasteboard.PasteboardType($0)) }
    }
    func clipboard() -> [String:Any] {
        let board = pasteboard
        if excludedApps.contains(activeBundleId) || clipboardIsConcealed() || blockedClipboardChange == board.changeCount { return ["changeCount":board.changeCount,"excluded":true] }
        var result:[String:Any] = ["changeCount":board.changeCount]
        if let app = NSWorkspace.shared.frontmostApplication { result["source"] = app.localizedName ?? "";result["bundleId"] = app.bundleIdentifier ?? "";if let bundle = app.bundleIdentifier,let icon = try? AppCatalogService.icon(root:root,bundleId:bundle) { result["sourceIconPath"] = icon } }
        if let text = board.string(forType:.string),text.utf8.count <= 512*1024 { result["text"] = text;result["type"] = "text" }
        if let urls = board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty { if selectedFiles.count+urls.count > 512 { selectedFiles.removeAll() };selectedFiles.formUnion(urls.prefix(32).map{$0.standardizedFileURL.resolvingSymlinksInPath().path});result["files"] = Array(urls.prefix(32)).map(\.path);result["type"] = "files" }
        for (format,extensionName) in [(NSPasteboard.PasteboardType.html,"html"),(NSPasteboard.PasteboardType.rtf,"rtf")] {
            if let bytes = board.data(forType:format),bytes.count <= 8*1024*1024 {
                let directory = root.appendingPathComponent("clipboard",isDirectory:true);try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let url = directory.appendingPathComponent("\(board.changeCount).\(extensionName)")
                if (try? bytes.write(to:url,options:.atomic)) != nil { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);result["mediaPath"] = url.path;result["path"] = url.path;result["type"] = "richText" };break
            }
        }
        for (type,kind,extensionName) in [(NSPasteboard.PasteboardType.pdf,"pdf","pdf"),(NSPasteboard.PasteboardType.png,"image","png"),(NSPasteboard.PasteboardType.tiff,"image","tiff"),(NSPasteboard.PasteboardType("public.jpeg"),"image","jpg")] {
            if let bytes = board.data(forType:type),bytes.count <= 32*1024*1024,!bytes.isEmpty {
                let directory = root.appendingPathComponent("clipboard",isDirectory:true)
                if (try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])) != nil {
                    let url = directory.appendingPathComponent("\(board.changeCount).\(extensionName)")
                    if (try? bytes.write(to:url,options:.atomic)) != nil { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);result["path"] = url.path;result["mediaPath"] = url.path;result["type"] = kind }
                };break
            }
        }
        return result
    }
    func permissions() -> [String:Any] { let value:[String:Any] = ["screen":CGPreflightScreenCaptureAccess(),"accessibility":AXIsProcessTrusted(),"microphone":AVCaptureDevice.authorizationStatus(for:.audio) == .authorized,"camera":AVCaptureDevice.authorizationStatus(for:.video) == .authorized,"input":CGPreflightListenEventAccess()];if let bytes=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){let target=root.appendingPathComponent("permissions-state.json");try? bytes.write(to:target,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)};return value }
    func captureScreen(_ p:[String:Any]) async throws -> Any {
        guard !capturing,!recording.starting,!scroller.selecting,scroller.completion == nil else { throw BridgeFailure(code:"BUSY",message:"已有截图选区正在进行") };capturing = true;defer { capturing = false }
        let mode = p["mode"] as? String ?? "region"
        guard let selection = try await NativeScreenshotSelector.select(mode:mode,snapping:p["snapping"] as? Bool ?? true,magnifier:p["magnifier"] as? Bool ?? p["captureMagnifier"] as? Bool ?? true,elementSnapping:p["captureSnapping"] as? Bool ?? true,selectionOnly:p["selectionOnly"] as? Bool ?? false) else { return ["cancelled":true] }
        try Task.checkCancellation()
        let captureScreen = NSScreen.screens.first(where:{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selection.displayId })
        let screenFrame = captureScreen.map { NativeScreenshotSelector.cgRect(CGRect(origin:.zero,size:$0.frame.size),screen:$0.frame,mainTop:NSScreen.screens.first?.frame.maxY ?? 0) } ?? selection.rect
        if let action = selection.action,["scroll","recording"].contains(action) {
            return ["action":action,"cancelled":false,"displayId":selection.displayId,
                "selectionRect":["x":selection.rect.minX,"y":selection.rect.minY,"width":selection.rect.width,"height":selection.rect.height],
                "displayFrame":["x":screenFrame.minX,"y":screenFrame.minY,"width":screenFrame.width,"height":screenFrame.height]]
        }
        let content:SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true) } catch { throw CaptureAccessPolicy.mapped(error) }
        guard #available(macOS 14.0,*) else { throw BridgeFailure(code:"PLATFORM_VERSION",message:"NSH 截图预览需要 macOS 14 或更新版本") }
        let config = SCStreamConfiguration(),filter:SCContentFilter,rect:CGRect,scale:CGFloat
        if let windowId = selection.windowId {
            guard let window = content.windows.first(where:{$0.windowID == windowId}) else { throw BridgeFailure(code:"WINDOW_GONE",message:"所选窗口已关闭，请重新截图") }
            filter = SCContentFilter(desktopIndependentWindow:window)
            // A desktop-independent window filter owns its complete content, even
            // across displays. Never intersect it with the originally clicked display.
            rect = filter.contentRect;scale = CGFloat(filter.pointPixelScale)
            config.ignoreShadowsSingleWindow = true
        } else {
            guard let display = content.displays.first(where:{$0.displayID == selection.displayId}) else { throw BridgeFailure(code:"NO_DISPLAY",message:"所选显示器已断开") }
            let screen = NSScreen.screens.first(where:{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID })
            scale = screen?.backingScaleFactor ?? 1;rect = selection.rect.intersection(display.frame)
            config.sourceRect = CGRect(x:rect.minX-display.frame.minX,y:rect.minY-display.frame.minY,width:rect.width,height:rect.height)
            filter = SCContentFilter(display:display,excludingApplications:content.applications.filter{$0.processID == getppid()},exceptingWindows:[])
        }
        let pixels = try NativeScreenshotSelector.pixelSize(contentRect:rect,pointPixelScale:scale)
        config.width = pixels.width;config.height = pixels.height;config.showsCursor = p["cursor"] as? Bool ?? p["captureCursor"] as? Bool ?? false
        let image:CGImage
        if let frozen = selection.frozenImage, !config.showsCursor {
            image = frozen
        } else {
            do { image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config) } catch { throw CaptureAccessPolicy.mapped(error) }
        }
        try Task.checkCancellation()
        let directory = root.appendingPathComponent("captures",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let target = directory.appendingPathComponent(UUID().uuidString+".png")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL,UTType.png.identifier as CFString,1,nil) else { throw BridgeFailure(code:"IMAGE_ENCODING",message:"无法编码截图") };CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw BridgeFailure(code:"IMAGE_ENCODING",message:"截图保存失败") };try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        return ["selectionRect":["x":selection.rect.minX,"y":selection.rect.minY,"width":selection.rect.width,"height":selection.rect.height],"displayFrame":["x":screenFrame.minX,"y":screenFrame.minY,"width":screenFrame.width,"height":screenFrame.height],"path":target.path,"width":image.width,"height":image.height,"cancelled":false,"displayId":selection.displayId,"windowId":selection.windowId as Any? ?? NSNull(),"backingScaleFactor":scale,"logicalWidth":rect.width,"logicalHeight":rect.height,"action":selection.action as Any? ?? NSNull()]
    }

}
