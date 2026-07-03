import AppKit
import CoreGraphics

enum ScreenCapturePermissionManager {
    private static var isShowingAlert = false

    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

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

    @discardableResult
    static func ensureAccess() -> Bool {
        if isAuthorized { return true }
        // 仅检测状态，不自动调用 CGRequestScreenCaptureAccess()，避免每次启动/截图都弹系统授权框。
        // 未授权时引导用户去系统设置手动开启（权限与 Bundle ID + 代码签名绑定，重编译未签名会失效）。
        showPermissionAlert()
        return false
    }

    private static func showPermissionAlert() {
        guard !isShowingAlert else { return }
        isShowingAlert = true

        DispatchQueue.main.async {
            defer { isShowingAlert = false }

            let alert = NSAlert()
            alert.messageText = L10n.t(.screenCaptureRequiredTitle)
            alert.informativeText = L10n.t(.screenCaptureRequiredMessage)
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.t(.openSystemSettings))
            alert.addButton(withTitle: L10n.t(.cancel))

            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
        }
    }
}
