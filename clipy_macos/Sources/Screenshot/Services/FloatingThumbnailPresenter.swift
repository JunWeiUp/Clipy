import AppKit
import Foundation

/// Presents macshot's `FloatingThumbnailController` in the bottom-right corner
/// with stacking, mirroring macshot's AppDelegate behavior.
///
/// macshot shows a draggable thumbnail after every capture/confirm/scroll-done:
/// it slides in from the right, auto-dismisses after a few seconds, and offers
/// hover actions (copy / save / pin / edit / share). This singleton owns the
/// active thumbnail stack and routes the actions back into clipy1's services
/// (ClipboardManager history, PinPanelController, DetachedEditorWindowController).
@MainActor
final class FloatingThumbnailPresenter {
    static let shared = FloatingThumbnailPresenter()
    private init() {}

    /// Active thumbnails, newest last. Bottom-corner thumbnails stack upward.
    private var controllers: [FloatingThumbnailController] = []

    /// Show a thumbnail for a confirmed image in the screen's bottom-right corner.
    /// - Parameters:
    ///   - image: the final (composited) image to thumbnail.
    ///   - annotationData: optional editable raw image + annotations (for re-edit).
    func show(image: NSImage, annotationData: CaptureAnnotationData? = nil) {
        // Honor the user pref (defaults ON, matching macshot).
        let enabled = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        guard enabled else { return }

        // Stacking (default ON): keep prior thumbnails, stack upward.
        // Replace mode: dismiss existing first.
        let stacking = UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool ?? true
        if !stacking {
            controllers.forEach { $0.dismiss() }
            controllers.removeAll()
        }

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let corner = FloatingThumbnailCorner.bottomRight
        let thumbSize = FloatingThumbnailController.currentThumbnailSize()

        // X anchored to the right edge.
        let xOrigin = screenFrame.maxX - thumbSize.width - padding

        // Bottom corner: first thumbnail sits at the bottom; later ones stack up.
        var yOrigin = screenFrame.minY + padding
        if let top = controllers.last {
            yOrigin = top.windowFrame.maxY + gap
        }

        let controller = FloatingThumbnailController(image: image)
        controller.annotationData = annotationData
        controller.onDismiss = { [weak self] in
            guard let self = self else { return }
            self.controllers.removeAll { $0 === controller }
            self.reflow()
        }
        controller.onCopy = { [weak controller] in
            guard let img = controller?.image else { return }
            ImageEncoder.copyToClipboard(img)
        }
        controller.onSave = { [weak controller] in
            guard let img = controller?.image else { return }
            if let data = ImageEncoder.encodePNG(img) {
                _ = ScreenshotSaveService.save(pngData: data)
            }
        }
        controller.onSaveAs = { [weak controller] in
            guard let img = controller?.image else { return }
            _ = ScreenshotSaveService.save(image: img)
        }
        controller.onPin = { [weak controller] in
            guard let img = controller?.image else { return }
            // clipy1's pin (history-aware). skipIngest since it's already in history.
            PinPanelController.shared.pin(image: img, at: nil, skipIngest: true)
        }
        controller.onEdit = { [weak controller] in
            guard let img = controller?.image else { return }
            NSApp.activate(ignoringOtherApps: true)
            DetachedEditorWindowController.open(image: img, fromCapture: false)
        }
        controller.show(at: NSPoint(x: xOrigin, y: yOrigin), corner: corner)
        controllers.append(controller)
    }

    /// Restack remaining thumbnails after one is dismissed.
    private func reflow() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        var y = screenFrame.minY + padding
        for controller in controllers {
            let frame = controller.windowFrame
            let newOrigin = NSPoint(x: frame.minX, y: y)
            controller.moveTo(origin: newOrigin)
            y = frame.height + gap + y
        }
    }
}
