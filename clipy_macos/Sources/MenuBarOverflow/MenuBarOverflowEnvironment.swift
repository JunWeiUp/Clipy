import AppKit
import Carbon

/// System reads are isolated so lifecycle races can be tested without changing user defaults,
/// requesting permissions, opening real menus, or depending on the test runner's monitors.
struct MenuBarOverflowEnvironment {
    var loadEnabled: () -> Bool
    var saveEnabled: (Bool) -> Void
    var availability: () -> MenuBarOverflowStatus?
    var context: () -> MenuBarOverflowContext?
    var monitorInput: (MenuBarOverflowCancellation) -> Any?

    static var live: MenuBarOverflowEnvironment {
        .init(loadEnabled: { PreferencesManager.shared.menuBarOverflowEnabled },
              saveEnabled: { PreferencesManager.shared.menuBarOverflowEnabled = $0 },
              availability: {
                  if IsSecureEventInputEnabled() { return .suspended }
                  if geometry() == nil { return .unsupportedDisplay }
                  if !AXIsProcessTrusted() { return .needsPermission }
                  return nil
              }, context: {
                  guard let geometry = geometry() else { return nil }
                  let apps = NSWorkspace.shared.runningApplications.compactMap { app -> MenuBarOverflowApplication? in
                      guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                            !app.isTerminated, let launched = MenuBarOverflowProcessIdentity.launchDate(for: app.processIdentifier) else { return nil }
                      return .init(pid: app.processIdentifier, launchDate: launched,
                                   name: app.localizedName ?? app.bundleIdentifier ?? "Application",
                                   icon: nil, isControlCenter: app.bundleIdentifier == "com.apple.controlcenter")
                  }
                  return .init(geometry: geometry, applications: apps,
                               frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
              }, monitorInput: { cancellation in
                  NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { _ in
                      cancellation.cancel()
                  }
              })
    }

    static func supportsDisplays(screenCount: Int, onlineDisplayCount: Int, builtIn: Bool) -> Bool {
        screenCount == 1 && onlineDisplayCount == 1 && builtIn
    }

    private static func geometry() -> MenuBarOverflowGeometry? {
        var onlineCount: UInt32 = 0
        guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGGetOnlineDisplayList(0, nil, &onlineCount) == .success,
              supportsDisplays(screenCount: NSScreen.screens.count, onlineDisplayCount: Int(onlineCount),
                               builtIn: CGDisplayIsBuiltin(number.uint32Value) != 0) else { return nil }
        let bounds = CGDisplayBounds(number.uint32Value)
        return .init(screen: bounds, barHeight: max(24, screen.safeAreaInsets.top + 1),
                     rightAreaMinX: screen.auxiliaryTopRightArea?.minX ?? bounds.minX)
    }
}
