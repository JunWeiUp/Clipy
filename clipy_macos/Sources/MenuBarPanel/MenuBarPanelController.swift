import AppKit
import Combine
import SwiftUI

/// A menu-bar surface can receive search input without taking the caller's app focus.
final class MenuBarControlPanel: EscapeClosingPanel {
    var menuDepth = 0
    var command: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { menuDepth == 0 }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           (firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
           menuDepth == 0, command?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if menuDepth == 0, command?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class MenuBarPanelController: NSObject, NSWindowDelegate {
    let model = MenuBarPanelModel()
    private var panel: MenuBarControlPanel?
    private weak var anchor: NSStatusBarButton?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var snapshotsPending = false
    private var historyPending = false
    private var resizePending = false
    private var sizeObservers: [AnyCancellable] = []
    private var generation: UInt64 = 0
    private var previousApp: NSRunningApplication?
    var onAction: ((MenuBarPanelModel.Action) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        model.onAction = { [weak self] action in self?.handoff(action) }
        model.onHistory = { [weak self] entry, action in self?.use(entry, action: action) }
        model.onSnippet = { [weak self] id in
            guard let self, let snippet = SnippetManager.shared.snippet(id: id) else { return }
            self.use(HistoryEntry(item: .text(snippet.content), date: Date(), sourceApp: nil, contentHash: nil), action: .use, reorder: false)
        }
        model.onClose = { [weak self] in self?.dismiss() }
        sizeObservers = [
            model.$page.sink { [weak self] _ in self?.scheduleResize() },
            model.$tab.sink { [weak self] _ in self?.scheduleResize() },
            model.$devices.sink { [weak self] _ in self?.scheduleResize() }
        ]
        observe(NotificationCenter.default, NSMenu.didBeginTrackingNotification) { $0.panel?.menuDepth += 1 }
        observe(NotificationCenter.default, NSMenu.didEndTrackingNotification) { owner in
            owner.panel?.menuDepth = max(0, (owner.panel?.menuDepth ?? 0) - 1)
            DispatchQueue.main.async { [weak owner] in
                guard let owner, owner.isVisible, owner.panel?.menuDepth == 0 else { return }
                if owner.historyPending { owner.historyPending = false; owner.refreshHistory() }
                if owner.snapshotsPending { owner.snapshotsPending = false; owner.refreshSnapshots() }
            }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.dismiss() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.dismiss() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.dismiss() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { owner in
            if owner.isVisible && !owner.model.pinned && owner.panel?.isKeyWindow != true { owner.dismiss() }
        }
    }
    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping (MenuBarPanelController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { action(self) }
        }
        observers.append((center, token))
    }
    func toggle(from button: NSStatusBarButton) { isVisible ? dismiss() : show(from: button) }
    func show(from button: NSStatusBarButton) {
        if isVisible { panel?.makeKeyAndOrderFront(nil); return }
        guard let buttonWindow = button.window else { return }
        generation &+= 1
        previousApp = NSWorkspace.shared.frontmostApplication
        anchor = button
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        guard let screen else { return }
        let frame = MenuBarPanelPolicy.frame(anchor: rect, visible: screen.visibleFrame,
                                            preferred: MenuBarPanelPolicy.preferredSize(page: .home, tab: .clipboard))
        let window = panel ?? makePanel()
        panel = window
        ClipboardManager.shared.refreshFromPasteboardIfNeeded()
        ClipboardManager.shared.ensureMenuSummariesLoaded()
        model.begin()
        TokenUsageManager.shared.refreshIfStale()
        updateSnapshots()
        let root = MenuBarPanelView(model: model, overflow: MenuBarOverflowManager.shared) { [weak self] entry in
            self?.activate(entry)
        }.environmentObject(AppLanguageObserver.shared)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        window.contentViewController = host
        window.setFrame(frame, display: false)
        window.makeKeyAndOrderFront(nil)
        // Never activate Clipy here: its caller remains the paste target.
        onVisibilityChanged?(true)
        installInputMonitors()
        MenuBarOverflowManager.shared.refreshForMenu()
        MenuBarOverflowManager.shared.recordMenuPresentation()
        SyncManager.shared.triggerCrossBandDiscovery()
    }
    private func scheduleResize() {
        guard isVisible, !resizePending else { return }
        resizePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizePending = false
            guard self.isVisible, let button = self.anchor, let buttonWindow = button.window,
                  let screen = buttonWindow.screen ?? NSScreen.main, let panel = self.panel else { return }
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let frame = MenuBarPanelPolicy.frame(anchor: anchor, visible: screen.visibleFrame,
                                                preferred: MenuBarPanelPolicy.preferredSize(page: self.model.page, tab: self.model.tab,
                                                                                            deviceCount: self.model.devices.count))
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
    }
    private func makePanel() -> MenuBarControlPanel {
        let window = MenuBarControlPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Clipy"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.delegate = self
        window.onEscape = { [weak self] in self?.model.escape() }
        window.command = { [weak self] event in self?.handleKey(event) ?? false }
        return window
    }
    func dismiss() {
        generation &+= 1 // Cancels any earlier deferred action, even after the window is hidden.
        guard isVisible else { return }
        MenuBarOverflowManager.shared.endMenuPresentation()
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        model.end()
        snapshotsPending = false; historyPending = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        onVisibilityChanged?(false)
        ClipboardManager.shared.releaseMenuMemory()
        MemoryFootprintReclaimer.reclaimIfIdle()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !model.pinned, panel?.menuDepth == 0 else { return }
        // AppKit can return key focus during the same turn after dismissing a menu.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.model.pinned, self.panel?.menuDepth == 0, self.panel?.isKeyWindow != true else { return }
            self.dismiss()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func refreshHistory() {
        guard isVisible else { return }
        guard panel?.menuDepth == 0 else { historyPending = true; return }
        model.refreshHistory()
    }
    func refreshSnapshots() {
        guard isVisible else { return }
        guard panel?.menuDepth == 0 else { snapshotsPending = true; return }
        updateSnapshots()
    }
    private func updateSnapshots() {
        model.folders = SnippetManager.shared.folders
        model.devices = SyncManager.shared.availableDeviceEntries
        model.notificationCount = NotificationManager.shared.notificationCount
        model.notifications = NotificationManager.shared.fetchPage(offset: 0, limit: 12)
    }
    private func installInputMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.model.pinned, self.panel?.menuDepth == 0 else { return }
            self.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible, !self.model.pinned, self.panel?.menuDepth == 0,
                  event.window !== self.panel else { return event }
            // Let the same status button toggle the existing panel instead of closing then reopening it.
            if let button = self.anchor, event.window === button.window,
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return event }
            self.dismiss()
            return event
        }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command {
            if event.charactersIgnoringModifiers == "f" {
                if model.page != .home { model.navigate(.home) }
                model.focusRequest += 1
                return true
            }
            if event.charactersIgnoringModifiers == "," { handoff(.preferences); return true }
            if event.charactersIgnoringModifiers == "w" { dismiss(); return true }
            if let char = event.charactersIgnoringModifiers, let number = Int(char), (1...6).contains(number) {
                model.useHistoryShortcut(number - 1); return true
            }
        }
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 125: model.moveSelection(1); return true
        case 126: model.moveSelection(-1); return true
        case 36, 76: model.useSelection(); return true
        default: return false
        }
    }
    private func handoff(_ action: MenuBarPanelModel.Action) {
        dismiss()
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, ticket == self.generation, !self.isVisible else { return }
            self.onAction?(action)
        }
    }
    private func activate(_ item: MenuBarOverflowItem) {
        dismiss()
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, ticket == self.generation, !self.isVisible else { return }
            MenuBarOverflowManager.shared.activate(item) { [weak self] result in
                guard let self, ticket == self.generation, !self.isVisible else { return }
                // AX cannotComplete may mean a native menu is already tracking.
                // Never cover that menu with a modal alert or retry the action.
                if result == .unavailable {
                    AlertPresenter.showWarning(title: L10n.t(.overflowTitle), message: L10n.t(.overflowUnavailable))
                }
            }
        }
    }
    private func use(_ entry: HistoryEntry, action: MenuBarPanelModel.HistoryAction, reorder: Bool = true) {
        let manager = ClipboardManager.shared
        if action == .reveal {
            dismiss(); manager.revealInFinder(for: entry); return
        }
        // Keep the precise persisted textPath; a list title is only a preview.
        if reorder { manager.moveHistoryEntryToFront(entry) }
        switch action {
        case .plainText: manager.writePlainTextToPasteboard(entry.item, textPath: entry.textPath)
        case .fileNames:
            guard let urls = entry.item.fileURLs else { return }
            manager.writeFileNamesToPasteboard(urls)
        default: manager.copyToPasteboard(entry, simulatePaste: false)
        }
        if action == .copy {
            model.notice = L10n.t(.panelCopied)
            let ticket = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.generation == ticket { self?.model.notice = nil }
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        let targetPID = target?.processIdentifier
        let version = NSPasteboard.general.changeCount
        let supportsPaste: Bool
        switch entry.item {
        case .text, .html, .rtf: supportsPaste = true
        default: supportsPaste = action == .fileNames
        }
        dismiss()
        guard supportsPaste, target?.isTerminated == false else { return }
        let ticket = generation
        // A nonactivating panel normally leaves the caller frontmost. Do not
        // reactivate an app after the user has switched elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, MenuBarPanelPolicy.mayPaste(ticket: ticket, current: self.generation,
                copiedVersion: version, currentVersion: NSPasteboard.general.changeCount,
                targetPID: targetPID, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                panelVisible: self.isVisible, hasKeyWindow: NSApp.keyWindow?.isVisible == true) else { return }
            manager.simulatePasteIfTrusted()
        }
    }
}
