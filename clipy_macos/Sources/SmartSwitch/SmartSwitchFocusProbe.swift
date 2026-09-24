import AppKit
import ApplicationServices

struct SmartSwitchFocusTarget {
    var element: AXUIElement?
    var window: AXUIElement?
    var desktop = false

    func matches(_ other: Self) -> Bool {
        if desktop || other.desktop { return desktop && other.desktop }
        guard let element, let otherElement = other.element, CFEqual(element, otherElement) else { return false }
        switch (window, other.window) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }
}

enum SmartSwitchFocusTraversal {
    static func collect<Node>(from root: Node, limit: Int = 256, maxDepth: Int = 16,
                              hasTime: () -> Bool, same: (Node, Node) -> Bool,
                              read: (Node) -> (focused: Bool, children: [Node])?) -> (nodes: [Node], complete: Bool) {
        var pending = [(root, 0)]
        var seen: [Node] = []
        var focused: [Node] = []
        var index = 0
        var complete = true
        while index < pending.count, seen.count < limit, hasTime() {
            let (node, depth) = pending[index]
            index += 1
            if seen.contains(where: { same($0, node) }) { continue }
            seen.append(node)
            guard let facts = read(node) else { complete = false; continue }
            if depth > 0, facts.focused { focused.append(node) }
            if depth >= maxDepth {
                if !facts.children.isEmpty { complete = false }
                continue
            }
            let remaining = max(0, limit - pending.count)
            if facts.children.count > remaining { complete = false }
            pending.append(contentsOf: facts.children.prefix(remaining).map { ($0, depth + 1) })
        }
        return (focused, complete && index == pending.count && hasTime())
    }
}

/// One probe shares a deadline across every IPC, fallback and property read.
/// It reads control metadata only; never AXValue, AXSelectedText or window titles.
final class SmartSwitchFocusProbe {
    typealias Inspection = SmartSwitchFocusMonitor.Inspection
    private let deadline: TimeInterval
    private var readFailed = false
    private var hasTime: Bool { ProcessInfo.processInfo.systemUptime < deadline }

    init(deadline: TimeInterval) { self.deadline = deadline }

    private func prepare(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining)))
        return true
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> (status: AXError, value: CFTypeRef?) {
        guard prepare(element) else { return (.cannotComplete, nil) }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if ![AXError.success, .noValue, .attributeUnsupported].contains(status) { readFailed = true }
        return (status, status == .success ? value : nil)
    }

    private func ownedElement(_ value: CFTypeRef?, pid: pid_t) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    func read(pid: pid_t, bundleID: String) -> Inspection {
        guard AXIsProcessTrusted() else { return Inspection(kind: .unknown, detail: "accessibilityDenied") }
        guard hasTime else { return Inspection(kind: .unknown, detail: "deadline") }
        let application = AXUIElementCreateApplication(pid)
        let manual = copy(application, "AXManualAccessibility")
        let enabled = manual.status == .success ? manual.value as? Bool : nil
        return SmartSwitchFocusMonitor.inspectFocusedAfterEnablingManualAX(enabled: enabled, enable: {
            self.prepare(application) &&
                AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        }, readFocused: {
            self.readFocused(application: application, pid: pid, bundleID: bundleID)
        })
    }

    private func readFocused(application: AXUIElement, pid: pid_t, bundleID: String) -> Inspection {
        let appFocus = copy(application, kAXFocusedUIElementAttribute)
        guard hasTime else { return Inspection(kind: .unknown, detail: "deadline") }
        let system = AXUIElementCreateSystemWide()
        var systemValue: CFTypeRef?
        // Setting a timeout on the system-wide object changes the process-wide
        // default (including other AX features). Keep this read on the bounded
        // worker; the request watchdog releases the gesture if it stalls.
        let systemStatus = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &systemValue)
        guard hasTime else { return Inspection(kind: .unknown, detail: "deadline") }
        let expectedStatuses: [AXError] = [.success, .noValue, .attributeUnsupported]
        guard expectedStatuses.contains(appFocus.status), expectedStatuses.contains(systemStatus) else {
            return Inspection(kind: .unknown, detail: "focusReadFailed appStatus=\(appFocus.status.rawValue) systemStatus=\(systemStatus.rawValue)")
        }
        if systemStatus != .success { systemValue = nil }
        let appElement = ownedElement(appFocus.value, pid: pid)
        let systemElement = ownedElement(systemValue, pid: pid)
        if (appFocus.value != nil && appElement == nil) || (systemValue != nil && systemElement == nil) {
            return Inspection(kind: .unknown, detail: "focusOwnerConflict")
        }
        if let appElement, let systemElement, !CFEqual(appElement, systemElement) {
            return Inspection(kind: .unknown, detail: "focusSourceConflict")
        }
        if let element = systemElement ?? appElement {
            let result = inspectControl(element, pid: pid, source: "direct")
            if result.kind != .unknown { return result }
        }
        let windowResult = copy(application, kAXFocusedWindowAttribute)
        // A system desktop has explicit OS evidence; arbitrary missing windows
        // in editors must remain unknown.
        if bundleID == "com.apple.finder", appFocus.status == .noValue,
           systemStatus == .noValue, windowResult.status == .noValue, hasTime {
            return Inspection(kind: .nonText, detail: "finderDesktop", target: .init(desktop: true))
        }
        if let window = ownedElement(windowResult.value, pid: pid) {
            let search = SmartSwitchFocusTraversal.collect(from: window, hasTime: { self.hasTime }, same: { CFEqual($0, $1) }, read: { element in
                guard self.ownedElement(element, pid: pid) != nil, self.prepare(element) else { return nil }
                var values: CFArray?
                let names = [kAXFocusedAttribute, kAXChildrenAttribute] as CFArray
                guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
                      let items = values as? [Any], items.count == 2 else { return nil }
                // A partial multi-read may contain AXValue(.axError) entries.
                // Treat failed focus/children reads as incomplete evidence.
                func absent(_ item: Any) -> Bool {
                    let raw = item as CFTypeRef
                    guard CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
                    let value = unsafeBitCast(raw, to: AXValue.self)
                    var error = AXError.failure
                    return AXValueGetType(value) == .axError && AXValueGetValue(value, .axError, &error) &&
                        (error == .attributeUnsupported || error == .noValue)
                }
                guard items[0] is Bool || absent(items[0]) else { return nil }
                let focused = items[0] as? Bool == true
                if let children = items[1] as? [AXUIElement] { return (focused, children) }
                if absent(items[1]) { return (focused, []) }
                return nil
            })
            if search.nodes.count > 1 { return Inspection(kind: .unknown, detail: "ambiguousDescendantFocus") }
            if let element = search.nodes.first {
                guard ownedElement(element, pid: pid) != nil else { return Inspection(kind: .unknown, detail: "descendantOwnerConflict") }
                let result = inspectControl(element, pid: pid, source: "windowFocused")
                if result.kind == .textInput || search.complete { return result }
            }
        }
        return Inspection(kind: .unknown, detail: hasTime ? "focusUnresolved appStatus=\(appFocus.status.rawValue) systemStatus=\(systemStatus.rawValue)" : "deadline",
                          retryAfterWarmup: hasTime)
    }

    private func inspectControl(_ element: AXUIElement, pid: pid_t, source: String) -> Inspection {
        guard let role = copy(element, kAXRoleAttribute).value as? String else { return Inspection(kind: .unknown, detail: "missingRole") }
        func writable(_ name: String) -> Bool {
            guard prepare(element) else { return false }
            var value = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, name as CFString, &value)
            if ![AXError.success, .noValue, .attributeUnsupported].contains(status) { readFailed = true }
            return status == .success && value.boolValue
        }
        let facts = SmartSwitchFocusFacts(role: role, subrole: copy(element, kAXSubroleAttribute).value as? String,
            hasTextSelection: copy(element, kAXSelectedTextRangeAttribute).value != nil,
            selectedTextIsWritable: writable(kAXSelectedTextAttribute), valueIsWritable: writable(kAXValueAttribute),
            editable: copy(element, "AXEditable").value as? Bool, readSucceeded: true)
        let windowValue = copy(element, kAXWindowAttribute).value
        let window = ownedElement(windowValue, pid: pid)
        guard hasTime else { return Inspection(kind: .unknown, detail: "deadline") }
        guard !readFailed else { return Inspection(kind: .unknown, detail: "controlReadFailed") }
        guard windowValue == nil || window != nil else { return Inspection(kind: .unknown, detail: "windowOwnerConflict") }
        return Inspection(kind: facts.kind,
            detail: "role=\(role) selection=\(facts.hasTextSelection) selectedWritable=\(facts.selectedTextIsWritable) valueWritable=\(facts.valueIsWritable) editable=\(facts.editable.map(String.init) ?? "unknown") source=\(source)",
            target: SmartSwitchFocusTarget(element: element, window: window))
    }
}
