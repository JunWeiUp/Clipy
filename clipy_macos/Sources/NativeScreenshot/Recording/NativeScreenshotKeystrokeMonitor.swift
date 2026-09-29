import Carbon
import CoreGraphics
import Foundation

/// Read-only keyboard tap. No key text is logged or written to disk.
/// The main run loop owns the tap; start and stop must run on the main thread.
final class NativeScreenshotKeystrokeMonitor {
    private let mode: NativeScreenshotRecordingOptions.KeystrokeMode
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onDisplayText: ((String) -> Void)?

    init(mode: NativeScreenshotRecordingOptions.KeystrokeMode) {
        self.mode = mode
    }

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread)
        guard mode != .off, CGPreflightListenEventAccess() else { return false }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<NativeScreenshotKeystrokeMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .keyDown,
                          let text = NativeScreenshotKeystrokeMonitor.displayText(
                            for: event, mode: monitor.mode,
                            secureInputEnabled: IsSecureEventInputEnabled()
                          ) {
                    monitor.onDisplayText?(text)
                } else if type == .flagsChanged,
                          let text = NativeScreenshotKeystrokeMonitor.modifierDisplayText(
                            for: event, mode: monitor.mode,
                            secureInputEnabled: IsSecureEventInputEnabled()
                          ) {
                    monitor.onDisplayText?(text)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        onDisplayText = nil
    }

    static func displayText(for event: CGEvent,
                            mode: NativeScreenshotRecordingOptions.KeystrokeMode,
                            secureInputEnabled: Bool = IsSecureEventInputEnabled()) -> String? {
        guard mode != .off, !secureInputEnabled else { return nil }
        let flags = event.flags
        let hasShortcutModifier = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        guard mode == .allKeys || hasShortcutModifier else { return nil }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let label: String
        switch Int(code) {
        case kVK_Return: label = "↩"
        case kVK_Tab: label = "⇥"
        case kVK_Space: label = "Space"
        case kVK_Delete: label = "⌫"
        case kVK_ForwardDelete: label = "⌦"
        case kVK_Escape: label = "Esc"
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        case kVK_Home: label = "Home"
        case kVK_End: label = "End"
        case kVK_PageUp: label = "Page Up"
        case kVK_PageDown: label = "Page Down"
        case kVK_F1: label = "F1"
        case kVK_F2: label = "F2"
        case kVK_F3: label = "F3"
        case kVK_F4: label = "F4"
        case kVK_F5: label = "F5"
        case kVK_F6: label = "F6"
        case kVK_F7: label = "F7"
        case kVK_F8: label = "F8"
        case kVK_F9: label = "F9"
        case kVK_F10: label = "F10"
        case kVK_F11: label = "F11"
        case kVK_F12: label = "F12"
        default:
            var units = [UniChar](repeating: 0, count: 16)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count,
                                           actualStringLength: &length,
                                           unicodeString: &units)
            let text = String(decoding: units.prefix(length), as: UTF16.self)
            let printable = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            guard printable, !text.isEmpty else { return nil }
            label = String(text.prefix(8))
        }
        var symbols = ""
        if flags.contains(.maskControl) { symbols += "⌃" }
        if flags.contains(.maskAlternate) { symbols += "⌥" }
        if flags.contains(.maskShift) { symbols += "⇧" }
        if flags.contains(.maskCommand) { symbols += "⌘" }
        return symbols + label
    }

    static func modifierDisplayText(for event: CGEvent,
                                    mode: NativeScreenshotRecordingOptions.KeystrokeMode,
                                    secureInputEnabled: Bool = IsSecureEventInputEnabled()) -> String? {
        guard mode == .allKeys, !secureInputEnabled else { return nil }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch code {
        case kVK_Command, kVK_RightCommand:
            return event.flags.contains(.maskCommand) ? "⌘" : nil
        case kVK_Shift, kVK_RightShift:
            return event.flags.contains(.maskShift) ? "⇧" : nil
        case kVK_Option, kVK_RightOption:
            return event.flags.contains(.maskAlternate) ? "⌥" : nil
        case kVK_Control, kVK_RightControl:
            return event.flags.contains(.maskControl) ? "⌃" : nil
        default: return nil
        }
    }
}
