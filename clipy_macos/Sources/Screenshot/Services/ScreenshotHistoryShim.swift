import AppKit
import Foundation

/// Minimal in-memory screenshot history shim.
///
/// macshot's `DetachedEditorWindowController` calls into `ScreenshotHistory` to
/// persist re-edited captures and read back the latest entry id. clipy1 keeps
/// its own clipboard-history store (`HistoryRepository`), and wiring the editor
/// into it is a host concern — not the screenshot module's job.
///
/// This shim keeps those call sites compiling and provides a thin in-memory
/// record. The host app (via `ScreenshotSessionCoordinator`) is responsible for
/// ingesting captures into the real history, so the shim is intentionally
/// best-effort: `add` returns a generated id and stores nothing persistent.
final class ScreenshotHistory {
    static let shared = ScreenshotHistory()

    /// Lightweight in-memory entry mirror used only to satisfy `entries.first?.id`.
    struct Entry {
        let id: String
    }

    /// In-memory list of ids handed out by `add`. Not the real store.
    private(set) var entries: [Entry] = []

    private init() {}

    @discardableResult
    func add(image: NSImage, rawImage: NSImage? = nil, annotations: [Annotation]? = nil,
             editState: CaptureEditState? = nil) -> String {
        let id = UUID().uuidString
        entries.append(Entry(id: id))
        return id
    }

    func updateEntry(id: String, compositedImage: NSImage, rawImage: NSImage?,
                     annotations: [Annotation]?, editState: CaptureEditState? = nil) {
        // No-op: the host ingests the final composited image via its own pipeline.
    }
}
