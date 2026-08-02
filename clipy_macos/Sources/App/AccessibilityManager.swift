import AppKit
import ApplicationServices

enum AccessibilityManager {
    private static var isShowingAlert = false

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestSystemPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let urlString: String
        if #available(macOS 13.0, *) {
            urlString = "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies can still succeed; paste simulation requires Accessibility permission.
    @discardableResult
    static func ensureTrustedForPaste() -> Bool {
        guard !isTrusted else { return true }
        showPastePermissionAlert()
        return false
    }

    static func showPermissionAlertIfNeeded() {
        guard !isTrusted else { return }
        showPastePermissionAlert()
    }

    private static func showPastePermissionAlert() {
        guard !isShowingAlert else { return }
        isShowingAlert = true

        DispatchQueue.main.async {
            defer { isShowingAlert = false }

            let alert = NSAlert()
            alert.messageText = L10n.t(.accessibilityRequiredTitle)
            alert.informativeText = L10n.t(.accessibilityRequiredMessage)
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.t(.openSystemSettings))
            alert.addButton(withTitle: L10n.t(.cancel))

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                requestSystemPrompt()
                openSettings()
            }
        }
    }
}
