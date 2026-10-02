import AppKit
import ApplicationServices

/// Retains control identity, never the contents of an external editor.
struct SmartSwitchDeliveryTarget {
    let pid: pid_t
    let launchedAt: Date
    let focus: SmartSwitchFocusTarget

    func matches(_ other: Self) -> Bool {
        pid == other.pid && launchedAt == other.launchedAt && focus.matches(other.focus)
    }
}

/// Uses the existing bounded worker/watchdog without adding observers or polling.
final class SmartSwitchDeliveryTargetReader {
    private let monitor = SmartSwitchFocusMonitor()

    func read(pid: pid_t, completion: @escaping (SmartSwitchDeliveryTarget?) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let launchedAt = app.launchDate, !app.isTerminated else { completion(nil); return }
        monitor.inspect(pid: pid, bundleID: app.bundleIdentifier ?? "") { snapshot in
            guard NSRunningApplication(processIdentifier: pid)?.launchDate == launchedAt,
                  snapshot.kind == .textInput, let focus = snapshot.target,
                  focus.element != nil, focus.window != nil, !focus.desktop else {
                completion(nil); return
            }
            completion(SmartSwitchDeliveryTarget(pid: pid, launchedAt: launchedAt, focus: focus))
        }
    }
}

enum SmartSwitchDeliveryOutcome: Equatable {
    // Dispatch is not evidence that the receiving editor inserted the text.
    case keySent
    case copiedOnly
}

/// A brief, nonactivating hint; no text payload, permission prompt or retained window.
@MainActor
final class SmartSwitchDeliveryNotice {
    static let shared = SmartSwitchDeliveryNotice()
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func showCopiedOnly() {
        dismissal?.cancel()
        panel?.orderOut(nil)
        let hint = SmartActionL10n.t("文字已复制；请在目标输入框手动粘贴。", "Text copied. Paste manually in the intended input.")
        let label = NSTextField(wrappingLabelWithString: hint)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: 16, y: 12, width: 328, height: 40)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView?.addSubview(label)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.minY + 40))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.dismissal = nil
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
