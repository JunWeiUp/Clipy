import Foundation

/// Minimal directory sweeper shim.
///
/// macshot's `ClipboardBackingStore` uses `DirectorySweeper.sweep(...)` to reap
/// stale clipboard backing files. The full `LaunchCleanup` module (which owns
/// the original) drags in unrelated launch-time cleanup that clipy1 already
/// handles itself, so this slim stand-alone replacement implements just the
/// sweep API the clipboard store relies on: delete files older than `olderThan`
/// for which `shouldDelete` returns true, and report what was removed.
enum DirectorySweeper {
    struct Result {
        var removed: Int = 0
        var bytesFreed: UInt64 = 0
    }

    @discardableResult
    static func sweep(
        directory: URL,
        olderThan: TimeInterval,
        shouldDelete: (URL) -> Bool
    ) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return result }

        let cutoff = Date().addingTimeInterval(-olderThan)
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
            ]), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantFuture
            guard modified < cutoff, shouldDelete(url) else { continue }
            let size = UInt64(values.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                result.removed += 1
                result.bytesFreed += size
            }
        }
        return result
    }
}
