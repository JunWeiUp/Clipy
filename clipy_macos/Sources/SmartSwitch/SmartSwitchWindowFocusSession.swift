import AppKit

/// Returns a dismissed input window to its caller. AppKit keeps a menu-bar app
/// active after its last window closes, so closing the window alone is not enough.
@MainActor
final class SmartSwitchWindowFocusSession {
    private let ownPID: pid_t
    private let frontmostPID: () -> pid_t?
    private let hasOtherKeyWindow: () -> Bool
    private let activate: (pid_t) -> Bool
    private let refreshFocus: () -> Void
    private let enqueue: (@escaping () -> Void) -> Void
    private let copyText: (String) -> Int
    private let clipboardVersion: () -> Int
    private let pasteCopiedText: (pid_t) -> Void
    private let afterActivation: (@escaping () -> Void) -> Void
    private var previousPID: pid_t?
    private var generation = 0

    init(ownPID: pid_t, frontmostPID: @escaping () -> pid_t?,
         hasOtherKeyWindow: @escaping () -> Bool, activate: @escaping (pid_t) -> Bool,
         refreshFocus: @escaping () -> Void, enqueue: @escaping (@escaping () -> Void) -> Void,
         copyText: @escaping (String) -> Int, clipboardVersion: @escaping () -> Int,
         pasteCopiedText: @escaping (pid_t) -> Void,
         afterActivation: @escaping (@escaping () -> Void) -> Void) {
        self.ownPID = ownPID
        self.frontmostPID = frontmostPID
        self.hasOtherKeyWindow = hasOtherKeyWindow
        self.activate = activate
        self.refreshFocus = refreshFocus
        self.enqueue = enqueue
        self.copyText = copyText
        self.clipboardVersion = clipboardVersion
        self.pasteCopiedText = pasteCopiedText
        self.afterActivation = afterActivation
    }

    convenience init() {
        self.init(ownPID: ProcessInfo.processInfo.processIdentifier,
                  frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                  hasOtherKeyWindow: { NSApp.keyWindow?.isVisible == true },
                  activate: { NSRunningApplication(processIdentifier: $0)?.activate(options: [.activateIgnoringOtherApps]) == true },
                  refreshFocus: { SmartSwitchVoiceRouter.shared.refreshFocusAfterWindowClose() },
                  enqueue: { work in DispatchQueue.main.async { work() } },
                  copyText: {
                      ClipboardManager.shared.writeToPasteboard(.text($0))
                      return NSPasteboard.general.changeCount
                  },
                  clipboardVersion: { NSPasteboard.general.changeCount },
                  pasteCopiedText: { pid in
                      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                            AccessibilityManager.isTrusted else { return }
                      ClipboardManager.shared.simulatePasteIfTrusted()
                      appLog("SmartVoice Escape paste dispatched to pid=\(pid)", level: .debug)
                  },
                  afterActivation: { work in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { work() } })
    }

    func begin(previousPID: pid_t?) {
        generation += 1
        // Reinvoking the shortcut in this window must retain the external caller.
        if let previousPID, previousPID > 0, previousPID != ownPID {
            self.previousPID = previousPID
        }
    }

    func handOff() {
        generation += 1
        previousPID = nil
    }

    func close(pasteText: String? = nil) {
        generation += 1
        let ticket = generation
        let previous = previousPID
        // A nonactivating input panel leaves its caller as the frontmost app.
        let frontAtClose = frontmostPID()
        let ownedForeground = frontAtClose == ownPID || (previous != nil && frontAtClose == previous)
        previousPID = nil
        // Retain the text on the clipboard even if its former app is unavailable.
        // Empty Escape and ordinary window closes must preserve the clipboard.
        let copyVersion = pasteText.flatMap { $0.isEmpty ? nil : copyText($0) }
        // onWillClose runs before AppKit removes the window. Wait until it is
        // gone, and do not override a new popup, settings window or app switch.
        enqueue { [weak self] in
            guard let self, self.generation == ticket else { return }
            if let previous, ownedForeground {
                let front = self.frontmostPID()
                let restored = !self.hasOtherKeyWindow() && (front == previous || (front == self.ownPID && self.activate(previous)))
                appLog("SmartVoice window closed restorePid=\(previous) restored=\(restored)", level: .debug)
                if restored, let copyVersion {
                    self.pasteAfterRestoring(pid: previous, copyVersion: copyVersion, ticket: ticket, attempts: 10)
                }
            }
            self.refreshFocus()
        }
    }

    private func pasteAfterRestoring(pid: pid_t, copyVersion: Int, ticket: Int, attempts: Int) {
        // Activation returns before the receiving app has its key window back.
        // Wait at most one second, and cancel if a new popup/app takes focus.
        afterActivation { [weak self] in
            guard let self, self.generation == ticket else { return }
            let front = self.frontmostPID()
            guard self.clipboardVersion() == copyVersion else { return }
            guard !self.hasOtherKeyWindow() else { return }
            if front == pid {
                self.pasteCopiedText(pid)
            } else if attempts > 1, front == self.ownPID || front == nil {
                self.pasteAfterRestoring(pid: pid, copyVersion: copyVersion, ticket: ticket, attempts: attempts - 1)
            }
        }
    }
}
