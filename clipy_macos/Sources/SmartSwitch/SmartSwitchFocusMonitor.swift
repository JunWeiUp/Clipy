import AppKit
import ApplicationServices
import Carbon

/// Event-driven, metadata-only Accessibility inspection. Focus reads run off
/// the event tap/main thread, with bounded messaging timeouts.
final class SmartSwitchFocusMonitor {
    struct Inspection {
        let kind: SmartSwitchFocusKind
        let detail: String
        var retryAfterWarmup = false
    }
    typealias Reader = (pid_t, String) -> Inspection
    struct Snapshot {
        let pid: pid_t
        let kind: SmartSwitchFocusKind
        let observedAt: TimeInterval
        let detail: String
        var bundleID = ""

        var shouldOpenSwitch: Bool {
            // An unresolved Electron editor may still own a live composition.
            // In ZCode require positive non-text evidence before taking over.
            kind.shouldOpenSwitch && !(bundleID == "dev.zcode.app" && kind == .unknown)
        }
    }
    private(set) var snapshot: Snapshot?
    private let queue = DispatchQueue(label: "Clipy.smart-switch-focus", qos: .userInitiated)
    private let reader: Reader
    private var activationObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var reliableObserver = false
    private var revision = 0
    private var reading = false
    private var isRunning = false
    private var reportedFocus: (pid: pid_t, kind: SmartSwitchFocusKind)?

    init(reader: @escaping Reader = SmartSwitchFocusMonitor.read) {
        self.reader = reader
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.followFrontmostApp() }
        followFrontmostApp()
    }

    func stop() {
        isRunning = false
        revision += 1
        snapshot = nil
        reportedFocus = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        removeAXObserver()
    }

    private func removeAXObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        reliableObserver = false
    }

    private func followFrontmostApp() {
        guard isRunning else { return }
        removeAXObserver()
        guard let app = NSWorkspace.shared.frontmostApplication else { invalidate(); return }
        var created: AXObserver?
        if AXObserverCreate(app.processIdentifier, { _, _, _, context in
            guard let context else { return }
            Unmanaged<SmartSwitchFocusMonitor>.fromOpaque(context).takeUnretainedValue().invalidate()
        }, &created) == .success, let created {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.06)
            let context = Unmanaged.passUnretained(self).toOpaque()
            reliableObserver = AXObserverAddNotification(created, element, kAXFocusedUIElementChangedNotification as CFString, context) == .success
            AXObserverAddNotification(created, element, kAXFocusedWindowChangedNotification as CFString, context)
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        invalidate()
    }

    var diagnosticSummary: String {
        guard let snapshot else { return "focus=pending" }
        let age = Int((ProcessInfo.processInfo.systemUptime - snapshot.observedAt) * 1000)
        return "focus=\(snapshot.kind) \(snapshot.detail) ageMs=\(age) observer=\(reliableObserver) pid=\(snapshot.pid)"
    }

    func invalidate() {
        snapshot = nil
        revision += 1
        refresh()
    }

    private func refresh() {
        guard isRunning, !reading, let app = NSWorkspace.shared.frontmostApplication else { return }
        reading = true
        let ticket = revision
        inspect(app) { [weak self] result in
            guard let self else { return }
            self.reading = false
            guard self.isRunning else { return }
            if ticket == self.revision {
                self.snapshot = result
                if self.reportedFocus?.pid != result.pid || self.reportedFocus?.kind != result.kind {
                    self.reportedFocus = (result.pid, result.kind)
                    appLog("SmartVoice focus changed pid=\(result.pid) kind=\(result.kind) \(result.detail)", level: .debug)
                }
            }
            else { self.refresh() }
        }
    }

    func recheck(_ completion: @escaping (Snapshot) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            completion(Snapshot(pid: 0, kind: .unknown, observedAt: 0, detail: "noFrontApp")); return
        }
        inspect(app, completion: completion)
    }

    private func inspect(_ app: NSRunningApplication, completion: @escaping (Snapshot) -> Void) {
        inspect(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", completion: completion)
    }

    func inspect(pid: pid_t, bundleID: String, completion: @escaping (Snapshot) -> Void) {
        inspect(pid: pid, bundleID: bundleID, retries: 2, completion: completion)
    }

    private func inspect(pid: pid_t, bundleID: String, retries: Int, completion: @escaping (Snapshot) -> Void) {
        queue.async { [self] in
            let inspection = reader(pid, bundleID)
            if inspection.retryAfterWarmup, retries > 0 {
                // Electron builds its AX tree asynchronously. Retry only this
                // event's read, with a strict bound; never poll while idle.
                queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                    inspect(pid: pid, bundleID: bundleID, retries: retries - 1, completion: completion)
                }
                return
            }
            let result = Snapshot(pid: pid, kind: inspection.kind, observedAt: ProcessInfo.processInfo.systemUptime,
                                  detail: inspection.detail, bundleID: bundleID)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func read(pid: pid_t, bundleID: String) -> Inspection {
        guard AXIsProcessTrusted() else { return Inspection(kind: .unknown, detail: "accessibilityDenied") }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.06)
        // Detect Electron support by its capability, not by an application list.
        // https://www.electronjs.org/docs/latest/tutorial/accessibility#macos
        var enabled: CFTypeRef?
        let manualStatus = AXUIElementCopyAttributeValue(application, "AXManualAccessibility" as CFString, &enabled)
        let supportsManualAX = manualStatus == .success && (enabled as? Bool) != nil
        return inspectFocusedAfterEnablingManualAX(enabled: supportsManualAX ? enabled as? Bool : nil, enable: {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        }, readFocused: {
            readFocusedElement(application: application, pid: pid, bundleID: bundleID, supportsManualAX: supportsManualAX)
        })
    }

    /// Some Electron builds keep reporting AXManualAccessibility=false even when
    /// their text controls are accessible. Enabling it must never bypass the read.
    static func inspectFocusedAfterEnablingManualAX(enabled: Bool?, enable: () -> Bool,
                                                    readFocused: () -> Inspection) -> Inspection {
        let requestedWarmup = enabled == false && enable()
        var result = readFocused()
        if requestedWarmup, result.kind == .unknown { result.retryAfterWarmup = true }
        return result
    }

    private static func readFocusedElement(application: AXUIElement, pid: pid_t, bundleID: String,
                                           supportsManualAX: Bool) -> Inspection {
        var focused: CFTypeRef?
        var focusedStatus = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        // The system-wide focus can point to the real Electron text control when
        // the app-level attribute is still a container. Never inspect another app.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.06)
        var systemFocused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &systemFocused) == .success,
           let systemFocused, CFGetTypeID(systemFocused) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(systemFocused, to: AXUIElement.self)
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success, owner == pid {
                focused = systemFocused
                focusedStatus = .success
            }
        }
        if focusedStatus == .noValue, bundleID == "com.apple.finder" {
            var window: CFTypeRef?
            // Finder with neither a focused element nor a window is the desktop.
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .noValue {
                return Inspection(kind: .nonText, detail: "finderDesktop")
            }
        }
        guard focusedStatus == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return Inspection(kind: .unknown, detail: "focusedStatus=\(focusedStatus.rawValue)",
                              retryAfterWarmup: focusedStatus == .cannotComplete || (supportsManualAX && focusedStatus == .noValue))
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.06)
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let role = attribute(kAXRoleAttribute) as? String else { return Inspection(kind: .unknown, detail: "missingRole") }
        var writable = DarwinBoolean(false)
        let writableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)
        var selectedWritable = DarwinBoolean(false)
        let selectedWritableStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedWritable)
        let selectedRange = attribute(kAXSelectedTextRangeAttribute)
        let facts = SmartSwitchFocusFacts(role: role, subrole: attribute(kAXSubroleAttribute) as? String,
            hasTextSelection: selectedRange != nil,
            selectedTextIsWritable: selectedWritableStatus == .success && selectedWritable.boolValue,
            valueIsWritable: writableStatus == .success && writable.boolValue,
            editable: attribute("AXEditable") as? Bool,
            readSucceeded: true)
        return Inspection(kind: facts.kind, detail: "role=\(role) selection=\(facts.hasTextSelection) selectedWritable=\(facts.selectedTextIsWritable) valueWritable=\(facts.valueIsWritable) editable=\(facts.editable.map(String.init) ?? "unknown")")
    }
}
