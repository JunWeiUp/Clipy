import AppKit

final class TransferWindow {
    private var window: HostingWindow<TransferView>?

    func showWindow() {
        if window == nil {
            window = HostingWindow(
                title: L10n.t(.transferStation),
                size: AppWindowSize.list,
                minSize: AppWindowSize.listMin,
                frameAutosaveName: "TransferWindow"
            ) {
                TransferView()
            }
        }
        window?.title = L10n.t(.transferStation)
        window?.show()
    }

    func closeWindow() {
        window?.close()
    }
}

// Keep for drag-drop overlay compatibility if referenced elsewhere
class WindowDragView: NSView {
    var onDrop: ((NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender) ?? false
    }

    override var acceptsFirstResponder: Bool { false }
}
