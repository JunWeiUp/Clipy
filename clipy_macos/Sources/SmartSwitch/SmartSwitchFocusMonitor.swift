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
        var target: SmartSwitchFocusTarget?
    }
    typealias Reader = (pid_t, String, TimeInterval) -> Inspection
    struct Snapshot {
        let pid: pid_t
        let kind: SmartSwitchFocusKind
        let observedAt: TimeInterval
        let detail: String
        var bundleID = ""

        var target: SmartSwitchFocusTarget?
        var shouldOpenSwitch: Bool { kind.shouldOpenSwitch }

        func matchesTarget(_ other: Snapshot) -> Bool {
            guard pid == other.pid, let target, let otherTarget = other.target else { return false }
            return target.matches(otherTarget)
        }
    }
    private(set) var snapshot: Snapshot?
    private let queue = DispatchQueue(label: "Clipy.smart-switch-focus", qos: .userInitiated)
    private let reader: Reader
    private let requestTimeout: TimeInterval
    private let readSlots = DispatchSemaphore(value: 2)
    private var activationObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var reliableObserver = false
    private var revision = 0
    private var reading = false
    private var isRunning = false
    private var reportedFocus: (pid: pid_t, kind: SmartSwitchFocusKind)?

    init(requestTimeout: TimeInterval = 0.15, reader: @escaping Reader = SmartSwitchFocusMonitor.read) {
        self.reader = reader
        self.requestTimeout = requestTimeout
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
        if BackgroundAccessibilityPolicy.canRead(pid: app.processIdentifier), AXObserverCreate(app.processIdentifier, { _, _, _, context in
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
        // Exclude self before entering the worker, acquiring slots or issuing AX.
        // Our input panel's keyboard focus is tracked directly by AppKit.
        guard BackgroundAccessibilityPolicy.canRead(pid: pid) else {
            DispatchQueue.main.async {
                completion(Snapshot(pid: pid, kind: .unknown,
                    observedAt: ProcessInfo.processInfo.systemUptime,
                    detail: "localProcessExcluded", bundleID: bundleID))
            }
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
        let request = SmartSwitchFocusRequest(deadline: deadline)
        func deliver(_ result: Inspection) {
            DispatchQueue.main.async {
                guard request.finish() else { return }
                let result = request.expired ? Inspection(kind: .unknown, detail: "deadline") : result
                completion(Snapshot(pid: pid, kind: result.kind, observedAt: ProcessInfo.processInfo.systemUptime,
                                    detail: result.detail, bundleID: bundleID, target: result.target))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            deliver(Inspection(kind: .unknown, detail: "deadline"))
        }
        guard readSlots.wait(timeout: .now()) == .success else {
            deliver(Inspection(kind: .unknown, detail: "probeBusy")); return
        }
        func attempt(_ retries: Int) {
            queue.async { [self] in
                guard request.isActive else { readSlots.signal(); return }
                let result = reader(pid, bundleID, deadline)
                if result.retryAfterWarmup, retries > 0, request.isActive {
                    queue.asyncAfter(deadline: .now() + 0.035) { attempt(retries - 1) }
                } else {
                    readSlots.signal()
                    deliver(result)
                }
            }
        }
        attempt(2)
    }

    static func read(pid: pid_t, bundleID: String, deadline: TimeInterval) -> Inspection {
        SmartSwitchFocusProbe(deadline: deadline).read(pid: pid, bundleID: bundleID)
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

}

private final class SmartSwitchFocusRequest {
    let deadline: TimeInterval
    private let lock = NSLock()
    private var completed = false

    init(deadline: TimeInterval) { self.deadline = deadline }
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !completed && !expired
    }
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
