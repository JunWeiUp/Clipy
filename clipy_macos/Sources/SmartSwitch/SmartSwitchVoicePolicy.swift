import AppKit

enum SmartSwitchVoiceKey: String, Codable, CaseIterable, Identifiable {
    case rightCommand, rightOption, fn
    var id: Self { self }
    var keyCode: CGKeyCode {
        switch self { case .rightCommand: return 54; case .rightOption: return 61; case .fn: return 63 }
    }
    var flag: CGEventFlags {
        switch self { case .rightCommand: return .maskCommand; case .rightOption: return .maskAlternate; case .fn: return .maskSecondaryFn }
    }
    var title: String {
        switch self {
        case .rightCommand: return L10n.t(.smartVoiceRightCommand)
        case .rightOption: return L10n.t(.smartVoiceRightOption)
        case .fn: return "Fn / 🌐"
        }
    }
}

struct SmartSwitchVoiceConfiguration: Codable {
    var enabled = false
    var trigger: SmartSwitchVoiceKey = .rightCommand
}

/// Modifier-only flagsChanged events are authoritative. On some macOS/input
/// devices CGEventSource.keyState(.hidSystemState) remains false for modifiers.
struct SmartSwitchVoiceModifierState {
    let key: SmartSwitchVoiceKey
    private(set) var isHeld = false

    // Device-dependent flags from IOKit/hidsystem/IOLLEvent.h.
    private var sideMasks: (left: UInt64, right: UInt64)? {
        switch key {
        case .rightCommand: return (0x08, 0x10) // NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK
        case .rightOption: return (0x20, 0x40) // NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK
        case .fn: return nil
        }
    }

    mutating func update(flags: CGEventFlags) -> Bool {
        if !flags.contains(key.flag) { isHeld = false }
        else if let masks = sideMasks {
            let hasSideFlags = flags.rawValue & (masks.left | masks.right) != 0
            // Drivers that omit side flags still send one flagsChanged event per
            // physical transition of this key. Track those transitions locally.
            isHeld = hasSideFlags ? flags.rawValue & masks.right != 0 : !isHeld
        } else { isHeld = true }
        return isHeld
    }

    func isAlone(flags: CGEventFlags) -> Bool {
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
        return modifiers == key.flag && sideMasks.map { flags.rawValue & $0.left == 0 } != false
    }

    mutating func reset() { isHeld = false }
}

enum SmartSwitchFocusKind: Equatable {
    case textInput, nonText, unknown

    // Prefer opening the switcher unless the focused element is a text input.
    // Unknown remains a distinct diagnostic result, not proof of editability.
    var shouldOpenSwitch: Bool { self != .textInput }
}

struct SmartSwitchFocusFacts {
    var role: String?
    var subrole: String?
    var hasTextSelection = false
    var selectedTextIsWritable = false
    var valueIsWritable = false
    var editable: Bool?
    var readSucceeded = false

    var kind: SmartSwitchFocusKind {
        guard readSucceeded else { return .unknown }
        // Chromium exposes AXSelectedTextRange on read-only links, paragraphs
        // and document bodies. Selection alone does not make a text input.
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return .textInput }
        if selectedTextIsWritable || editable == true || (valueIsWritable && hasTextSelection) { return .textInput }
        guard let role else { return .unknown }
        if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
            // Missing AXEditable is common on native inputs and terminals;
            // distinguish it from an explicit read-only text control.
            return editable == false ? .nonText : .textInput
        }
        // A writable AXValue alone also describes sliders, checkboxes and tabs.
        // No application exclusions or non-text role allowlist are needed.
        return .nonText
    }
}

/// Pure gesture policy, shared by the event tap and regression tests.
/// Only the initial modifier-down is buffered. Ordinary shortcuts are flushed
/// in order before their next physical event, without synthesizing their text.
struct SmartSwitchVoiceGesture {
    enum Phase: Equatable { case idle, waiting, preparing, forwarding, cancelledUntilRelease }
    enum Event { case down(eligible: Bool), up, other, interaction, cancel, preserveDictation, hold(eligible: Bool), ready(success: Bool), reset }
    enum Action: Equatable { case bufferDown, scheduleHold, replayDown, discardDown, showPanel, keepPanel, cancelPanel }
    struct Decision {
        var swallow = false
        var actions: [Action] = []
    }
    private(set) var phase: Phase = .idle

    mutating func handle(_ event: Event) -> Decision {
        switch (phase, event) {
        case (.waiting, .down), (.preparing, .down), (.cancelledUntilRelease, .down):
            return Decision(swallow: true)
        case (.idle, .down(true)):
            phase = .waiting
            return Decision(swallow: true, actions: [.bufferDown, .scheduleHold])
        case (.waiting, .up), (.waiting, .other), (.waiting, .preserveDictation):
            phase = .idle
            return Decision(actions: [.replayDown])
        case (.waiting, .hold(true)):
            phase = .preparing
            return Decision(actions: [.showPanel])
        case (.waiting, .hold(false)):
            phase = .idle
            return Decision(actions: [.replayDown])
        case (.preparing, .ready(true)):
            phase = .forwarding
            return Decision(actions: [.replayDown])
        case (.preparing, .ready(false)):
            phase = .cancelledUntilRelease
            return Decision(actions: [.discardDown, .keepPanel])
        case (.preparing, .up):
            phase = .idle
            // A completed hold already requested the window. A profile switch,
            // early release or slow input source only cancels voice forwarding;
            // it must not undo that request and flash the window closed.
            return Decision(swallow: true, actions: [.discardDown, .keepPanel])
        case (.preparing, .other):
            phase = .cancelledUntilRelease
            return Decision(swallow: true, actions: [.discardDown, .keepPanel])
        case (.preparing, .interaction):
            phase = .cancelledUntilRelease
            // A click (including the close button) or ordinary key still goes
            // to its target. Only the buffered voice modifier is discarded.
            return Decision(actions: [.discardDown, .keepPanel])
        case (.preparing, .cancel):
            phase = .cancelledUntilRelease
            return Decision(swallow: true, actions: [.discardDown, .cancelPanel])
        case (.forwarding, .up):
            phase = .idle
            return Decision()
        case (.cancelledUntilRelease, .up):
            phase = .idle
            return Decision(swallow: true)
        case (.waiting, .reset):
            phase = .idle
            return Decision(actions: [.replayDown])
        case (.preparing, .reset):
            phase = .idle
            return Decision(actions: [.discardDown, .cancelPanel])
        case (_, .reset):
            phase = .idle
            return Decision()
        default: return Decision()
        }
    }
}
