import AppKit
import CoreGraphics

enum ScreenCapturePermissionManager {
    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗；仅应在用户主动点击「请求权限」时调用。
    @discardableResult
    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        let urlString: String
        if #available(macOS 13.0, *) {
            urlString = "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 仅检测权限状态，不弹窗。未授权时由设置页展示状态，截图操作静默失败。
    @discardableResult
    static func ensureAccess() -> Bool {
        isAuthorized
    }
}
