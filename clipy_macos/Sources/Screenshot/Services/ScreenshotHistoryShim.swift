import AppKit
import Foundation

/// Bridges macshot's `ScreenshotHistory` calls onto clipy1's clipboard history.
///
/// macshot's `DetachedEditorWindowController` persists re-edited captures through
/// this type and reads back an entry id to link its floating thumbnail. clipy1
/// has no separate screenshot store, so an entry here is a row in the regular
/// clipboard history: `add` ingests the composited PNG, and `updateEntry`
/// re-ingests the edited version so a save from the editor is actually kept.
@MainActor
final class ScreenshotHistory {
    static let shared = ScreenshotHistory()

    struct Entry {
        let id: String
    }

    /// Ids handed out by `add`, newest last. Bounded because the editor can be
    /// reopened any number of times within one app session.
    private(set) var entries: [Entry] = []
    private static let maxTrackedEntries = 32

    private init() {}

    @discardableResult
    func add(image: NSImage, rawImage: NSImage? = nil, annotations: [Annotation]? = nil,
             editState: CaptureEditState? = nil) -> String {
        let id = UUID().uuidString
        entries.append(Entry(id: id))
        if entries.count > Self.maxTrackedEntries {
            entries.removeFirst(entries.count - Self.maxTrackedEntries)
        }
        ingest(image)
        return id
    }

    func updateEntry(id: String, compositedImage: NSImage, rawImage: NSImage?,
                     annotations: [Annotation]?, editState: CaptureEditState? = nil) {
        // clipy1's history is append-only and de-duplicates by content hash, so
        // an edited capture lands as its own entry rather than mutating the old
        // row. Losing the edit entirely (the previous no-op) was worse.
        ingest(compositedImage)
    }

    private func ingest(_ image: NSImage) {
        guard let pngData = ImageEncoder.encodePNG(image) ?? image.tiffRepresentation else {
            appLog("ScreenshotHistory: failed to encode image for history", level: .warning)
            return
        }
        ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: false)
    }
}
