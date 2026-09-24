import Foundation
import CoreGraphics
import AppKit
import SwiftUI

@MainActor
func runSmartSwitchInputPanelTests() {
    let panel = SmartSwitchInputPanel(title: "Fixture", size: CGSize(width: 720, height: 500),
                                     minSize: CGSize(width: 620, height: 440), frameAutosaveName: "SmartSwitchFixture") { EmptyView() }
    precondition(panel.styleMask.contains(.nonactivatingPanel) && panel.canBecomeKey && !panel.canBecomeMain,
                 "Input panel would activate Clipy instead of taking keyboard focus only")
    precondition(!panel.hidesOnDeactivate && !panel.isVisible, "Input panel unexpectedly hides or shows itself during setup")
    var escapes = 0
    panel.onEscape = { escapes += 1 }
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    precondition(WindowEscapeKeyHandler.handle(event, in: panel) && escapes == 1,
                 "Nonactivating panel lost the custom Escape paste callback")
    panel.close()
    print("Smart Switch input panel regressions passed (nonactivating, key focus, Escape callback).")
}

private final class VoiceFocusReaderFixture {
    private let lock = NSLock()
    private var reads = 0
    let results: [SmartSwitchFocusMonitor.Inspection]
    init(_ results: [SmartSwitchFocusMonitor.Inspection]) { self.results = results }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read(_ pid: pid_t, _ bundleID: String, _ deadline: TimeInterval) -> SmartSwitchFocusMonitor.Inspection {
        lock.lock()
        defer { lock.unlock() }
        let result = results[min(reads, results.count - 1)]
        reads += 1
        return result
    }
}

@MainActor
func runSmartSwitchFocusWarmupTests() async {
    var focusedReads = 0, enableRequests = 0
    for expected in [SmartSwitchFocusKind.textInput, .textInput, .nonText] {
        let result = SmartSwitchFocusMonitor.inspectFocusedAfterEnablingManualAX(enabled: false, enable: {
            enableRequests += 1; return true
        }, readFocused: {
            focusedReads += 1
            return .init(kind: expected, detail: expected == .textInput ? "role=AXTextArea" : "role=AXButton")
        })
        precondition(result.kind == expected && !result.retryAfterWarmup,
                     "A false Electron AX flag bypassed actual focus or hid a later non-text focus")
    }
    precondition(focusedReads == 3 && enableRequests == 3,
                 "Electron warmup stopped reading focus or reused an earlier input verdict")
    let stillWarming = SmartSwitchFocusMonitor.inspectFocusedAfterEnablingManualAX(enabled: false, enable: { true },
        readFocused: { .init(kind: .unknown, detail: "noFocus") })
    precondition(stillWarming.retryAfterWarmup, "Unready Electron focus did not receive a bounded retry")
    func inspect(_ fixture: VoiceFocusReaderFixture, bundleID: String = "dev.zcode.app") async -> SmartSwitchFocusMonitor.Snapshot {
        let monitor = SmartSwitchFocusMonitor(reader: fixture.read)
        return await withCheckedContinuation { continuation in
            monitor.inspect(pid: 123, bundleID: bundleID) { continuation.resume(returning: $0) }
        }
    }
    let warming = SmartSwitchFocusMonitor.Inspection(kind: .unknown, detail: "electronAXWarmingUp", retryAfterWarmup: true)
    let page = VoiceFocusReaderFixture([warming, .init(kind: .nonText, detail: "role=AXButton")])
    let pageResult = await inspect(page)
    precondition(pageResult.kind == .nonText && page.callCount == 2, "Electron warmup cached an unknown focus instead of reading the ready page")
    let editor = VoiceFocusReaderFixture([warming, .init(kind: .textInput, detail: "role=AXTextArea")])
    let editorResult = await inspect(editor)
    precondition(editorResult.kind == .textInput && editor.callCount == 2, "Warmup classified the focused chat/terminal as empty")
    let unavailable = VoiceFocusReaderFixture([.init(kind: .unknown, detail: "focusedStatus=-25212", retryAfterWarmup: true)])
    let unavailableResult = await inspect(unavailable)
    precondition(unavailableResult.kind == .unknown && unavailable.callCount == 3, "AX failure became non-text focus or retried without a bound")
    precondition(!unavailableResult.shouldOpenSwitch, "Unresolved ZCode input stole dictation by opening a popup")
    let otherUnknown = SmartSwitchFocusMonitor.Snapshot(pid: 123, kind: .unknown, observedAt: 0,
        detail: "noFocus", bundleID: "test.other")
    precondition(!otherUnknown.shouldOpenSwitch, "An unfamiliar app lost unknown-focus protection")
    // Doubao and Codex can temporarily return noValue from AXFocusedUIElement
    // despite a live editor. Preserve the buffered voice key in that state too.
    for bundleID in ["com.bot.pc.doubao", "com.work.pc.doubao", "com.openai.codex", "dev.zcode.app", "dev.zed.Zed", "test.unseen.editor"] {
        let editor = VoiceFocusReaderFixture([.init(kind: .unknown, detail: "focusedStatus=-25212"),
                                             .init(kind: .textInput, detail: "role=AXTextArea"),
                                             .init(kind: .nonText, detail: "role=AXButton")])
        let editorMonitor = SmartSwitchFocusMonitor(reader: editor.read)
        for expected in [SmartSwitchFocusKind.unknown, .textInput, .nonText] {
            let result = await withCheckedContinuation { continuation in
                editorMonitor.inspect(pid: 789, bundleID: bundleID) { continuation.resume(returning: $0) }
            }
            precondition(result.kind == expected && result.shouldOpenSwitch == (expected == .nonText),
                         "Editor protection stole dictation or kept stale focus after leaving the input: \(bundleID)")
            var gesture = SmartSwitchVoiceGesture()
            _ = gesture.handle(.down(eligible: true))
            if !result.shouldOpenSwitch {
                precondition(gesture.handle(.preserveDictation).actions == [.replayDown],
                             "Editor protection swallowed the original voice trigger: \(bundleID)")
                precondition(gesture.handle(.hold(eligible: true)).actions.isEmpty,
                             "A late hold reopened the switcher after preserving dictation: \(bundleID)")
            } else {
                precondition(gesture.handle(.hold(eligible: result.shouldOpenSwitch)).actions == [.showPanel],
                             "Confirmed non-text focus no longer opens the switcher: \(bundleID)")
            }
        }
        let warmingEditor = VoiceFocusReaderFixture([warming, .init(kind: .textInput, detail: "role=AXTextArea source=windowFocused")])
        let readyEditor = await inspect(warmingEditor, bundleID: bundleID)
        precondition(!readyEditor.shouldOpenSwitch && warmingEditor.callCount == 2,
                     "Editor focus recovery failed to preserve input during warmup: \(bundleID)")
        let missing = VoiceFocusReaderFixture([.init(kind: .unknown, detail: "focusedStatus=-25212", retryAfterWarmup: true)])
        let unresolved = await inspect(missing, bundleID: bundleID)
        precondition(unresolved.kind == .unknown && !unresolved.shouldOpenSwitch && missing.callCount == 3,
                     "Exhausted focus retries opened a popup or invented text focus: \(bundleID)")
    }
    runFocusedDescendantTests()
    runUniversalFocusTests()
    runFocusTargetTests()
    await runFocusDeadlineTests()
    let group = VoiceFocusReaderFixture([.init(kind: .unknown, detail: "role=AXGroup")])
    let groupResult = await inspect(group)
    precondition(!groupResult.shouldOpenSwitch && group.callCount == 1, "An opaque container stole dictation")
    // The same app can stop being editable without a focus-change notification.
    // Each inspection must use the new reader result, not a cached input verdict.
    let changing = VoiceFocusReaderFixture([.init(kind: .textInput, detail: "role=AXTextArea"),
                                           .init(kind: .nonText, detail: "role=AXButton")])
    let monitor = SmartSwitchFocusMonitor(reader: changing.read)
    func fresh() async -> SmartSwitchFocusMonitor.Snapshot {
        await withCheckedContinuation { continuation in
            monitor.inspect(pid: 456, bundleID: "test.editor") { continuation.resume(returning: $0) }
        }
    }
    let input = await fresh()
    let container = await fresh()
    precondition(!input.shouldOpenSwitch && container.shouldOpenSwitch && changing.callCount == 2,
                 "An old text-input verdict blocked the next fresh focus check")
    print("Smart Switch focus regressions passed (universal input protection, Electron warmup, bounded/cyclic trees, target identity, deadlines, queue bounds, late results).")
}

private func runUniversalFocusTests() {
    let cases: [(SmartSwitchFocusFacts, SmartSwitchFocusKind)] = [
        (.init(role: "AXWindow", readSucceeded: true), .unknown),
        (.init(role: "AXWindow", readSucceeded: false), .unknown),
        (.init(role: nil, readSucceeded: true), .unknown),
        (.init(role: "AXTextArea", readSucceeded: true), .textInput),
        (.init(role: "AXWindow", hasTextSelection: true, valueIsWritable: true, readSucceeded: true), .textInput),
        (.init(role: "AXButton", readSucceeded: true), .nonText),
        (.init(role: "AXMenuItem", readSucceeded: true), .nonText),
        (.init(role: "AXSlider", hasTextSelection: true, valueIsWritable: true, readSucceeded: true), .nonText),
        (.init(role: "AXButton", selectedTextIsWritable: true, readSucceeded: true), .unknown),
        (.init(role: "AXLink", editable: true, readSucceeded: true), .unknown),
        (.init(role: "AXApplication", readSucceeded: true), .unknown),
        (.init(role: "AXTable", readSucceeded: true), .unknown),
        (.init(role: "AXCell", readSucceeded: true), .unknown)
    ]
    for bundleID in ["dev.zed.Zed", "com.openai.codex", "test.unseen.editor"] {
        for (facts, expected) in cases {
            precondition(facts.kind == expected, "Text capability classification changed")
            let snapshot = SmartSwitchFocusMonitor.Snapshot(pid: 456, kind: facts.kind, observedAt: 0,
                detail: "fixture", bundleID: bundleID)
            precondition(snapshot.shouldOpenSwitch == (expected == .nonText), "App identity changed routing")
            var gesture = SmartSwitchVoiceGesture()
            _ = gesture.handle(.down(eligible: true))
            precondition(gesture.handle(.hold(eligible: snapshot.shouldOpenSwitch)).actions ==
                         (expected == .nonText ? [.showPanel] : [.replayDown]), "Input protection lost a voice trigger")
        }
    }
}

private func runFocusTargetTests() {
    // AX references are opaque fixtures only; no IPC is performed on these PIDs.
    let first = AXUIElementCreateApplication(123), second = AXUIElementCreateApplication(456)
    let same = AXUIElementCreateApplication(123)
    let target = SmartSwitchFocusTarget(element: first, window: second)
    precondition(target.matches(.init(element: same, window: second)), "Stable target was rejected")
    precondition(!target.matches(.init(element: second, window: second)), "Changed control was accepted")
    precondition(!target.matches(.init(element: same, window: first)), "Changed window was accepted")
    precondition(!target.matches(.init(element: same)), "Lost window identity was accepted")
    precondition(!SmartSwitchFocusTarget().matches(.init()), "Missing elements became equal evidence")
    precondition(SmartSwitchFocusTarget(desktop: true).matches(.init(desktop: true)), "Desktop identity changed")
    let before = SmartSwitchFocusMonitor.Snapshot(pid: 123, kind: .nonText, observedAt: 0, detail: "fixture", target: target)
    let after = SmartSwitchFocusMonitor.Snapshot(pid: 456, kind: .nonText, observedAt: 1, detail: "fixture", target: target)
    precondition(!before.matchesTarget(after), "Target comparison ignored the originating PID")
}

@MainActor
private func runFocusDeadlineTests() async {
    func waitForSignal(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                precondition(semaphore.wait(timeout: .now() + 2) == .success, "Slow-reader fixture did not progress")
                continuation.resume()
            }
        }
    }
    let gate = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let fixture = VoiceFocusReaderFixture([.init(kind: .nonText, detail: "lateButton", retryAfterWarmup: true)])
    let monitor = SmartSwitchFocusMonitor(requestTimeout: 0.05, reader: { pid, bundle, deadline in
        started.signal()
        _ = gate.wait(timeout: .now() + 2)
        defer { finished.signal() }
        return fixture.read(pid, bundle, deadline)
    })
    var received: [SmartSwitchFocusMonitor.Snapshot] = []
    var gesture = SmartSwitchVoiceGesture()
    _ = gesture.handle(.down(eligible: true))
    monitor.inspect(pid: 123, bundleID: "test.slow") { snapshot in
        received.append(snapshot)
        if !snapshot.shouldOpenSwitch { _ = gesture.handle(.preserveDictation) }
    }
    await waitForSignal(started)
    // A blocked AX call must not retain the modifier until the worker returns.
    monitor.inspect(pid: 123, bundleID: "test.queued") { received.append($0) }
    monitor.inspect(pid: 123, bundleID: "test.busy") { received.append($0) }
    try? await Task.sleep(nanoseconds: 150_000_000)
    precondition(received.count == 3 && received.allSatisfy { !$0.shouldOpenSwitch },
                 "A stalled reader blocked the main-thread deadline or queue bound")
    precondition(received.contains { $0.detail == "probeBusy" } && received.contains { $0.detail == "deadline" },
                 "Timeout/queue exhaustion did not provide a diagnostic reason")
    precondition(gesture.phase == .passthrough, "Timeout did not commit ordinary dictation")
    gate.signal()
    await waitForSignal(finished)
    try? await Task.sleep(nanoseconds: 100_000_000)
    precondition(received.count == 3 && fixture.callCount == 1, "Late result completed twice or retried an expired request")
    precondition(gesture.handle(.down(eligible: true)).actions.isEmpty &&
                 gesture.handle(.hold(eligible: true)).actions.isEmpty, "Late non-text evidence rearmed the held key")
    _ = gesture.handle(.up)
    precondition(gesture.handle(.down(eligible: true)).actions == [.bufferDown, .scheduleHold],
                 "A fresh press remained blocked after the timed-out gesture")
}

private func runFocusedDescendantTests() {
    let tree: [Int: (focused: Bool, children: [Int])] = [
        0: (true, [1, 2]), 1: (false, []), 2: (false, [3]), 3: (true, [])
    ]
    let focused = SmartSwitchFocusTraversal.collect(from: 0, hasTime: { true }, same: ==, read: { tree[$0] })
    precondition(focused.nodes == [3] && focused.complete, "Window/unfocused input masked the actual descendant")
    let unfocused = SmartSwitchFocusTraversal.collect(from: 0, hasTime: { true }, same: ==, read: { node in
        tree[node].map { (false, $0.children) }
    })
    precondition(unfocused.nodes.isEmpty && unfocused.complete, "Visible controls invented descendant focus")
    let ambiguous = SmartSwitchFocusTraversal.collect(from: 0, hasTime: { true }, same: ==, read: { node in
        tree[node].map { (node == 1 || node == 3, $0.children) }
    })
    precondition(ambiguous.nodes == [1, 3], "First focused element concealed conflicting focus")
    let unavailable = SmartSwitchFocusTraversal.collect(from: 0, hasTime: { true }, same: ==, read: { _ in nil })
    precondition(unavailable.nodes.isEmpty && !unavailable.complete, "Unavailable AX tree became reliable evidence")
    var reads = 0
    let cyclic = SmartSwitchFocusTraversal.collect(from: 0, limit: 4, hasTime: { true }, same: ==, read: { node in
        reads += 1
        return (false, [node])
    })
    precondition(cyclic.nodes.isEmpty && reads == 1, "AX cycle was read more than once")
    let bounded = SmartSwitchFocusTraversal.collect(from: 0, limit: 2, hasTime: { true }, same: ==, read: { tree[$0] })
    precondition(!bounded.complete, "Truncated AX tree was considered complete")
    let shallow = SmartSwitchFocusTraversal.collect(from: 0, maxDepth: 1, hasTime: { true }, same: ==, read: { tree[$0] })
    precondition(!shallow.complete && shallow.nodes.isEmpty, "Tree depth budget was ignored")
    reads = 0
    let timedOut = SmartSwitchFocusTraversal.collect(from: 0, hasTime: { reads < 2 }, same: ==, read: { node in
        reads += 1
        return tree[node]
    })
    precondition(!timedOut.complete && reads == 2, "Window fallback ignored its time budget")
}

@MainActor
func runSmartSwitchEscapePasteTests() {
    let caller: pid_t = 10, clipy: pid_t = 20, otherApp: pid_t = 30
    var front = clipy
    var otherWindow = false
    var activationSucceeds = true
    var activationRequests = 0
    var version = 0
    var clipboard = "original clipboard"
    var pastes: [(pid_t, String)] = []
    var closing: [() -> Void] = []
    var activationTicks: [() -> Void] = []
    let session = SmartSwitchWindowFocusSession(ownPID: clipy, frontmostPID: { front },
        hasOtherKeyWindow: { otherWindow }, activate: { _ in activationRequests += 1; return activationSucceeds },
        refreshFocus: {}, enqueue: { closing.append($0) },
        copyText: { text in clipboard = text; version += 1; return version },
        clipboardVersion: { version }, pasteCopiedText: { pastes.append(($0, clipboard)) },
        afterActivation: { activationTicks.append($0) })
    func finishClose() {
        let work = closing; closing.removeAll(); work.forEach { $0() }
    }
    func tick() {
        let work = activationTicks; activationTicks.removeAll(); work.forEach { $0() }
    }
    func escape(_ text: String?) {
        session.begin(previousPID: caller)
        front = clipy
        session.close(pasteText: text)
    }

    var draft = "  语音文字 👩🏽‍💻\n第二行  "
    let original = draft
    escape(draft)
    draft = "" // model.close() must not erase the captured payload
    precondition(clipboard == original && pastes.isEmpty, "Escape lost text before closing or pasted into the popup")
    finishClose()
    tick()
    precondition(pastes.isEmpty && activationTicks.count == 1, "Paste did not wait for application activation")
    front = caller
    tick()
    precondition(pastes.count == 1 && pastes[0].0 == caller && pastes[0].1 == original,
                 "Escape did not paste the exact Unicode/whitespace payload into its caller")
    tick()
    precondition(pastes.count == 1, "Escape pasted more than once")

    let savedVersion = version
    for empty in [nil, ""] as [String?] {
        escape(empty)
        finishClose()
        tick()
    }
    precondition(version == savedVersion && pastes.count == 1, "Empty Escape or ordinary close changed the clipboard")

    escape("clipboard race")
    finishClose()
    clipboard = "new user copy"; version += 1
    front = caller
    tick()
    precondition(pastes.count == 1 && clipboard == "new user copy", "Escape pasted a newer, unrelated clipboard value")

    escape("new popup")
    finishClose()
    session.begin(previousPID: caller)
    tick()
    precondition(pastes.count == 1, "A previous Escape pasted into a reopened popup")

    escape("user switched")
    finishClose()
    front = otherApp
    tick()
    precondition(pastes.count == 1 && activationTicks.isEmpty, "Escape pasted into a different foreground app")

    escape("activation timeout")
    finishClose()
    for _ in 0..<10 { tick() }
    precondition(pastes.count == 1 && activationTicks.isEmpty, "Paste waited without a bound or fired before activation")

    activationSucceeds = false
    escape("keep for manual paste")
    finishClose()
    tick()
    precondition(clipboard == "keep for manual paste" && pastes.count == 1, "Missing caller lost the copied text or pasted elsewhere")
    activationSucceeds = true

    escape("settings opened")
    otherWindow = true
    finishClose()
    tick()
    precondition(pastes.count == 1 && activationTicks.isEmpty, "Paste stole focus from a different Clipy window")
    otherWindow = false

    session.begin(previousPID: clipy) // no recorded external caller
    front = clipy
    session.close(pasteText: "no caller")
    finishClose()
    tick()
    precondition(clipboard == "no caller" && pastes.count == 1, "Missing caller used an old application's identity")

    // A key panel can accept text while its original app stays frontmost.
    let beforeActivation = activationRequests
    session.begin(previousPID: caller)
    front = caller
    session.close(pasteText: "nonactivating panel text")
    finishClose(); tick()
    precondition(pastes.count == 2 && pastes.last?.1 == "nonactivating panel text" && activationRequests == beforeActivation,
                 "Nonactivating panel did not paste back or unnecessarily reactivated its caller")
    session.begin(previousPID: caller)
    session.close(pasteText: "another key panel appeared")
    finishClose()
    otherWindow = true
    tick()
    precondition(pastes.count == 2 && activationTicks.isEmpty,
                 "Paste leaked into another key panel while the original app remained frontmost")
    otherWindow = false
    print("Smart Switch Escape paste regressions passed (exact text, activating/nonactivating callers, clipboard/focus races, timeout).")
}

@MainActor
func runSmartSwitchWindowFocusTests() {
    func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    let caller: pid_t = 10, clipy: pid_t = 20, destination: pid_t = 30
    var front = caller
    var otherWindow = false
    var activationSucceeds = true
    var activations: [pid_t] = []
    var refreshes = 0
    var deferred: [() -> Void] = []
    let session = SmartSwitchWindowFocusSession(ownPID: clipy, frontmostPID: { front },
        hasOtherKeyWindow: { otherWindow }, activate: { pid in
            activations.append(pid)
            if activationSucceeds { front = pid }
            return activationSucceeds
        }, refreshFocus: { refreshes += 1 }, enqueue: { deferred.append($0) },
        copyText: { _ in preconditionFailure("Ordinary close changed the clipboard") },
        clipboardVersion: { preconditionFailure("Ordinary close inspected the clipboard") },
        pasteCopiedText: { _ in preconditionFailure("Ordinary close pasted content") },
        afterActivation: { _ in preconditionFailure("Ordinary close scheduled a paste") })
    func finishClosing() {
        let work = deferred
        deferred.removeAll()
        work.forEach { $0() }
    }

    // Reproduce the reported loop: the caller's non-text focus never changes,
    // and no outside click is available to deactivate Clipy after dismissal.
    var gesture = SmartSwitchVoiceGesture()
    for _ in 0..<3 {
        expect(gesture.handle(.down(eligible: front == caller)).swallow, "Closing the popup prevented the next voice gesture")
        expect(gesture.handle(.hold(eligible: true)).actions == [.showPanel], "Repeated hold did not open input")
        session.begin(previousPID: front)
        front = clipy
        _ = gesture.handle(.ready(success: true))
        _ = gesture.handle(.up)
        session.close()
        expect(front == clipy, "Focus restored before AppKit finished closing")
        finishClosing()
        expect(front == caller, "Dismissed voice popup left Clipy active with a stale input focus")
    }
    expect(activations == [caller, caller, caller] && refreshes == 3, "Close did not restore the caller and refresh AX focus")

    session.begin(previousPID: caller)
    front = clipy
    session.begin(previousPID: clipy) // manual shortcut while already open
    session.close()
    finishClosing()
    expect(front == caller, "Repeated shortcut replaced the caller with Clipy")

    // Both success and opening preferences explicitly transfer focus ownership.
    // The destination app's activation can still be pending when close fires.
    for _ in 0..<2 {
        session.begin(previousPID: caller)
        front = clipy
        let count = activations.count
        session.handOff()
        session.close()
        finishClosing()
        expect(front == clipy && activations.count == count, "Close overrode the destination/settings activation")
    }

    session.begin(previousPID: caller)
    front = clipy
    session.close()
    front = destination // user switched during the deferred close
    finishClosing()
    expect(front == destination, "Deferred restore stole focus from another app")

    session.begin(previousPID: caller)
    front = destination // user had already switched away before closing
    session.close()
    front = clipy
    let count = activations.count
    finishClosing()
    expect(activations.count == count, "Background dismissal restored an unowned app")

    session.begin(previousPID: caller)
    front = clipy
    session.close()
    session.begin(previousPID: caller) // reopen before the previous close settles
    finishClosing()
    expect(front == clipy && activations.count == count, "Old close deactivated the reopened popup")
    session.close()
    finishClosing()
    expect(front == caller, "Reopened popup lost its caller")

    session.begin(previousPID: caller)
    front = clipy
    session.close()
    otherWindow = true
    finishClosing()
    expect(front == clipy, "Close stole focus from another Clipy window")
    otherWindow = false

    activationSucceeds = false
    session.begin(previousPID: caller)
    front = clipy
    let beforeFailure = refreshes
    session.close()
    finishClosing()
    expect(front == clipy && refreshes == beforeFailure + 1, "Unavailable caller left the closed editor cached")
    activationSucceeds = true
    session.begin(previousPID: clipy)
    session.close()
    finishClosing()
    expect(front == clipy, "A later local popup reused a stale caller")
    print("Smart Switch window focus regressions passed (repeat close/reopen, handoff, races, unavailable caller).")
}

func runSmartSwitchVoicePolicyTests() {
    func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    var modifier = SmartSwitchVoiceModifierState(key: .rightCommand)
    let rightDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    expect(modifier.update(flags: rightDown) && modifier.isHeld, "Right Command down lost when HID keyState is false")
    expect(modifier.isAlone(flags: rightDown), "Right Command incorrectly treated as a combination")
    expect(modifier.update(flags: rightDown), "Repeated side-specific down toggled to up")
    let bothCommands = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x18)
    expect(!modifier.isAlone(flags: bothCommands), "Both Command keys accepted as a standalone voice gesture")
    let leftOnly = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    expect(!modifier.update(flags: leftOnly), "Releasing right Command while left is held was missed")
    expect(!modifier.update(flags: []), "Unmodified release became key down")
    expect(modifier.update(flags: .maskCommand), "Driver without side flags lost key down")
    expect(!modifier.update(flags: .maskCommand), "Driver without side flags lost the next transition")
    var fn = SmartSwitchVoiceModifierState(key: .fn)
    expect(fn.update(flags: .maskSecondaryFn) && !fn.update(flags: []), "Fn transitions failed")
    var option = SmartSwitchVoiceModifierState(key: .rightOption)
    expect(option.update(flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)), "Right Option down lost")
    option.reset()
    expect(!option.isHeld, "Tap reset left a held modifier")
    for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
        expect(SmartSwitchFocusFacts(role: role, readSucceeded: true).kind == .textInput, "Native editable control intercepted")
    }
    expect(SmartSwitchFocusFacts(role: "AXGroup", subrole: "AXSecureTextField", readSucceeded: true).kind == .textInput,
           "Secure text control intercepted")
    expect(SmartSwitchFocusFacts(role: "AXGroup", hasTextSelection: true, selectedTextIsWritable: true, readSucceeded: true).kind == .textInput,
           "Custom editable text intercepted")
    expect(SmartSwitchFocusFacts(role: "AXGroup", hasTextSelection: true, readSucceeded: true).kind == .unknown,
           "Read-only selection in an opaque group incorrectly proved editability")
    // Real Edge reproduction: AXLink has a selected text range, but AXValue is
    // not writable. The old classifier incorrectly treated it as a text input.
    for role in ["AXLink", "AXStaticText", "AXHeading"] {
        expect(SmartSwitchFocusFacts(role: role, hasTextSelection: true, readSucceeded: true).kind == .nonText,
               "Read-only Chromium content prevented automatic voice entry")
    }
    expect(SmartSwitchFocusFacts(role: "AXWebArea", hasTextSelection: true, editable: true,
                                readSucceeded: true).kind == .textInput, "Editable web content intercepted")
    expect(SmartSwitchFocusFacts(role: "AXGroup", editable: true, readSucceeded: true).kind == .textInput,
           "Web contenteditable intercepted")
    expect(!SmartSwitchFocusFacts(role: "AXGroup", readSucceeded: true).kind.shouldOpenSwitch, "Opaque group stole dictation")
    expect(SmartSwitchFocusFacts(role: "AXWindow", readSucceeded: false).kind == .unknown, "AX failure assumed no focus")
    expect(SmartSwitchFocusFacts(role: nil, readSucceeded: true).kind == .unknown, "Missing AX role assumed no focus")
    expect(SmartSwitchFocusFacts(role: "AXOutline", readSucceeded: true).kind == .unknown,
           "A container was mistaken for a non-text control")
    for role in ["AXButton", "AXStaticText", "AXLink"] {
        expect(SmartSwitchFocusFacts(role: role, hasTextSelection: true, readSucceeded: true).kind == .nonText,
               "ZCode's non-editable page was blocked by the editor exclusion")
    }
    for role in ["AXTextArea", "AXTextField"] {
        expect(SmartSwitchFocusFacts(role: role, selectedTextIsWritable: true, valueIsWritable: true,
                                    readSucceeded: true).kind == .textInput,
               "ZCode chat/terminal input was intercepted")
    }
    expect(SmartSwitchFocusFacts(role: "AXWebArea", editable: true, readSucceeded: true).kind == .textInput,
           "Editable ZCode web content was treated as an empty page")
    for role in ["AXWindow", "AXScrollArea", "AXGroup", "AXSplitGroup", "AXSharedScreen", "CustomCanvas"] {
        expect(!SmartSwitchFocusFacts(role: role, hasTextSelection: true, readSucceeded: true).kind.shouldOpenSwitch,
               "An unfamiliar container stole dictation")
    }
    for role in ["AXSlider", "AXCheckBox", "AXTab", "AXPopUpButton"] {
        expect(SmartSwitchFocusFacts(role: role, valueIsWritable: true, readSucceeded: true).kind == .nonText,
               "Writable non-text value was mistaken for a text input")
    }
    expect(SmartSwitchFocusFacts(role: "AXGroup", hasTextSelection: true, valueIsWritable: true,
                                readSucceeded: true).kind == .textInput, "Custom text-capable control lost input protection")
    expect(SmartSwitchFocusFacts(role: "AXTextArea", editable: false, readSucceeded: true).kind == .nonText,
           "Explicitly read-only text area blocked the popup")
    expect(!SmartSwitchFocusKind.unknown.shouldOpenSwitch && !SmartSwitchFocusKind.textInput.shouldOpenSwitch,
           "Input-only passthrough policy regressed")
    expect(SmartSwitchFocusFacts(role: "AXWebArea", readSucceeded: true).kind == .unknown,
           "An opaque browser body stole dictation")

    var tap = SmartSwitchVoiceGesture()
    let unchanged = tap.handle(.down(eligible: false))
    expect(!unchanged.swallow && unchanged.actions.isEmpty && tap.phase == .passthrough, "A blocked gesture changed the trigger")
    expect(tap.handle(.down(eligible: true)).actions.isEmpty, "A repeated down rearmed a passed-through gesture")
    _ = tap.handle(.up)
    let begin = tap.handle(.down(eligible: true))
    expect(begin.swallow && begin.actions == [.bufferDown, .scheduleHold], "Long press was not armed")
    expect(tap.handle(.down(eligible: true)).swallow, "Repeated modifier-down leaked before readiness")
    let short = tap.handle(.up)
    expect(!short.swallow && short.actions == [.replayDown] && tap.phase == .idle, "Short tap lost down/up ordering")

    _ = tap.handle(.down(eligible: true))
    let inputDetected = tap.handle(.preserveDictation)
    expect(inputDetected.actions == [.replayDown] && tap.phase == .passthrough, "Fresh input evidence did not immediately restore dictation")
    expect(tap.handle(.hold(eligible: true)).actions.isEmpty, "An input-field gesture later opened the popup")
    expect(!tap.handle(.up).swallow, "Input-field dictation lost its matching release")

    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.up)
    expect(tap.handle(.preserveDictation).actions.isEmpty, "Late focus inspection replayed a completed gesture")

    _ = tap.handle(.down(eligible: true))
    expect(tap.handle(.hold(eligible: SmartSwitchFocusKind.unknown.shouldOpenSwitch)).actions == [.replayDown],
           "Unknown focus stole a completed long press")
    _ = tap.handle(.up)

    _ = tap.handle(.down(eligible: true))
    let shortcut = tap.handle(.other)
    expect(!shortcut.swallow && shortcut.actions == [.replayDown], "Command+C or a mouse click was consumed")
    expect(tap.handle(.hold(eligible: true)).actions.isEmpty, "Cancelled hold still opened a window")
    _ = tap.handle(.up)

    _ = tap.handle(.down(eligible: true))
    let focusChanged = tap.handle(.hold(eligible: false))
    expect(focusChanged.actions == [.replayDown] && tap.phase == .passthrough, "Focus changed but routing continued")
    _ = tap.handle(.up)

    _ = tap.handle(.down(eligible: true))
    expect(tap.handle(.hold(eligible: true)).actions == [.showPanel], "Hold did not request a focused input")
    let releaseEarly = tap.handle(.up)
    expect(releaseEarly.swallow && releaseEarly.actions == [.discardDown, .keepPanel], "Release before focus closed the accepted popup or started voice")
    expect(tap.handle(.ready(success: true)).actions.isEmpty, "Late readiness started a cancelled recording")

    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.hold(eligible: true))
    let failure = tap.handle(.ready(success: false))
    expect(failure.actions == [.discardDown, .keepPanel], "Failed input source closed the window instead of keeping ordinary input")
    expect(tap.handle(.ready(success: true)).actions.isEmpty, "Late readiness restarted a failed voice handoff")
    expect(tap.handle(.up).swallow && tap.phase == .idle, "Unpaired release escaped after setup failure")

    // Peripheral app-profile changes can emit an extra modifier event while
    // Clipy is becoming active. Preserve the popup, discard the buffered key,
    // and never replay it later into the new preset or foreground application.
    for _ in 0..<3 {
        _ = tap.handle(.down(eligible: true))
        _ = tap.handle(.hold(eligible: true))
        let profileChange = tap.handle(.other)
        expect(profileChange.swallow && profileChange.actions == [.discardDown, .keepPanel],
               "Profile change closed the popup or leaked its buffered modifier")
        expect(tap.handle(.ready(success: true)).actions.isEmpty, "Delayed readiness replayed a key after profile interruption")
        expect(tap.handle(.down(eligible: true)).swallow, "Repeated modifier-down escaped after profile interruption")
        expect(tap.handle(.up).swallow && tap.phase == .idle, "Profile interruption did not release cleanly")
        let retryInPanel = tap.handle(.down(eligible: false))
        expect(!retryInPanel.swallow && retryInPanel.actions.isEmpty,
               "Retry in the preserved editor did not pass through to Doubao")
        expect(!tap.handle(.up).swallow, "Retry in the preserved editor lost its release")
    }

    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.hold(eligible: true))
    expect(tap.handle(.cancel).actions == [.discardDown, .cancelPanel], "Escape/Command-W stopped dismissing a preparing popup")
    expect(tap.handle(.ready(success: true)).actions.isEmpty, "Readiness reopened an explicitly dismissed popup")
    _ = tap.handle(.up)

    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.hold(eligible: true))
    let clickDuringPreparation = tap.handle(.interaction)
    expect(!clickDuringPreparation.swallow && clickDuringPreparation.actions == [.discardDown, .keepPanel],
           "A close-button click or ordinary key was swallowed during preparation")
    expect(tap.handle(.ready(success: true)).actions.isEmpty, "Readiness forwarded a modifier after user interaction")
    _ = tap.handle(.up)

    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.hold(eligible: true))
    expect(tap.handle(.ready(success: true)).actions == [.replayDown] && tap.phase == .forwarding,
           "Voice trigger sent before input was ready")
    expect(!tap.handle(.other).swallow, "Active voice route swallowed other input")
    expect(!tap.handle(.up).swallow && tap.phase == .idle, "Voice stop did not reach Doubao")

    _ = tap.handle(.down(eligible: true))
    expect(tap.handle(.reset).actions == [.replayDown], "Disabling while waiting lost modifier-down")
    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.hold(eligible: true))
    expect(tap.handle(.reset).actions == [.discardDown, .cancelPanel], "Sleep/tap failure left the capture window active")
    print("Smart Switch voice routing regressions passed (focus triage, shortcut passthrough, hold/release, profile interruption, preserved input, cancellation).")
}
