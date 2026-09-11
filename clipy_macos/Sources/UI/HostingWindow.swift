import AppKit
import SwiftUI

final class HostingWindow<Content: View>: EscapeClosingWindow, NSWindowDelegate {
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

        // Standard windows use readable, opaque content and the native title bar.
        // Capture overlays have their own canvas chrome and lifecycle.
        backgroundColor = .windowBackgroundColor
        isOpaque = true
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        if #available(macOS 13.0, *) {
            titlebarSeparatorStyle = .none
        }
        hasShadow = true
        isMovableByWindowBackground = false
        center()

        let root = content()
            .font(AppFont.body)
            .tint(AppColor.accent)
            .environmentObject(AppLanguageObserver.shared)
        let intendedFrame = frame
        let hostingController = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.minSize]
        }

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.wantsLayer = true
        container.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: container.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        contentView = container
        setFrame(intendedFrame, display: false)
        delegate = self
    }

    var onWillClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
    }

    func show() {
        let wasVisible = isVisible
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 极轻克制的窗口淡入：仅 transform/opacity，遵守系统「减少动态效果」。
        if wasVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
        } else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close()
            return
        }
        super.keyDown(with: event)
    }
}
