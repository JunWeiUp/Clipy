import AppKit
import Darwin

enum MemoryFootprintReclaimer {
    static func registerIdleHandlers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            reclaimIfIdle()
        }
        center.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            reclaimIfIdle()
        }
    }

    static func reclaimIfIdle() {
        guard !hasVisibleInteractiveWindows() else { return }
        ClipboardManager.shared.releaseMenuMemory()
        // The CIContext pool can grow large after a screenshot and never shrinks
        // on its own; release it while the app is idle so the footprint recovers.
        ScreenshotImageProcessor.releaseCIContext()
        applyMallocPressure()
    }

    /// Aggressive reclamation after a screenshot flow completes. Screenshots
    /// briefly hold several large bitmaps (full-display capture, cropped copy,
    /// flatten context, PNG encoding); even after those objects are
    /// autoreleased, libmalloc does not return the now-free pages to the system
    /// unless asked. This drops the CIContext pool and nudges every malloc zone
    /// to madvise freed pages back, recovering most of the peak footprint.
    /// Runs off the main thread so the UI never waits on zone compaction.
    static func reclaimAfterScreenshot() {
        DispatchQueue.global(qos: .utility).async {
            // Give the capture pipeline's autorelease pool a runloop tick to
            // drain before we measure/compact.
            ScreenshotImageProcessor.releaseCIContext()
            applyMallocPressure()
        }
    }

    /// Signals memory pressure to the default and purgeable malloc zones so
    /// libmalloc compacts free lists and `madvise`s reusable pages back to the
    /// kernel. Screenshots briefly hold several large bitmaps; once they are
    /// autoreleased the freed pages otherwise stay mapped (RSS does not drop).
    /// Uses only the public `malloc_zone_t.pressure_relief` field and the
    /// public zone accessors. Safe to call periodically; no-op if a zone does
    /// not implement the handler.
    private static func applyMallocPressure() {
        // Default zone handles the bulk of small-object allocations (caches,
        // dictionaries, autorelease pools, etc.) and is the main contributor to
        // the elevated high-water mark after a screenshot.
        applyPressure(to: malloc_default_zone())
        // The purgeable zone holds discardable buffers; ask it to purge too.
        applyPressure(to: malloc_default_purgeable_zone())
    }

    private static func applyPressure(to zone: UnsafeMutablePointer<malloc_zone_t>?) {
        guard let zone else { return }
        // pressure_relief is a public field on malloc_zone_t that asks the zone
        // to release memory it can reclaim. Its return value (bytes freed) is
        // not needed here.
        guard let relief = zone.pointee.pressure_relief else { return }
        _ = relief(zone, 0)
    }

    private static func hasVisibleInteractiveWindows() -> Bool {
        for window in NSApp.windows where window.isVisible {
            if window is NSPanel { continue }
            if NSStringFromClass(type(of: window)).contains("StatusBar") { continue }
            return true
        }
        return false
    }
}
