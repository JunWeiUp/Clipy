import AppKit
import SwiftUI

final class ScreenshotInlineEditor: NSResponder {
    static weak var current: ScreenshotInlineEditor?

    private let viewModel: ScreenshotEditorViewModel
    private let screenRect: NSRect
    private var panel: ScreenshotEditorPanel?
    private var keyMonitor: Any?

    init(image: NSImage, screenRect: NSRect) {
        self.screenRect = screenRect
        self.viewModel = ScreenshotEditorViewModel(image: image)
        super.init()
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
        let placement = toolbarPlacement(barHeight: barHeight)

        let panel = ScreenshotEditorPanel(
            contentRect: placement.panelFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        let chromeView = ScreenshotEditorChromeView(
            viewModel: viewModel,
            toolbarOnTop: placement.toolbarOnTop,
            onDone: { [weak self] in self?.done() },
            onPin: { [weak self] in self?.pin() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        .environmentObject(AppLanguageObserver.shared)

        let hostingController = NSHostingController(rootView: chromeView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        panel.contentViewController = hostingController
        panel.setFrame(placement.panelFrame, display: false)

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(hostingController.view)

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
                self.viewModel.canvasView?.needsDisplay = true
                return nil
            }
            return event
        }
    }

    private struct ToolbarPlacement {
        let panelFrame: NSRect
        let toolbarOnTop: Bool
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
            return ToolbarPlacement(
                panelFrame: NSRect(x: originX, y: belowY, width: panelWidth, height: panelHeight),
                toolbarOnTop: false
            )
        }

        return ToolbarPlacement(
            panelFrame: NSRect(x: originX, y: screenRect.maxY, width: panelWidth, height: panelHeight),
            toolbarOnTop: true
        )
    }

    func dismiss() {
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

private struct ScreenshotEditorChromeView: View {
    @ObservedObject var viewModel: ScreenshotEditorViewModel
    let toolbarOnTop: Bool
    var onDone: () -> Void
    var onPin: () -> Void
    var onDismiss: () -> Void

    @State private var canvasRef: AnnotationCanvasView?

    var body: some View {
        VStack(spacing: 0) {
            if toolbarOnTop {
                toolbar
            }
            canvas
            if !toolbarOnTop {
                toolbar
            }
        }
        .overlay(alignment: toolbarOnTop ? .top : .bottom) {
            if let message = viewModel.toastMessage {
                Text(message)
                    .font(AppFont.caption)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .padding(toolbarOnTop ? .top : .bottom, ScreenshotChrome.barHeight + 8)
            }
        }
        .onAppear {
            viewModel.canvasView = canvasRef
        }
        .onChange(of: canvasRef) { newValue in
            viewModel.canvasView = newValue
        }
    }

    private var canvas: some View {
        AnnotationCanvasRepresentable(
            baseImage: viewModel.baseImage,
            model: viewModel.annotationModel,
            contentMode: .fill,
            canvasRef: $canvasRef
        )
        .frame(
            width: viewModel.baseImage.size.width,
            height: viewModel.baseImage.size.height
        )
    }

    private var toolbar: some View {
        ScreenshotToolbarView(
            viewModel: viewModel,
            barWidth: viewModel.baseImage.size.width,
            onDone: onDone,
            onPin: onPin,
            onDismiss: onDismiss
        )
    }
}
