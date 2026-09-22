import AppKit
import Carbon
import Combine

/// Coordinates one long-press gesture. Each trigger starts a fresh asynchronous
/// focus inspection; Accessibility IPC never runs inside the event tap.
final class SmartSwitchVoiceRouter: ObservableObject {
    static let shared = SmartSwitchVoiceRouter()
    enum Status { case disabled, needsSetup, needsPermission, active, unavailable }
    @Published private(set) var status: Status = .disabled
    private let focus = SmartSwitchFocusMonitor()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var subscriptions: [AnyCancellable] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var gesture = SmartSwitchVoiceGesture()
    private var bufferedDown: CGEvent?
    private var attempt = UUID()
    private var originalPID: pid_t = 0
    private var holdWork: DispatchWorkItem?
    private var preparationTimeout: DispatchWorkItem?
    private var trigger: SmartSwitchVoiceKey = .rightCommand
    private var modifierState = SmartSwitchVoiceModifierState(key: .rightCommand)
    private static let replayTag: Int64 = 0x434C_5652

    func start() {
        guard subscriptions.isEmpty else { return }
        let store = SmartSwitchStore.shared
        subscriptions = [
            store.$voiceConfiguration.dropFirst().sink { [weak self] _ in self?.scheduleConfigure() },
            store.$configuration.dropFirst().sink { [weak self] _ in self?.scheduleConfigure() }
        ]
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            systemObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reset()
                self?.focus.invalidate()
            })
        }
        configure()
    }

    private func scheduleConfigure() {
        DispatchQueue.main.async { [weak self] in self?.configure() }
    }

    func refreshFocusAfterWindowClose() {
        // Discard the closed editor's AX snapshot. App activation notifications
        // refresh it again when the original app finishes coming forward.
        // Keep the gesture/modifier state: a held voice key still needs its up.
        focus.invalidate()
    }

    func configure() {
        stopTap()
        defer { appLog("SmartVoice configure status=\(status) trigger=\(SmartSwitchStore.shared.voiceConfiguration.trigger.rawValue)") }
        let store = SmartSwitchStore.shared
        guard store.voiceConfiguration.enabled else { status = .disabled; return }
        // App launch and ZCode drafts work without model setup.
        guard AccessibilityManager.isTrusted, CGPreflightListenEventAccess() else { status = .needsPermission; return }
        trigger = store.voiceConfiguration.trigger
        modifierState = SmartSwitchVoiceModifierState(key: trigger)
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SmartSwitchVoiceRouter>.fromOpaque(context).takeUnretainedValue()
                    .handle(proxy: proxy, type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { status = .unavailable; return }
        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        focus.start()
        status = .active
    }

    private func stopTap() {
        reset()
        focus.stop()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func reset() {
        let decision = gesture.handle(.reset)
        perform(decision.actions, event: nil, proxy: nil)
        holdWork?.cancel()
        preparationTimeout?.cancel()
        modifierState.reset()
        attempt = UUID()
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            appLog("SmartVoice tap disabled; resetting gesture", level: .warning)
            reset()
            focus.invalidate()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.replayTag else { return Unmanaged.passUnretained(event) }
        let isTrigger = type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == Int64(trigger.keyCode)
        let decision: SmartSwitchVoiceGesture.Decision
        if isTrigger {
            let isDown = modifierState.update(flags: event.flags)
            if isDown {
                let app = NSWorkspace.shared.frontmostApplication
                let pid = app?.processIdentifier ?? 0
                let alone = modifierState.isAlone(flags: event.flags)
                // The tap is installed on CFRunLoopGetMain. Read our own panel
                // synchronously; AX still belongs on the background focus queue.
                let panelHasFocus = MainActor.assumeIsolated { SmartSwitchWindow.shared.hasKeyboardFocus }
                let eligible = alone && pid > 0 && pid != ProcessInfo.processInfo.processIdentifier &&
                    !panelHasFocus && AccessibilityManager.isTrusted && !IsSecureEventInputEnabled()
                appLog("SmartVoice trigger down flags=\(String(event.flags.rawValue, radix: 16)) alone=\(alone) checkingFocus=\(eligible) frontPid=\(pid) cached:\(focus.diagnosticSummary)", level: .debug)
                originalPID = gesture.phase == .idle ? pid : originalPID
                decision = gesture.handle(.down(eligible: eligible))
            } else {
                appLog("SmartVoice trigger up flags=\(String(event.flags.rawValue, radix: 16)) phase=\(gesture.phase)", level: .debug)
                decision = gesture.handle(.up)
            }
        } else if type == .keyDown || type == .flagsChanged || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            // Explicit Escape/Command-W must still dismiss a preparing window.
            // Incidental profile/modifier changes only detach the voice handoff.
            let closesPanel = type == .keyDown && (key == 53 || (key == 13 && event.flags.contains(.maskCommand)))
            if gesture.phase == .preparing && closesPanel { decision = gesture.handle(.cancel) }
            else if gesture.phase == .preparing && type != .flagsChanged { decision = gesture.handle(.interaction) }
            else { decision = gesture.handle(.other) }
            let isShortcut = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            if type != .flagsChanged && (type != .keyDown || isShortcut || [9, 36, 53].contains(key) || focus.snapshot?.kind != .textInput) {
                focus.invalidate()
            }
        } else { return Unmanaged.passUnretained(event) }
        perform(decision.actions, event: event, proxy: proxy)
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func perform(_ actions: [SmartSwitchVoiceGesture.Action], event: CGEvent?, proxy: CGEventTapProxy?) {
        for action in actions {
            switch action {
            case .bufferDown:
                bufferedDown = event?.copy()
                attempt = UUID()
            case .scheduleHold:
                let ticket = attempt
                let work = DispatchWorkItem { [weak self] in self?.holdElapsed(ticket: ticket) }
                holdWork?.cancel()
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
                inspectInitialFocus(ticket: ticket)
            case .replayDown:
                holdWork?.cancel()
                preparationTimeout?.cancel()
                guard let down = bufferedDown else { continue }
                bufferedDown = nil
                down.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
                down.timestamp = DispatchTime.now().uptimeNanoseconds
                if let proxy {
                    // Apple guarantees this is inserted BEFORE the current returned
                    // event, so Command+C and a short down/up retain their ordering.
                    down.tapPostEvent(proxy)
                } else { down.post(tap: .cgSessionEventTap) }
            case .discardDown:
                bufferedDown = nil
                holdWork?.cancel()
                preparationTimeout?.cancel()
            case .showPanel:
                appLog("SmartVoice preparing input window")
                let ticket = attempt
                let timeout = DispatchWorkItem { [weak self] in self?.panelReady(ticket: ticket, success: false) }
                preparationTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
                DispatchQueue.main.async { [weak self] in
                    // Once a hold is accepted, release may precede this queued
                    // presentation. Show it anyway; keepPanel below then detaches
                    // voice readiness. A reset/new attempt invalidates the ticket.
                    guard let self, self.attempt == ticket else { return }
                    SmartSwitchWindow.shared.showForVoiceRouting(ticket: ticket, previousPID: self.originalPID) { [weak self] success in
                        self?.panelReady(ticket: ticket, success: success)
                    }
                }
            case .keepPanel:
                appLog("SmartVoice handoff interrupted; preserving input window phase=\(gesture.phase)", level: .debug)
                let ticket = attempt
                DispatchQueue.main.async { SmartSwitchWindow.shared.preserveVoiceRouting(ticket: ticket) }
            case .cancelPanel:
                appLog("SmartVoice explicitly cancelled/reset before input readiness; closing window", level: .debug)
                let ticket = attempt
                DispatchQueue.main.async { SmartSwitchWindow.shared.cancelVoiceRouting(ticket: ticket) }
            }
        }
    }

    private func inspectInitialFocus(ticket: UUID) {
        // Even a cached text input may have lost focus without an AX notification.
        // Fresh positive input evidence releases the modifier immediately, without
        // waiting out the hold threshold in normal dictation fields.
        focus.recheck { [weak self] snapshot in
            guard let self, self.attempt == ticket, self.gesture.phase == .waiting,
                  snapshot.pid == self.originalPID, !snapshot.shouldOpenSwitch else { return }
            appLog("SmartVoice preserving dictation focus=\(snapshot.kind) \(snapshot.detail)", level: .debug)
            let decision = self.gesture.handle(.preserveDictation)
            self.perform(decision.actions, event: nil, proxy: nil)
        }
    }

    private func holdElapsed(ticket: UUID) {
        guard attempt == ticket, gesture.phase == .waiting else { return }
        focus.recheck { [weak self] snapshot in
            guard let self, self.attempt == ticket, self.gesture.phase == .waiting else { return }
            let eligible = snapshot.shouldOpenSwitch && snapshot.pid == self.originalPID &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.originalPID &&
                AccessibilityManager.isTrusted && !IsSecureEventInputEnabled() && self.modifierState.isHeld
            appLog("SmartVoice hold eligible=\(eligible) focus=\(snapshot.kind) \(snapshot.detail)", level: .debug)
            let decision = self.gesture.handle(.hold(eligible: eligible))
            self.perform(decision.actions, event: nil, proxy: nil)
        }
    }

    private func panelReady(ticket: UUID, success: Bool) {
        guard attempt == ticket, gesture.phase == .preparing else { return }
        let stillHeld = modifierState.isHeld
        appLog("SmartVoice input ready=\(success) held=\(stillHeld)")
        let decision = gesture.handle(.ready(success: success && stillHeld))
        perform(decision.actions, event: nil, proxy: nil)
    }
}
