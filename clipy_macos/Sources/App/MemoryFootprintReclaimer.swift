import AppKit
import Darwin

enum MemoryFootprintReclaimer {

    /// Serializes access to `pendingDelayedReclaim`; callers come from any thread.
    private static let schedulerQueue = DispatchQueue(label: "com.clipy.memory-reclaim", qos: .utility)
    private static var pendingDelayedReclaim: DispatchWorkItem?
    private static var pendingFinalReclaim: DispatchWorkItem?

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
        releaseOverlayPool()
        // The CIContext pools can grow large after a screenshot and never shrink
        // on their own; release them while the app is idle so the footprint
        // recovers. ScreenshotImageProcessor, ImageEffects and Annotation each
        // hold their own CIContext (30-80MB of IOSurface/texture pool per
        // context after a 4K render).
        ScreenshotImageProcessor.releaseCIContext()
        ImageEffects.releaseContext()
        Annotation.releaseContext()
        OverlayView.releaseOutlineGlowContext()
        ScreenCaptureManager.releaseCachedContent()
        applyMallocPressure()
    }

    /// Debounced second-pass reclaim. The tail of a capture flow (PNG
    /// re-encode for history ingest, floating-thumbnail offload, boundary-snap
    /// index build) allocates several more full-screen buffers AFTER
    /// `reclaimAfterScreenshot` already ran at overlay teardown, and this
    /// LSUIElement app never receives didResignActive/didHide — so without a
    /// second pass the freed dirty pages and the re-created CIContext pools
    /// stay in the footprint forever (observed ~400MB after one 4K capture).
    /// A final third pass follows at +35s: history OCR runs on a serial
    /// utility queue and regularly outlives the 10s pass — it is the last big
    /// allocator (Vision loads models + staging buffers on first use).
    static func scheduleDelayedReclaim(after seconds: TimeInterval = 10) {
        schedulerQueue.async {
            pendingDelayedReclaim?.cancel()
            let item = DispatchWorkItem {
                // The capture session has been quiet for `seconds`: the warm
                // overlay pool (fullscreen layer backing per screen) is now
                // pure overhead, not a fast-next-capture win.
                releaseOverlayPool()
                reclaimAfterScreenshot()
            }
            pendingDelayedReclaim = item
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + seconds, execute: item)

            pendingFinalReclaim?.cancel()
            let final = DispatchWorkItem {
                releaseOverlayPool()
                reclaimAfterScreenshot()
                logMemoryBreakdown(tag: "settled")
            }
            pendingFinalReclaim = final
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + seconds + 35, execute: final)
        }
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
            let before = currentFootprintBytes()
            ScreenshotImageProcessor.releaseCIContext()
            ImageEffects.releaseContext()
            Annotation.releaseContext()
            OverlayView.releaseOutlineGlowContext()
            ScreenCaptureManager.releaseCachedContent()
            applyMallocPressure()
            if let before, let after = currentFootprintBytes() {
                // Always log, including the freed == 0 case: a silent zero is
                // itself the diagnostic (stuck memory lives outside the
                // managed pools — see logMemoryBreakdown).
                appLog("Memory: reclaim footprint \(before) -> \(after) bytes (freed \(before - after))", level: .info)
            }
        }
    }

    /// One-line memory breakdown for post-capture diagnosis: the Activity
    /// Monitor number plus the anonymous/compressed split and the top malloc
    /// zones, so a stuck footprint can be attributed to heap vs framework
    /// (IOSurface/Vision/SCK) memory. Cheap enough to call after captures.
    static func logMemoryBreakdown(tag: String) {
        DispatchQueue.global(qos: .utility).async {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            var line = "Memory[\(tag)]:"
            if kr == KERN_SUCCESS {
                line += " footprint=\(mb(info.phys_footprint))MB"
                line += " anonymous=\(mb(info.internal))MB"
                line += " compressed=\(mb(info.compressed))MB"
                line += " residentPeak=\(mb(info.resident_size_peak))MB"
            }
            line += " | zones: " + topMallocZones().joined(separator: ", ")
            appLog(line, level: .info)
        }
    }

    /// Each pooled overlay controller keeps a fullscreen layer-backed panel +
    /// the whole overlay view tree alive (its backing store still holds the
    /// last captured frame, ~33-70MB per Retina screen). The pool only exists
    /// to make the *next* capture instant; releasing it while idle trades a
    /// few ms of panel re-creation for the memory.
    private static func releaseOverlayPool() {
        Task { @MainActor in
            ScreenshotSessionCoordinator.shared.releaseIdleOverlayPool()
        }
    }

    /// task_vm_info.phys_footprint — the same number Activity Monitor's
    /// "Memory" column shows. Used to verify reclaims in the log.
    private static func currentFootprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }

    // MARK: - Malloc zones

    /// Signals memory pressure to the default + purgeable malloc zones so
    /// libmalloc compacts free lists and `madvise`s reusable pages back to the
    /// kernel. Screenshots briefly hold several large bitmaps; once they are
    /// autoreleased the freed pages otherwise stay mapped (RSS does not drop).
    ///
    /// Framework-private zones (Vision, CoreVideo, ColorSync) cannot be pressed:
    /// the buffer-out `malloc_get_all_zones` is broken on this OS (it hands
    /// back a pointer to zeroed memory, not zone structs — calling
    /// `malloc_zone_statistics` on it SEGVs), and no other public API
    /// enumerates zones. The settle breakdown attributes what that floor is.
    private static func applyMallocPressure() {
        applyPressure(to: malloc_default_zone())
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

    /// In-use sizes of the directly reachable zones, for the breakdown log
    /// line. `zone_name`/`statistics` come from the live zone structs obtained
    /// via the public accessors — never from `malloc_get_all_zones`, which
    /// returns garbage on this OS (see applyMallocPressure).
    private static func topMallocZones() -> [String] {
        var stats: [(name: String, inUse: Int64)] = []
        for zone in [malloc_default_zone(), malloc_default_purgeable_zone()] {
            guard let zone,
                  let introspect = zone.pointee.introspect,
                  introspect.pointee.statistics != nil else { continue }
            var s = malloc_statistics_t()
            malloc_zone_statistics(zone, &s)
            let name = zone.pointee.zone_name.map { String(cString: $0) } ?? "zone"
            stats.append((name, Int64(s.size_in_use)))
        }
        return stats.map { "\($0.name)=\(mb(UInt64($0.inUse)))MB" }
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
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
