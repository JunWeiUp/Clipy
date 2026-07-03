import AppKit

/// Floating panel that can receive keyboard and mouse events for toolbar buttons.
final class ScreenshotEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class PinFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
