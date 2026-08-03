import AppKit
import Foundation

/// Opens the System Settings pane for a given privacy permission.
///
/// macOS 13+ uses the `com.apple.Settings.PrivacySecurity.extension?Privacy_<X>` URL
/// scheme; older OSes use the legacy `com.apple.preference.security?Privacy_<X>` form.
/// Each privacy category has its own `Privacy_` id (Accessibility, ScreenCapture,
/// InputMonitoring, Microphone, Camera). `AccessibilityManager`/`ScreenCapturePermissionManager`
/// already own their own openSettings(); this helper covers the remaining three so the
/// screenshot settings panel can deep-link every permission row uniformly.
enum PermissionDeepLink {
    static func openInputMonitoringSettings() {
        open(privacyID: "Privacy_InputMonitoring")
    }

    static func openMicrophoneSettings() {
        open(privacyID: "Privacy_Microphone")
    }

    static func openCameraSettings() {
        open(privacyID: "Privacy_Camera")
    }

    private static func open(privacyID: String) {
        let urlString: String
        if #available(macOS 13.0, *) {
            urlString = "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?\(privacyID)"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?\(privacyID)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
