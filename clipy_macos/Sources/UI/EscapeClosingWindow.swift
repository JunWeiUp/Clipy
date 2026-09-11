import AppKit

/// Handle Escape at the window boundary so text fields and SwiftUI editors do
/// not swallow it. Sheets and active input sessions keep their own cancellation.
enum WindowEscapeKeyHandler {
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              window.attachedSheet == nil else { return false }

        if window.firstResponder is ShortcutRecorderView { return false }
        if let input = window.firstResponder as? NSTextInputClient, input.hasMarkedText() {
            return false
        }

        // Holding Escape must not repeatedly dismiss windows or close prompts.
        if !event.isARepeat { window.cancelOperation(nil) }
        return true
    }
}

class EscapeClosingWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if WindowEscapeKeyHandler.handle(event, in: self) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Honor windowShouldClose and all normal save/teardown callbacks.
        performClose(sender)
    }
}

class EscapeClosingPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if WindowEscapeKeyHandler.handle(event, in: self) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
