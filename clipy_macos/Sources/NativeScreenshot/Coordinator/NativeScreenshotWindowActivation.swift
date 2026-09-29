import AppKit

/// Keeps the menu-bar app's temporary Dock activation balanced across windows.
@MainActor
enum NativeScreenshotWindowActivation {
    private static var owners: Set<UUID> = []

    static func opened(_ id: UUID) {
        owners.insert(id)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed(_ id: UUID) {
        owners.remove(id)
        if owners.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
