import AppKit
import CoreGraphics

@MainActor
private final class NativeScreenshotCountdownWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}

/// Visible, cancellable delay before capture starts. It does not enter the
/// ScreenCaptureKit stream because the coordinator closes it first.
@MainActor
final class NativeScreenshotRecordingCountdownHUD: NSObject {
    private let window: NativeScreenshotCountdownWindow
    private let label = NSTextField(labelWithString: "")
    var onCancel: (() -> Void)?

    override init() {
        window = NativeScreenshotCountdownWindow(
            contentRect: CGRect(x: 0, y: 0, width: 182, height: 108),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let root = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 182, height: 108))
        root.material = .hudWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 43, weight: .semibold)
        label.frame = CGRect(x: 12, y: 38, width: 158, height: 56)
        label.setAccessibilityLabel(NativeScreenshotUserText.string(
            "录屏开始倒计时", "Recording starts in"))
        root.addSubview(label)
        let cancel = NSButton(title: NativeScreenshotUserText.string("取消", "Cancel"),
                              target: self, action: #selector(cancelPressed))
        cancel.frame = CGRect(x: 45, y: 8, width: 92, height: 28)
        root.addSubview(cancel)
        window.contentView = root
        window.onEscape = { [weak self] in self?.onCancel?() }
    }

    func show(near region: CGRect, displayID: CGDirectDisplayID) {
        NativeScreenshotRecordingPanelPlacement.place(window, near: region, displayID: displayID)
        window.makeKeyAndOrderFront(nil)
    }

    func update(seconds: Int) { label.stringValue = String(seconds) }

    func close() {
        window.orderOut(nil)
        window.onEscape = nil
        window.contentView = nil
        onCancel = nil
    }

    @objc private func cancelPressed() { onCancel?() }
}
