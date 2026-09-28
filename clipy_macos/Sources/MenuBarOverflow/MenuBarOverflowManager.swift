import AppKit
import Combine
import Carbon

/// Main-thread state, one bounded worker, no mouse events, reordering or clipboard access.
final class MenuBarOverflowManager: ObservableObject {
    static let shared = MenuBarOverflowManager()
    @Published private(set) var enabled: Bool
    @Published private(set) var status: MenuBarOverflowStatus = .disabled
    @Published private(set) var items: [MenuBarOverflowItem] = []
    private let provider: MenuBarOverflowProviding
    private let environment: MenuBarOverflowEnvironment
    private let images = MenuBarOverflowImages()
    private let queue = DispatchQueue(label: "clipy.menu-bar-overflow", qos: .utility)
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var scanCancellation: MenuBarOverflowCancellation?
    private var actionCancellation: MenuBarOverflowCancellation?
    private var scanning = false
    private var revision: UInt64 = 0
    private var started = false
    private var suspended = false
    private var inputMonitor: Any?
    private var wantsOriginalIcons = false
    private var presentationActive = false
    private var lastDiagnostic: String?

    init(provider: MenuBarOverflowProviding = MenuBarItemProvider(), environment: MenuBarOverflowEnvironment = .live) {
        self.provider = provider
        self.environment = environment
        enabled = environment.loadEnabled()
    }

    func start() {
        guard !started else { return }
        started = true
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.invalidate(); $0.refresh() }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { $0.refresh() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { $0.workspaceDidChange() }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.setSuspended(true) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.setSuspended(false) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.setSuspended(true) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.setSuspended(false) }
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (MenuBarOverflowManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { action(self) }
        }
        observers.append((center, token))
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        environment.saveEnabled(value)
        invalidate()
        refresh()
    }

    private func setSuspended(_ value: Bool) { suspended = value; invalidate(); refresh() }

    func workspaceDidChange() {
        // Opening a status menu can itself change the active app. Keep the last
        // useful snapshot until the replacement arrives; otherwise every open
        // can render a loading row instead of the icons discovered while idle.
        invalidate(clearItems: false)
        refresh()
    }

    private func invalidate(clearItems: Bool = true) {
        revision &+= 1
        scanCancellation?.cancel()
        actionCancellation?.cancel()
        stopInputMonitor()
        actionCancellation = nil
        if clearItems {
            wantsOriginalIcons = false
            items = []
        }
    }

    private func unavailableStatus() -> MenuBarOverflowStatus? {
        if !enabled { return .disabled }
        if suspended { return .suspended }
        return environment.availability()
    }

    func refreshForMenu() {
        presentationActive = true
        wantsOriginalIcons = true
        refresh()
    }

    /// Keep the visible strip fresh, but stop AX polling and pending image
    /// capture as soon as the menu/panel closes. Workspace and display events
    /// still refresh metadata while idle; the next open requests a fresh scan.
    func endMenuPresentation() {
        dispatchPrecondition(condition: .onQueue(.main))
        presentationActive = false
        wantsOriginalIcons = false
        timer?.invalidate()
        timer = nil
        scanCancellation?.cancel()
    }

    func recordMenuPresentation() {
        LogManager.shared.log("MenuBarOverflow pid=\(ProcessInfo.processInfo.processIdentifier) menu enabled=\(enabled) status=\(status) items=\(items.count)", level: .debug)
    }

    private func recordDiagnostic() {
        let diagnostic = "MenuBarOverflow pid=\(ProcessInfo.processInfo.processIdentifier) state=\(status) items=\(items.count)"
        guard diagnostic != lastDiagnostic else { return }
        lastDiagnostic = diagnostic
        LogManager.shared.log(diagnostic, level: .debug)
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let unavailable = unavailableStatus() {
            invalidate(); status = unavailable
            timer?.invalidate(); timer = nil
            recordDiagnostic()
            return
        }
        if presentationActive && timer == nil {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        guard !scanning, actionCancellation == nil, let context = environment.context() else { return }
        let cancellation = MenuBarOverflowCancellation()
        scanCancellation?.cancel()
        revision &+= 1
        scanCancellation = cancellation
        let capturedRevision = revision
        scanning = true
        if items.isEmpty { status = .loading }
        queue.async { [weak self, provider] in
            let found = provider.scan(context, cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard !cancellation.isCancelled, self.revision == capturedRevision else {
                    if self.enabled { self.refresh() }
                    return
                }
                guard self.unavailableStatus() == nil else { self.refresh(); return }
                // Resolve fallback images only for hidden entries, not every running application.
                let previousImages = Dictionary(uniqueKeysWithValues: self.items.compactMap { item in
                    item.image.map { (item.id, $0) }
                })
                self.items = found.items.map { item in
                    var item = item
                    if item.image == nil {
                        item.image = previousImages[item.id] ?? NSRunningApplication(processIdentifier: item.id.pid)?.icon
                    }
                    return item
                }
                self.status = found.isComplete ? .ready : .partial
                self.recordDiagnostic()
                // Idle refreshes enumerate metadata only. Do not run ScreenCaptureKit
                // every 15 seconds while the main menu is closed.
                guard self.wantsOriginalIcons else { return }
                self.wantsOriginalIcons = false
                self.images.load(found.items, cancellation: cancellation) { [weak self] icons in
                    guard let self, self.revision == capturedRevision, !cancellation.isCancelled else { return }
                    self.items = self.items.map { item in
                        var item = item
                        if let image = icons[item.id] { item.image = image }
                        return item
                    }
                }
            }
        }
    }

    /// Called after NSMenu tracking has ended. AX success means an action was accepted,
    /// not proof that every third-party app has shown a visible popup.
    func activate(_ item: MenuBarOverflowItem, completion: @escaping (MenuBarOverflowActivationResult) -> Void) {
        guard actionCancellation == nil else { return }
        guard unavailableStatus() == nil, item.canPress else { completion(.unavailable); return }
        scanCancellation?.cancel()
        let cancellation = MenuBarOverflowCancellation()
        actionCancellation = cancellation
        status = .activating
        let capturedRevision = revision
        inputMonitor = environment.monitorInput(cancellation)
        queue.async { [weak self, provider] in
            let result = provider.press(item, cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self, self.revision == capturedRevision else { return }
                self.stopInputMonitor()
                self.actionCancellation = nil
                if cancellation.isCancelled { self.status = .ready; completion(.cancelled); return }
                self.status = result == .unavailable ? .failed : (result == .unconfirmed ? .unconfirmed : .ready)
                completion(result)
            }
        }
    }

    private func stopInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
    }

    deinit {
        timer?.invalidate()
        scanCancellation?.cancel(); actionCancellation?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        for (center, token) in observers { center.removeObserver(token) }
    }

    #if CLIPY_CORE_TESTS
    var hasRefreshTimer: Bool { timer != nil }
    #endif
}
