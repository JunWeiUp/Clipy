import AppKit
import Foundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import Security
import OpenDirectory

@MainActor final class SystemService {
    let root:URL
    var hidden:[String:HiddenItem] = [:]
    typealias Finding = (pid_t,String,String,Date?,AXUIElement,CGPoint,CGSize)
    var hiddenTask:Task<[Finding],Never>?
    func close() { hiddenTask?.cancel();hiddenTask = nil;hidden.removeAll() }
    struct HiddenItem { let pid:pid_t;let launched:Date?;let bundle:String;let element:AXUIElement }
    init(root:URL) { self.root = root }
    func invoke(_ method:String,_ p:[String:Any]) async throws -> Any {
        switch method {
        case "system.loginItem":
            guard Bundle.main.bundleURL.pathExtension == "app",Bundle.main.bundleIdentifier == "dev.clipy.tsx.macos" else { throw BridgeFailure(code:"PACKAGED_APP_REQUIRED",message:"请在完整预览应用包中设置登录启动") }
            if p["enabled"] as? Bool == true { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() };return ["enabled":SMAppService.mainApp.status == .enabled,"requiresApproval":SMAppService.mainApp.status == .requiresApproval]
        case "system.loginItemStatus":
            guard Bundle.main.bundleURL.pathExtension == "app" else { return ["enabled":false,"available":false] };return ["enabled":SMAppService.mainApp.status == .enabled,"requiresApproval":SMAppService.mainApp.status == .requiresApproval]
        case "permissions.input":return ["granted":CGPreflightListenEventAccess()]
        case "permissions.inputRequest":return CGRequestListenEventAccess()
        case "permissions.notifications":
            guard Bundle.main.bundleURL.pathExtension == "app" else { return ["granted":false] }
            let settings = await UNUserNotificationCenter.current().notificationSettings();return ["granted":[UNAuthorizationStatus.authorized,.provisional].contains(settings.authorizationStatus)]
        case "permissions.notificationsRequest":
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw BridgeFailure(code:"PACKAGED_APP_REQUIRED",message:"请在完整预览应用中请求通知权限") };return try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.badge,.sound])
        case "system.notify":
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw BridgeFailure(code:"PACKAGED_APP_REQUIRED",message:"请在完整预览应用中发送通知") }
            let content = UNMutableNotificationContent();content.title = String((p["title"] as? String ?? "Clipy").prefix(256));content.body = String((p["body"] as? String ?? "").prefix(4096));if p["sound"] as? Bool == true { content.sound = .default };try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil));return true
        case "system.hiddenIcons":return try await hiddenIcons()
        case "system.openHiddenIcon":
            guard let id = p["id"] as? String,let item = hidden[id],let app = NSRunningApplication(processIdentifier:item.pid),app.bundleIdentifier == item.bundle,item.launched != nil,app.launchDate == item.launched,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw BridgeFailure(code:"STALE_ITEM",message:"此菜单栏项目已变化，请刷新") }
            AXUIElementSetMessagingTimeout(item.element,0.4);let error = AXUIElementPerformAction(item.element,kAXPressAction as CFString);guard error == .success else { throw BridgeFailure(code:"AX_UNCONFIRMED",message:"未能确认打开原菜单，请直接使用原应用") };return true
        case "screenControl.status":return ["configured":readPassword() != nil,"locked":lockState() as Any? ?? NSNull(),"accessibility":AXIsProcessTrusted(),"scope":"current-login-session"]
        case "screenControl.configure":
            guard let password = p["password"] as? String,!password.isEmpty,password.utf8.count <= 1024 else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"请输入当前 Mac 登录密码") }
            try await Task.detached { let session = ODSession.default();let node = try ODNode(session:session,type:UInt32(kODNodeTypeAuthentication));let record = try node.record(withRecordType:kODRecordTypeUsers,name:NSUserName(),attributes:nil);try record.verifyPassword(password) }.value
            try storePassword(password);return ["configured":true]
        case "screenControl.disable":let q = passwordQuery();SecItemDelete(q as CFDictionary);return ["configured":false]
        case "screenControl.lock":
            guard readPassword() != nil else { throw BridgeFailure(code:"NOT_CONFIGURED",message:"请先配置手机控制 Mac") };guard AXIsProcessTrusted() else { throw BridgeFailure(code:"PERMISSION_DENIED",message:"锁屏需要辅助功能权限") }
            let source = CGEventSource(stateID:.combinedSessionState);let down = CGEvent(keyboardEventSource:source,virtualKey:12,keyDown:true),up = CGEvent(keyboardEventSource:source,virtualKey:12,keyDown:false);down?.flags = [.maskControl,.maskCommand];up?.flags = [.maskControl,.maskCommand];down?.post(tap:.cghidEventTap);up?.post(tap:.cghidEventTap);return ["requested":true,"confirmed":false]
        case "screenControl.unlock":return try await unlock()
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"尚未实现系统操作 \(method)")
        }
    }
    func passwordQuery() -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.clipy.tsx.experimental.screen-control",kSecAttrAccount as String:root.path] }
    func readPassword() -> String? { var q = passwordQuery();q[kSecReturnData as String] = true;var item:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&item) == errSecSuccess,let data = item as? Data else { return nil };return String(data:data,encoding:.utf8) }
    func storePassword(_ password:String) throws {
        let q = passwordQuery(),bytes = Data(password.utf8);let result = SecItemUpdate(q as CFDictionary,[kSecValueData as String:bytes] as CFDictionary)
        if result == errSecItemNotFound { var add = q;add[kSecValueData as String] = bytes;add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly;guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw BridgeFailure(code:"KEYCHAIN",message:"无法安全保存登录密码") } }
        else if result != errSecSuccess { throw BridgeFailure(code:"KEYCHAIN",message:"无法更新登录密码") }
    }
    func lockState() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any],session["kCGSSessionUserIDKey"] != nil else { return nil };return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    func locked() -> Bool { lockState() == true }
    func unlock() async throws -> [String:Any] {
        guard AXIsProcessTrusted(),locked(),let password = readPassword() else { throw BridgeFailure(code:"NOT_READY",message:"仅支持已授权且已配置的当前会话锁屏") }
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any],let uid = session["kCGSSessionUserIDKey"] as? NSNumber,uid.uint32Value == getuid(),session["kCGSSessionOnConsoleKey"] as? Bool == true else { throw BridgeFailure(code:"SESSION_MISMATCH",message:"当前登录会话不匹配") }
        guard let app = NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier == "com.apple.loginwindow"}) else { throw BridgeFailure(code:"NO_LOGIN_WINDOW",message:"未找到当前会话锁屏窗口") }
        let pid = app.processIdentifier
        let field:AXUIElement? = await Task.detached {
            let application = AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(application,0.15);let deadline = ProcessInfo.processInfo.systemUptime+2;var queue = [application],visited = 0,fields = [AXUIElement](),accountVisible = false
            while !queue.isEmpty,visited < 128,ProcessInfo.processInfo.systemUptime < deadline {
                let item = queue.removeFirst();visited += 1;var role:CFTypeRef?,subrole:CFTypeRef?
                AXUIElementCopyAttributeValue(item,kAXRoleAttribute as CFString,&role);AXUIElementCopyAttributeValue(item,kAXSubroleAttribute as CFString,&subrole)
                if subrole as? String == kAXSecureTextFieldSubrole as String { fields.append(item) }
                if role as? String == kAXStaticTextRole as String {
                    var value:CFTypeRef?;AXUIElementCopyAttributeValue(item,kAXValueAttribute as CFString,&value);if let name = value as? String,[NSUserName(),NSFullUserName()].contains(name) { accountVisible = true }
                }
                var children:CFTypeRef?;if AXUIElementCopyAttributeValue(item,kAXChildrenAttribute as CFString,&children) == .success,let items = children as? [AXUIElement] { queue.append(contentsOf:items.prefix(128-visited)) }
            };return fields.count == 1 && accountVisible ? fields[0] : nil
        }.value
        guard locked(),let field else { throw BridgeFailure(code:"SECURE_FIELD_UNAVAILABLE",message:"无法安全确认锁屏密码输入框，请在 Mac 上手动解锁") }
        guard AXUIElementSetAttributeValue(field,kAXValueAttribute as CFString,password as CFString) == .success else { throw BridgeFailure(code:"UNLOCK_DENIED",message:"系统拒绝填写锁屏密码，请手动解锁") }
        let source = CGEventSource(stateID:.combinedSessionState);CGEvent(keyboardEventSource:source,virtualKey:36,keyDown:true)?.postToPid(pid);CGEvent(keyboardEventSource:source,virtualKey:36,keyDown:false)?.postToPid(pid)
        try await Task.sleep(nanoseconds:600_000_000);return ["requested":true,"confirmed":!locked()]
    }
    func hiddenIcons() async throws -> [[String:Any]] {
        guard hiddenTask == nil else { throw BridgeFailure(code:"BUSY",message:"菜单栏项目正在刷新") }
        guard AXIsProcessTrusted() else { throw BridgeFailure(code:"PERMISSION_DENIED",message:"读取隐藏菜单栏项目需要辅助功能权限") }
        // Never AX-read this process or the NSH renderer: local AppKit getters can deadlock.
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            let path = app.executableURL?.path ?? "",id = app.bundleIdentifier ?? ""
            return app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !id.hasPrefix("dev.clipy.tsx") && !path.contains("nsh-macos") && !path.contains("Clipy TSX") && app.activationPolicy != .prohibited
        }.prefix(128).map { ($0.processIdentifier,$0.bundleIdentifier ?? "",$0.localizedName ?? "App",$0.launchDate) }
        let task = Task.detached { () -> [Finding] in
            var found:[(pid_t,String,String,Date?,AXUIElement,CGPoint,CGSize)] = [];let deadline = ProcessInfo.processInfo.systemUptime+2
            for (pid,bundle,name,date) in candidates {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { break }
                let app = AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.08);var bar:CFTypeRef?
                guard AXUIElementCopyAttributeValue(app,"AXExtrasMenuBar" as CFString,&bar) == .success,let bar,CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                var children:CFTypeRef?;guard AXUIElementCopyAttributeValue(bar as! AXUIElement,kAXChildrenAttribute as CFString,&children) == .success,let items = children as? [AXUIElement] else { continue }
                for item in items.prefix(32) {
                    if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { return found }
                    var rawPosition:CFTypeRef?,rawSize:CFTypeRef?,rawTitle:CFTypeRef?;AXUIElementCopyAttributeValue(item,kAXPositionAttribute as CFString,&rawPosition);AXUIElementCopyAttributeValue(item,kAXSizeAttribute as CFString,&rawSize)
                    guard let rawPosition,let rawSize,CFGetTypeID(rawPosition) == AXValueGetTypeID(),CFGetTypeID(rawSize) == AXValueGetTypeID() else { continue }
                    var position = CGPoint.zero,size = CGSize.zero;AXValueGetValue(rawPosition as! AXValue,.cgPoint,&position);AXValueGetValue(rawSize as! AXValue,.cgSize,&size)
                    AXUIElementCopyAttributeValue(item,kAXDescriptionAttribute as CFString,&rawTitle);found.append((pid,bundle,rawTitle as? String ?? name,date,item,position,size))
                    if found.count >= 128 { return found }
                }
            };return found
        }
        hiddenTask = task;defer { hiddenTask = nil }
        let findings = await withTaskCancellationHandler(operation:{ await task.value },onCancel:{ task.cancel() });try Task.checkCancellation()
        hidden.removeAll();var rows = [[String:Any]]();let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        for (pid,bundle,title,date,element,position,size) in findings {
            let rect = CGRect(x:position.x,y:mainTop-position.y-size.height,width:size.width,height:size.height)
            let screen = NSScreen.screens.first(where:{$0.frame.intersects(rect)})
            var covered = screen == nil || size.width <= 0 || size.height <= 0
            if let screen {
                if let left = screen.auxiliaryTopLeftArea,let right = screen.auxiliaryTopRightArea { let notch = CGRect(x:left.maxX,y:left.minY,width:max(0,right.minX-left.maxX),height:left.height);covered = covered || notch.intersects(rect) }
                let available = screen.visibleFrame;covered = covered || rect.minX < screen.frame.minX || rect.maxX > screen.frame.maxX || (rect.maxY < available.maxY && rect.maxY < screen.frame.maxY-40)
            }
            guard covered else { continue };let id = UUID().uuidString;hidden[id] = HiddenItem(pid:pid,launched:date,bundle:bundle,element:element);rows.append(["id":id,"pid":pid,"bundleId":bundle,"title":String(title.prefix(128))])
        };return rows
    }
}
