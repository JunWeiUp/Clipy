import AppKit
import ApplicationServices
import Carbon

final class MenuBarItemProvider: MenuBarOverflowProviding {
    private let bridge = MenuBarSystemBridge()

    private final class Reader {
        let cancellation: MenuBarOverflowCancellation
        let deadline: TimeInterval
        private(set) var hadTimeout = false
        init(_ cancellation: MenuBarOverflowCancellation, seconds: TimeInterval) {
            self.cancellation = cancellation
            deadline = ProcessInfo.processInfo.systemUptime + seconds
        }
        var available: Bool { !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard available else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.04)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if result == .cannotComplete || result == .apiDisabled { hadTimeout = true }
            guard result == .success else { return nil }
            return value
        }
        func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
            guard let value = value(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            Array((value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(128))
        }
    }

    func scan(_ context: MenuBarOverflowContext, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowScan {
        guard AXIsProcessTrusted() else { return .init(items: [], isComplete: false) }
        let reader = Reader(cancellation, seconds: 2)
        let windows = bridge.windows()
        var applicationMenuMaxX: CGFloat?
        if let pid = context.frontPID,
           let bar = reader.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) {
            let edges = reader.children(bar).compactMap { reader.frame($0) }.filter {
                abs($0.minY - context.geometry.screen.minY) <= context.geometry.barHeight
            }.map(\.maxX)
            applicationMenuMaxX = edges.max()
        }
        var results: [MenuBarOverflowItem] = []
        // Prefer real source applications over the duplicate hosted Control Center elements.
        for application in context.applications.sorted(by: { !$0.isControlCenter && $1.isControlCenter }) {
            guard reader.available else { break }
            let app = AXUIElementCreateApplication(application.pid)
            guard let bar = reader.element(app, "AXExtrasMenuBar") else { continue }
            for (ordinal, element) in reader.children(bar).enumerated() {
                guard reader.available, let frame = reader.frame(element) else { continue }
                let window = MenuBarSystemBridge.matchedWindow(for: frame, in: windows)
                // AX describes the inner button. On a notched display, its hosting
                // window can already be hidden while the inner button still fits.
                guard context.geometry.isOverflow(window?.frame ?? frame, applicationMenuMaxX: applicationMenuMaxX) else { continue }
                let windowID = window?.id
                if let windowID, results.contains(where: { $0.id.windowID == windowID }) { continue }
                let title = (reader.value(element, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let description = (reader.value(element, kAXDescriptionAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = !title.isEmpty ? title : description
                let name = label.isEmpty ? application.name : "\(application.name) — \(label.prefix(100))"
                var actions: CFArray?
                let hasActions = reader.available && AXUIElementCopyActionNames(element, &actions) == .success
                let canPress = hasActions && (actions as? [String] ?? []).contains(kAXPressAction)
                results.append(MenuBarOverflowItem(
                    id: .init(pid: application.pid, launchDate: application.launchDate, windowID: windowID, ordinal: ordinal),
                    title: name, frame: frame, element: element, canPress: canPress, image: application.icon))
            }
        }
        let sorted = results.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.id.pid < $1.id.pid
        }
        return MenuBarOverflowScan(items: sorted, isComplete: reader.available && !reader.hadTimeout)
    }

    func press(_ item: MenuBarOverflowItem, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowActivationResult {
        guard !cancellation.isCancelled else { return .cancelled }
        guard item.canPress, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let application = NSRunningApplication(processIdentifier: item.id.pid),
              !application.isTerminated, MenuBarOverflowProcessIdentity.launchDate(for: item.id.pid) == item.id.launchDate else { return .unavailable }
        let reader = Reader(cancellation, seconds: 0.5)
        guard let bar = reader.element(AXUIElementCreateApplication(item.id.pid), "AXExtrasMenuBar"),
              let target = reader.children(bar).first(where: { CFEqual($0, item.element) }),
              let frame = reader.frame(target), frame.width > 0, frame.height > 0 else { return .unavailable }
        // Do not replace a stale element by an ordinal, a nearby coordinate, or an app launch.
        if let windowID = item.id.windowID,
           MenuBarSystemBridge.window(for: frame, in: bridge.windows()) != windowID { return .unavailable }
        guard reader.available, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return .cancelled }
        AXUIElementSetMessagingTimeout(target, 0.3)
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if result == .success { return .requested }
        // Some native menus keep the AX request pending until tracking ends. A timeout
        // is an unknown result, not permission to retry or show a modal over that menu.
        if result == .cannotComplete { return .unconfirmed }
        return .unavailable
    }
}
