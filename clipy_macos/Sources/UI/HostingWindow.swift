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
        } else {
            setContentSize(NSSize(width: size.width, height: size.height))
        }
        if let minSize {
            var clampedFrame = frame
            if clampedFrame.width < minSize.width {
                clampedFrame.size.width = minSize.width
            }
            if clampedFrame.height < minSize.height {
                clampedFrame.size.height = minSize.height
            }
            if clampedFrame != frame {
                setFrame(clampedFrame, display: false)
            }
        }

        backgroundColor = .windowBackgroundColor
        isOpaque = true
        center()

        let root = content()
            .environmentObject(AppLanguageObserver.shared)
        let intendedFrame = frame
        let hostingController = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.minSize]
        }
        contentViewController = hostingController
        setFrame(intendedFrame, display: false)
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
