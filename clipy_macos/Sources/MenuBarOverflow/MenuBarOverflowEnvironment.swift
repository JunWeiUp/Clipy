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
                  if geometries().isEmpty { return .unsupportedDisplay }
                  if !AXIsProcessTrusted() { return .needsPermission }
                  return nil
              }, context: {
                  let bars = geometries()
                  guard let geometry = bars.first else { return nil }
                  let apps = NSWorkspace.shared.runningApplications.compactMap { app -> MenuBarOverflowApplication? in
                      guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                            !app.isTerminated, let launched = MenuBarOverflowProcessIdentity.launchDate(for: app.processIdentifier) else { return nil }
                      return .init(pid: app.processIdentifier, launchDate: launched,
                                   name: app.localizedName ?? app.bundleIdentifier ?? "Application",
                                   icon: nil, isControlCenter: app.bundleIdentifier == "com.apple.controlcenter")
                  }
                  return .init(geometry: geometry, geometries: bars, applications: apps,
                               frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
              }, monitorInput: { cancellation in
                  NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { _ in
                      cancellation.cancel()
                  }
              })
    }

    /// Every attached display keeps its own menu bar. Mirroring still reports one screen.
    static func geometries() -> [MenuBarOverflowGeometry] {
        NSScreen.screens.compactMap(geometry(for:))
    }

    private static func geometry(for screen: NSScreen) -> MenuBarOverflowGeometry? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let bounds = CGDisplayBounds(number.uint32Value)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return .init(screen: bounds, barHeight: max(24, screen.safeAreaInsets.top + 1),
                     rightAreaMinX: screen.auxiliaryTopRightArea?.minX ?? bounds.minX)
    }
}
