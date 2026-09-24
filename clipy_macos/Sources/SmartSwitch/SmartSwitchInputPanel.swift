import AppKit
import SwiftUI

/// Receives text input without changing the foreground application. Peripheral
/// tools can keep that application's preset while the user dictates into Clipy.
/// NSMenu sessions save and restore the key window around tracking. A
/// nonactivating panel that can still become key during that window drags
/// the panel into the session's key negotiation while the app activation
/// transition is still settling, and the menu cancels itself within
/// milliseconds of opening. Refusing key only while any menu is tracking
/// keeps the panel clear of that negotiation; outside menu sessions the
/// panel keeps its normal input behavior.
private enum SmartSwitchMenuTrackingGuard {
    static var depth = 0
    static let observers: [NSObjectProtocol] = {
        let center = NotificationCenter.default
        let begin = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            depth += 1
        }
        let end = center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            depth = max(0, depth - 1)
        }
        return [begin, end]
    }()
}

final class SmartSwitchInputPanel<Content: View>: EscapeClosingPanel, NSWindowDelegate, WindowSessionPresenting {
    var onWillClose: (() -> Void)?

    init(title: String, size: CGSize, minSize: CGSize, frameAutosaveName: String,
         @ViewBuilder content: () -> Content) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        self.minSize = NSSize(width: minSize.width, height: minSize.height)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .windowBackgroundColor
        isOpaque = true
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        titlebarSeparatorStyle = .none
        hasShadow = true
        isMovableByWindowBackground = false
        setFrameAutosaveName(frameAutosaveName)
        setContentSize(size)
        center()

        let root = content().font(AppFont.body).tint(AppColor.accent)
            .environmentObject(AppLanguageObserver.shared)
        let intendedFrame = frame
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.minSize]
        contentViewController = controller
        setFrame(intendedFrame, display: false)
        delegate = self
        // Install the NSMenu tracking observers eagerly; the static property
        // above is otherwise lazily initialized on first canBecomeKey read.
        _ = SmartSwitchMenuTrackingGuard.observers
    }

    override var canBecomeKey: Bool { SmartSwitchMenuTrackingGuard.depth == 0 }
    override var canBecomeMain: Bool { false }

    func show() {
        // Do not call NSApp.activate here: doing so changes Ulanzi's app preset
        // and may release its current voice shortcut during the transition.
        makeKeyAndOrderFront(nil)
        appLog("SmartVoice panel shown nonactivating=true key=\(isKeyWindow) appActive=\(NSApp.isActive) frontPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)", level: .debug)
    }

    func windowWillClose(_ notification: Notification) { onWillClose?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
