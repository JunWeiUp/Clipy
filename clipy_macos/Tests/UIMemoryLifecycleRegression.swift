import AppKit
import ApplicationServices

/// Compile with the normal CLIPY_CORE_TESTS sources, then call this entry point.
/// Injected workers never capture a screen, press AX, launch apps or write fixtures to storage.
func runUIMemoryLifecycleRegressionTests() {
    func awaitCondition(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), message)
    }
    func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    func entry(_ query: String) -> NotificationManager.NotificationEntry {
        .init(id: query, notificationKey: nil, packageName: "fixture", appName: "Fixture",
              title: query, subtitle: nil, body: query, postTime: 0, groupKey: nil,
              isClearable: true, isArchived: false, extras: nil)
    }

    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let releaseSecond = DispatchSemaphore(value: 0)
    let queryLock = NSLock()
    var queries: [String] = []
    let model = NotificationViewModel(searchNotifications: { query, limit in
        precondition(limit == 500, "Notification search lost its 500-row cap")
        queryLock.lock(); queries.append(query); let count = queries.count; queryLock.unlock()
        if count == 1 { firstStarted.signal(); _ = releaseFirst.wait(timeout: .now() + 3) }
        if count == 2 { secondStarted.signal(); _ = releaseSecond.wait(timeout: .now() + 3) }
        return [entry(query)]
    }, initialBannerKeywords: [], initialBlockedKeywords: [])
    model.activateSearchForTesting()
    model.searchText = "A"
    model.flushSearchForTesting()
    precondition(firstStarted.wait(timeout: .now() + 1) == .success)
    model.searchText = "B" // Setter invalidates A immediately, before B's debounce.
    releaseFirst.signal()
    drain()
    precondition(model.filteredEntries.isEmpty, "A backfilled during B debounce")
    model.flushSearchForTesting()
    precondition(secondStarted.wait(timeout: .now() + 1) == .success)
    for index in 0..<100 {
        model.searchText = "queued-\(index)"
        model.flushSearchForTesting()
    }
    queryLock.lock(); let executedBeforeClose = queries; queryLock.unlock()
    precondition(executedBeforeClose == ["A", "B"], "Notification workers were not bounded")
    model.prepareForClose()
    releaseSecond.signal()
    drain()
    queryLock.lock(); let executedAfterClose = queries; queryLock.unlock()
    precondition(executedAfterClose == ["A", "B"] && model.filteredEntries.isEmpty,
                 "Close executed a pending search or accepted a late result")
    model.activateSearchForTesting()
    model.searchText = "A"
    model.flushSearchForTesting()
    awaitCondition("Reopened search did not load") { model.filteredEntries.first?.id == "A" }
    model.prepareForClose()

    // Two subscribers, one decode; cancel one without cancelling the other.
    let decodeStarted = DispatchSemaphore(value: 0)
    let releaseDecode = DispatchSemaphore(value: 0)
    let image = NSImage(size: NSSize(width: 8, height: 8))
    let countLock = NSLock()
    var decodeCount = 0
    let loader = HistoryRowThumbnailLoader { _ in
        countLock.lock(); decodeCount += 1; countLock.unlock()
        decodeStarted.signal()
        _ = releaseDecode.wait(timeout: .now() + 3)
        return image
    }
    let key = HistoryRowThumbnailKey(path: "fixture-a", width: 24, height: 24)
    var delivered = 0
    let first = loader.request(key) { _ in preconditionFailure("Offscreen subscriber was called") }!
    _ = loader.request(key) { result in precondition(result === image); delivered += 1 }
    precondition(decodeStarted.wait(timeout: .now() + 1) == .success)
    loader.cancel(first)
    releaseDecode.signal()
    awaitCondition("Deduplicated thumbnail was not delivered") { delivered == 1 }
    countLock.lock(); let totalDecodes = decodeCount; countLock.unlock()
    precondition(totalDecodes == 1)

    // A recycled row with a new path must reject A and keep B; hidden B must
    // release its bitmap, and a late worker must not refill the state.
    let aStarted = DispatchSemaphore(value: 0), bStarted = DispatchSemaphore(value: 0)
    let releaseA = DispatchSemaphore(value: 0), releaseB = DispatchSemaphore(value: 0)
    let newImage = NSImage(size: NSSize(width: 9, height: 9))
    let stateLoader = HistoryRowThumbnailLoader { request in
        if request.path == "fixture-a" {
            aStarted.signal(); _ = releaseA.wait(timeout: .now() + 3); return image
        }
        bStarted.signal(); _ = releaseB.wait(timeout: .now() + 3); return newImage
    }
    let state = HistoryRowThumbnailState(loader: stateLoader)
    state.show(key)
    precondition(aStarted.wait(timeout: .now() + 1) == .success)
    state.update(.init(path: "fixture-b", width: 24, height: 24))
    precondition(bStarted.wait(timeout: .now() + 1) == .success)
    releaseA.signal()
    drain()
    precondition(state.image == nil, "Old path populated the recycled row")
    state.hide()
    releaseB.signal()
    drain()
    precondition(state.image == nil, "Late thumbnail refilled an offscreen row")

    // Bitmap dimensions, not only NSImage's logical size, must be bounded.
    let source = NSImage(size: NSSize(width: 1024, height: 1024))
    let raster = UIIconRasterizer.rasterize(source, pointSize: 16, scale: 2)!
    precondition(raster.representations.count == 1)
    precondition(raster.representations[0].pixelsWide == 32 && raster.representations[0].pixelsHigh == 32)

    final class Provider: MenuBarOverflowProviding {
        let item: MenuBarOverflowItem
        init(_ item: MenuBarOverflowItem) { self.item = item }
        func scan(_ context: MenuBarOverflowContext, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowScan {
            .init(items: [item], isComplete: true)
        }
        func press(_ item: MenuBarOverflowItem, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowActivationResult {
            .requested
        }
    }
    final class Images: MenuBarOverflowImageLoading {
        var completions: [([MenuBarOverflowIdentity: NSImage]) -> Void] = []
        func load(_ items: [MenuBarOverflowItem], cancellation: MenuBarOverflowCancellation,
                  completion: @escaping ([MenuBarOverflowIdentity: NSImage]) -> Void) {
            completions.append(completion) // Deliberately ignore cancellation.
        }
    }
    let identity = MenuBarOverflowIdentity(pid: 123, launchDate: Date(timeIntervalSince1970: 1), windowID: 1, ordinal: 0)
    let item = MenuBarOverflowItem(id: identity, title: "Fixture", frame: CGRect(x: 0, y: 0, width: 24, height: 24),
                                   element: AXUIElementCreateApplication(123), canPress: true, image: image)
    let geometry = MenuBarOverflowGeometry(screen: CGRect(x: 0, y: 0, width: 1000, height: 800), barHeight: 24, rightAreaMinX: 500)
    let environment = MenuBarOverflowEnvironment(loadEnabled: { true }, saveEnabled: { _ in }, availability: { nil },
        context: { .init(geometry: geometry, applications: [], frontPID: nil) }, monitorInput: { _ in nil })
    let images = Images()
    var fallbackLoads = 0
    let overflow = MenuBarOverflowManager(provider: Provider(item), environment: environment, images: images,
                                         fallbackIcon: { _ in fallbackLoads += 1; return image })
    overflow.refresh()
    awaitCondition("Idle metadata missing") { overflow.items.count == 1 }
    precondition(overflow.items[0].image == nil && fallbackLoads == 0 && images.completions.isEmpty)
    overflow.refreshForMenu()
    awaitCondition("Visible panel did not request images") { images.completions.count == 1 }
    precondition(fallbackLoads == 1)
    overflow.endMenuPresentation()
    precondition(overflow.items.count == 1 && overflow.items[0].image == nil && !overflow.hasRefreshTimer)
    images.completions[0]([identity: newImage])
    precondition(overflow.items[0].image == nil, "Late capture refilled closed panel")
    overflow.refreshForMenu()
    awaitCondition("Reopened panel did not request fresh images") { images.completions.count == 2 }
    images.completions[0]([identity: newImage])
    precondition(overflow.items[0].image !== newImage, "Old presentation capture replaced reopened icon")
    images.completions[1]([identity: newImage])
    precondition(overflow.items[0].image === newImage)
    overflow.endMenuPresentation()
    var activated = false
    overflow.activate(item) { result in activated = result == .requested }
    awaitCondition("Closing the strip broke AX action handoff") { activated }
    overflow.setEnabled(false)
    print("UI memory lifecycle regressions passed (notification debounce/close, thumbnail dedup/path/offscreen, icon pixels, overflow late capture/handoff).")
}
