import AppKit

enum MemoryFootprintReclaimer {
    static func registerIdleHandlers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            reclaimIfIdle()
        }
        center.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            reclaimIfIdle()
        }
    }

    static func reclaimIfIdle() {
        guard !hasVisibleInteractiveWindows() else { return }
        ClipboardManager.shared.releaseMenuMemory()
    }

    private static func hasVisibleInteractiveWindows() -> Bool {
        for window in NSApp.windows where window.isVisible {
            if window is NSPanel { continue }
            if NSStringFromClass(type(of: window)).contains("StatusBar") { continue }
            return true
        }
        return false
    }
}
