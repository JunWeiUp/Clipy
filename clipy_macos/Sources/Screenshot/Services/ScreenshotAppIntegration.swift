import AppKit
import Foundation

/// Integration seam between the screenshot module and the host app.
///
/// macshot's `DetachedEditorWindowController` forwards lifecycle events to its
/// `AppDelegate` (show floating thumbnail, refresh history, focus the previous
/// app, pin, upload). clipy1 has no such AppDelegate, so this protocol lets the
/// host app opt into whichever callbacks it cares about. Conformance is
/// optional — every method has a default no-op, so the editor compiles and runs
/// even when the host implements none of them.
@MainActor
protocol ScreenshotAppIntegration: AnyObject {
    func returnFocusIfNeeded()
    func refreshThumbnail(for entryID: String, image: NSImage, annotationData: CaptureAnnotationData?)
    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData?, historyEntryID: String?)
    func showPin(image: NSImage)
    func uploadImage(_ image: NSImage)
}

extension ScreenshotAppIntegration {
    func returnFocusIfNeeded() {}
    func refreshThumbnail(for entryID: String, image: NSImage, annotationData: CaptureAnnotationData?) {}
    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData?, historyEntryID: String?) {}
    func showPin(image: NSImage) {}
    func uploadImage(_ image: NSImage) {}
}

/// Resolve the host app delegate as a `ScreenshotAppIntegration`, if it conforms.
/// Returns nil (and therefore no-ops all calls) when the host doesn't conform,
/// which keeps the editor self-contained.
@MainActor
func screenshotAppIntegration() -> ScreenshotAppIntegration? {
    NSApp.delegate as? ScreenshotAppIntegration
}
