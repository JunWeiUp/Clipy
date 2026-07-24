import AppKit
import SwiftUI

final class HostingWindow<Content: View>: NSWindow, NSWindowDelegate {
    init(
        title: String,
        size: CGSize,
        minSize: CGSize? = nil,
        resizable: Bool = true,
        frameAutosaveName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        var styleMask: StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
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

        // Liquid Glass：透明窗口 + 毛玻璃背景层。
        backgroundColor = .clear
        isOpaque = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        if #available(macOS 13.0, *) {
            titlebarSeparatorStyle = .none
        }
        hasShadow = true
        isMovableByWindowBackground = false
        center()

        let root = content()
            .environmentObject(AppLanguageObserver.shared)
        let intendedFrame = frame
        let hostingController = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.minSize]
        }

        // 用 NSVisualEffectView 作为窗口背景，HostingController 的内容浮于其上，
        // 让整个窗口内容呈现统一的毛玻璃质感。
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

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
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 极轻克制的窗口淡入：仅 transform/opacity，遵守系统「减少动态效果」。
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
