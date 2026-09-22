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
    func read(_ pid: pid_t, _ bundleID: String) -> SmartSwitchFocusMonitor.Inspection {
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
    func inspect(_ fixture: VoiceFocusReaderFixture) async -> SmartSwitchFocusMonitor.Snapshot {
        let monitor = SmartSwitchFocusMonitor(reader: fixture.read)
        return await withCheckedContinuation { continuation in
            monitor.inspect(pid: 123, bundleID: "dev.zcode.app") { continuation.resume(returning: $0) }
        }
    }
    let warming = SmartSwitchFocusMonitor.Inspection(kind: .unknown, detail: "electronAXWarmingUp", retryAfterWarmup: true)
    let page = VoiceFocusReaderFixture([warming, .init(kind: .nonText, detail: "role=AXWebArea")])
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
    precondition(otherUnknown.shouldOpenSwitch, "ZCode input protection changed the fallback in unrelated apps")
    let group = VoiceFocusReaderFixture([.init(kind: .nonText, detail: "role=AXGroup")])
    let groupResult = await inspect(group)
    precondition(groupResult.shouldOpenSwitch && group.callCount == 1, "A non-editable ZCode container caused polling or blocked routing")
    // The same app can stop being editable without a focus-change notification.
    // Each inspection must use the new reader result, not a cached input verdict.
    let changing = VoiceFocusReaderFixture([.init(kind: .textInput, detail: "role=AXTextArea"),
                                           .init(kind: .nonText, detail: "role=AXSplitGroup")])
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
    print("Smart Switch focus regressions passed (Electron flag/read ordering, ZCode input protection, fresh reads, bounded retry).")
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
    expect(SmartSwitchFocusFacts(role: "AXGroup", hasTextSelection: true, readSucceeded: true).kind == .nonText,
           "Read-only selection in an opaque group incorrectly proved editability")
    // Real Edge reproduction: AXLink has a selected text range, but AXValue is
    // not writable. The old classifier incorrectly treated it as a text input.
    for role in ["AXLink", "AXStaticText", "AXHeading", "AXWebArea"] {
        expect(SmartSwitchFocusFacts(role: role, hasTextSelection: true, readSucceeded: true).kind == .nonText,
               "Read-only Chromium content prevented automatic voice entry")
    }
    expect(SmartSwitchFocusFacts(role: "AXWebArea", hasTextSelection: true, editable: true,
                                readSucceeded: true).kind == .textInput, "Editable web content intercepted")
    expect(SmartSwitchFocusFacts(role: "AXGroup", editable: true, readSucceeded: true).kind == .textInput,
           "Web contenteditable intercepted")
    expect(SmartSwitchFocusFacts(role: "AXGroup", readSucceeded: true).kind.shouldOpenSwitch, "Non-editable group still blocked routing")
    expect(SmartSwitchFocusFacts(role: "AXWindow", readSucceeded: false).kind == .unknown, "AX failure assumed no focus")
    expect(SmartSwitchFocusFacts(role: nil, readSucceeded: true).kind == .unknown, "Missing AX role assumed no focus")
    expect(SmartSwitchFocusFacts(role: "AXOutline", readSucceeded: true).kind == .nonText,
           "Finder selection was not eligible")
    for role in ["AXWebArea", "AXButton", "AXStaticText", "AXLink"] {
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
        expect(SmartSwitchFocusFacts(role: role, hasTextSelection: true, readSucceeded: true).kind.shouldOpenSwitch,
               "A container or unfamiliar non-input role still required an allowlist")
    }
    for role in ["AXSlider", "AXCheckBox", "AXTab", "AXPopUpButton"] {
        expect(SmartSwitchFocusFacts(role: role, valueIsWritable: true, readSucceeded: true).kind == .nonText,
               "Writable non-text value was mistaken for a text input")
    }
    expect(SmartSwitchFocusFacts(role: "AXGroup", hasTextSelection: true, valueIsWritable: true,
                                readSucceeded: true).kind == .textInput, "Custom text-capable control lost input protection")
    expect(SmartSwitchFocusFacts(role: "AXTextArea", editable: false, readSucceeded: true).kind == .nonText,
           "Explicitly read-only text area blocked the popup")
    expect(SmartSwitchFocusKind.unknown.shouldOpenSwitch && !SmartSwitchFocusKind.textInput.shouldOpenSwitch,
           "Input-only passthrough policy regressed")
    expect(SmartSwitchFocusFacts(role: "AXWebArea", readSucceeded: true).kind == .nonText,
           "Browser body without a text selection was not eligible")

    var tap = SmartSwitchVoiceGesture()
    let unchanged = tap.handle(.down(eligible: false))
    expect(!unchanged.swallow && unchanged.actions.isEmpty && tap.phase == .idle, "A blocked gesture changed the trigger")
    let begin = tap.handle(.down(eligible: true))
    expect(begin.swallow && begin.actions == [.bufferDown, .scheduleHold], "Long press was not armed")
    expect(tap.handle(.down(eligible: true)).swallow, "Repeated modifier-down leaked before readiness")
    let short = tap.handle(.up)
    expect(!short.swallow && short.actions == [.replayDown] && tap.phase == .idle, "Short tap lost down/up ordering")

    _ = tap.handle(.down(eligible: true))
    let inputDetected = tap.handle(.preserveDictation)
    expect(inputDetected.actions == [.replayDown] && tap.phase == .idle, "Fresh input evidence did not immediately restore dictation")
    expect(tap.handle(.hold(eligible: true)).actions.isEmpty, "An input-field gesture later opened the popup")
    expect(!tap.handle(.up).swallow, "Input-field dictation lost its matching release")

    _ = tap.handle(.down(eligible: true))
    _ = tap.handle(.up)
    expect(tap.handle(.preserveDictation).actions.isEmpty, "Late focus inspection replayed a completed gesture")

    _ = tap.handle(.down(eligible: true))
    expect(tap.handle(.hold(eligible: SmartSwitchFocusKind.unknown.shouldOpenSwitch)).actions == [.showPanel],
           "Unknown focus still suppressed a completed long press")
    _ = tap.handle(.up)

    _ = tap.handle(.down(eligible: true))
    let shortcut = tap.handle(.other)
    expect(!shortcut.swallow && shortcut.actions == [.replayDown], "Command+C or a mouse click was consumed")
    expect(tap.handle(.hold(eligible: true)).actions.isEmpty, "Cancelled hold still opened a window")

    _ = tap.handle(.down(eligible: true))
    let focusChanged = tap.handle(.hold(eligible: false))
    expect(focusChanged.actions == [.replayDown] && tap.phase == .idle, "Focus changed but routing continued")

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
