import AppKit
import SwiftUI

final class HostingWindow<Content: View>: NSWindow {
    init(
        title: String,
        size: CGSize,
        minSize: CGSize? = nil,
        resizable: Bool = true,
        frameAutosaveName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        var styleMask: StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            styleMask.insert(.resizable)
        }

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        self.title = title
        self.isReleasedWhenClosed = false
        if let minSize {
            self.minSize = NSSize(width: minSize.width, height: minSize.height)
        }
        if let frameAutosaveName {
            setFrameAutosaveName(frameAutosaveName)
        }

        backgroundColor = .windowBackgroundColor
        isOpaque = true
        center()

        let root = content()
            .environmentObject(AppLanguageObserver.shared)
        contentViewController = NSHostingController(rootView: root)
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close()
            return
        }
        super.keyDown(with: event)
    }
}
