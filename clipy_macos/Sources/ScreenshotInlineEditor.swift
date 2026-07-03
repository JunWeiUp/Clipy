import AppKit
import Combine
import SwiftUI

final class ScreenshotInlineEditor: NSResponder {
    static weak var current: ScreenshotInlineEditor?

    private let viewModel: ScreenshotEditorViewModel
    private let canvasView: AnnotationCanvasView
    private let screenRect: NSRect
    private var panel: ScreenshotEditorPanel?
    private var keyMonitor: Any?

    init(image: NSImage, screenRect: NSRect) {
        self.screenRect = screenRect
        self.viewModel = ScreenshotEditorViewModel(image: image)
        self.canvasView = AnnotationCanvasView(baseImage: image, model: viewModel.annotationModel, contentMode: .fill)
        super.init()
        viewModel.canvasView = canvasView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func present(image: NSImage, screenRect: NSRect) {
        let editor = ScreenshotInlineEditor(image: image, screenRect: screenRect)
        editor.present()
    }

    func present() {
        Self.current?.dismiss()
        Self.current = self

        let barHeight = ScreenshotChrome.barHeight
        let panelWidth = screenRect.width
        let placement = toolbarPlacement(barHeight: barHeight)
        let panelFrame = placement.panelFrame

        let panel = ScreenshotEditorPanel(
            contentRect: panelFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))

        let canvasFrame = placement.canvasFrame
        canvasView.frame = canvasFrame
        canvasView.autoresizingMask = [.width, .height]
        container.addSubview(canvasView)

        let toolbarView = ScreenshotToolbarView(
            viewModel: viewModel,
            barWidth: panelWidth,
            onDone: { [weak self] in self?.done() },
            onPin: { [weak self] in self?.pin() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        .environmentObject(AppLanguageObserver.shared)

        let toolbarHosting = NSHostingView(rootView: toolbarView)
        toolbarHosting.frame = placement.toolbarFrame
        container.addSubview(toolbarHosting)

        let toastHosting = NSHostingView(rootView: ToastOverlay(viewModel: viewModel))
        toastHosting.frame = NSRect(
            x: panelWidth / 2 - 120,
            y: placement.toolbarFrame.maxY + 8,
            width: 240,
            height: 36
        )
        toastHosting.isHidden = true
        container.addSubview(toastHosting)

        viewModel.$toastMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak toastHosting] message in
                toastHosting?.isHidden = message == nil
            }
            .store(in: &cancellables)

        panel.contentView = container
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.modifierFlags.contains(.command), event.keyCode == 36 {
                self.done()
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                if event.modifierFlags.contains(.shift) {
                    self.viewModel.annotationModel.redo()
                } else {
                    self.viewModel.annotationModel.undo()
                }
                self.canvasView.needsDisplay = true
                return nil
            }
            return event
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private struct ToolbarPlacement {
        let panelFrame: NSRect
        let canvasFrame: NSRect
        let toolbarFrame: NSRect
    }

    private func toolbarPlacement(barHeight: CGFloat) -> ToolbarPlacement {
        let panelWidth = screenRect.width
        let panelHeight = screenRect.height + barHeight
        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? screenRect

        var originX = screenRect.origin.x
        originX = max(visible.minX, min(originX, visible.maxX - panelWidth))

        let belowY = screenRect.origin.y - barHeight
        if belowY >= visible.minY {
            let panelFrame = NSRect(x: originX, y: belowY, width: panelWidth, height: panelHeight)
            return ToolbarPlacement(
                panelFrame: panelFrame,
                canvasFrame: NSRect(x: 0, y: barHeight, width: panelWidth, height: screenRect.height),
                toolbarFrame: NSRect(x: 0, y: 0, width: panelWidth, height: barHeight)
            )
        }

        let panelFrame = NSRect(x: originX, y: screenRect.maxY, width: panelWidth, height: panelHeight)
        return ToolbarPlacement(
            panelFrame: panelFrame,
            canvasFrame: NSRect(x: 0, y: 0, width: panelWidth, height: screenRect.height),
            toolbarFrame: NSRect(x: 0, y: screenRect.height, width: panelWidth, height: barHeight)
        )
    }

    func dismiss() {
        cancellables.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel?.close()
        panel = nil
        if Self.current === self {
            Self.current = nil
        }
    }

    private func done() {
        viewModel.copyToClipboard()
        dismiss()
    }

    private func pin() {
        viewModel.pinToScreen()
        dismiss()
    }
}

private struct ToastOverlay: View {
    @ObservedObject var viewModel: ScreenshotEditorViewModel

    var body: some View {
        if let message = viewModel.toastMessage {
            Text(message)
                .font(AppFont.caption)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
