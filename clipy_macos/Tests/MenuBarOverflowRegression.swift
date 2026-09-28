import AppKit
import ApplicationServices

func runMenuBarOverflowRegressionTests() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), "Menu bar overflow: " + message)
    }
    let geometry = MenuBarOverflowGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                            barHeight: 33, rightAreaMinX: 848)
    check(MenuBarOverflowEnvironment.supportsDisplays(screenCount: 1, onlineDisplayCount: 1, builtIn: true), "built-in screen rejected")
    check(!MenuBarOverflowEnvironment.supportsDisplays(screenCount: 1, onlineDisplayCount: 2, builtIn: true), "mirrored external display not paused")
    check(!MenuBarOverflowEnvironment.supportsDisplays(screenCount: 2, onlineDisplayCount: 2, builtIn: true), "extended display not paused")
    check(!MenuBarOverflowEnvironment.supportsDisplays(screenCount: 1, onlineDisplayCount: 1, builtIn: false), "external-only display accepted")
    check(geometry.isOverflow(CGRect(x: 810, y: 4, width: 36, height: 24), applicationMenuMaxX: 400), "notch occlusion missed")
    check(geometry.isOverflow(CGRect(x: 846, y: 4.5, width: 24, height: 24), applicationMenuMaxX: 400), "two-point notch overlap was incorrectly tolerated")
    let insetButton = CGRect(x: 851, y: 4.5, width: 24, height: 24)
    let hiddenHost = MenuBarSystemBridge.Window(id: 21, frame: CGRect(x: 844, y: 0, width: 38, height: 33))
    let matchedHost = MenuBarSystemBridge.matchedWindow(for: insetButton, in: [hiddenHost])
    check(matchedHost?.id == 21 && geometry.isOverflow(matchedHost!.frame, applicationMenuMaxX: 400), "host window occlusion lost behind an inset AX button")
    check(!geometry.isOverflow(insetButton, applicationMenuMaxX: 400), "test must distinguish inner button from host window")
    check(!geometry.isOverflow(CGRect(x: 900, y: 4, width: 36, height: 24), applicationMenuMaxX: 400), "visible icon included")
    check(geometry.isOverflow(CGRect(x: 900, y: 4, width: 36, height: 24), applicationMenuMaxX: 960), "long application menu ignored")
    check(!geometry.isOverflow(CGRect(x: 0, y: 982, width: 0, height: 0), applicationMenuMaxX: nil), "empty AX placeholder included")
    check(!geometry.isOverflow(CGRect(x: 100, y: 100, width: 36, height: 24), applicationMenuMaxX: nil), "other row included")
    check(!geometry.isOverflow(CGRect(x: 800, y: 0, width: 200, height: 600), applicationMenuMaxX: nil), "ordinary window included")
    check(!geometry.isOverflow(CGRect(x: CGFloat.nan, y: 0, width: 36, height: 24), applicationMenuMaxX: nil), "unknown frame included")
    check(geometry.isOverflow(CGRect(x: -30, y: 0, width: 24, height: 24), applicationMenuMaxX: nil), "offscreen icon missed")
    check(!geometry.isOverflow(CGRect(x: 1480, y: 0, width: 34, height: 33), applicationMenuMaxX: nil), "system edge rounding included")
    let plain = MenuBarOverflowGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), barHeight: 24, rightAreaMinX: 0)
    check(!plain.isOverflow(CGRect(x: 820, y: 0, width: 24, height: 24), applicationMenuMaxX: 500), "space recovery failed")
    check(plain.isOverflow(CGRect(x: 480, y: 0, width: 24, height: 24), applicationMenuMaxX: 500), "non-notch overlap missed")
    // Geometry uses logical points: no backing scale is multiplied into positions.
    let frame = CGRect(x: 900, y: 4.5, width: 36, height: 24)
    let w1 = MenuBarSystemBridge.Window(id: 11, frame: CGRect(x: 901, y: 0, width: 34, height: 33))
    check(MenuBarSystemBridge.window(for: frame, in: [w1]) == 11, "AX/host padding match failed")
    check(MenuBarSystemBridge.window(for: frame, in: [w1, .init(id: 12, frame: w1.frame)]) == nil, "ambiguous window chosen")
    check(MenuBarSystemBridge.window(for: frame, in: []) == nil, "unavailable private API did not fall back")
    let launch = Date(timeIntervalSince1970: 10)
    check(MenuBarOverflowProcessIdentity.launchDate(for: ProcessInfo.processInfo.processIdentifier) != nil, "CLI process identity unavailable")
    check(MenuBarOverflowProcessIdentity.launchDate(for: -1) == nil, "invalid process identity accepted")
    let id = MenuBarOverflowIdentity(pid: 123, launchDate: launch, windowID: 11, ordinal: 0)
    check(id != .init(pid: 123, launchDate: Date(timeIntervalSince1970: 11), windowID: 11, ordinal: 0), "PID reuse aliases an old app")
    check(id != .init(pid: 123, launchDate: launch, windowID: 12, ordinal: 1), "two icons of one app merged")

    let cancellation = MenuBarOverflowCancellation()
    cancellation.cancel()
    let item = MenuBarOverflowItem(id: id, title: "Fixture", frame: frame,
                                  element: AXUIElementCreateApplication(123), canPress: true, image: nil)
    let provider = MenuBarItemProvider()
    check(provider.press(item, cancellation: cancellation) == .cancelled, "cancelled request reached AX")
    var unavailable = item
    unavailable = MenuBarOverflowItem(id: id, title: "Fixture", frame: frame, element: item.element, canPress: false, image: nil)
    check(provider.press(unavailable, cancellation: MenuBarOverflowCancellation()) == .unavailable, "unsupported action accepted")
    let empty = provider.scan(.init(geometry: geometry, applications: [], frontPID: nil), cancellation: cancellation)
    check(empty.items.isEmpty && !empty.isComplete, "cancelled scan claimed completeness")

    func bitmap(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }
    check(!MenuBarOverflowImages.hasVisiblePixels(bitmap { _ in }), "transparent capture replaced fallback icon")
    check(!MenuBarOverflowImages.hasVisiblePixels(bitmap { c in c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }), "blank opaque capture replaced fallback icon")
    check(MenuBarOverflowImages.hasVisiblePixels(bitmap { c in c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 4, y: 4, width: 8, height: 8)) }), "valid template icon rejected")
    runMenuBarOverflowLifecycleTests(item: item, geometry: geometry)
    print("Menu bar overflow regressions passed (notch, logical coordinates, recovery, unknown geometry, hosted windows, stale identity, cancellation, image fallback).")
}

// Optional live integration harness. It creates only disposable test status items;
// no installed app is launched, no real icon is moved, and no defaults are changed.
func runMenuBarOverflowFixture(popover: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    final class Fixture: NSObject, NSMenuDelegate {
        // Wider than the entire usable area: insertion position varies by app identity.
        let item = NSStatusBar.system.statusItem(withLength: (NSScreen.screens.first?.auxiliaryTopRightArea?.width
            ?? NSScreen.screens.first?.frame.width ?? 1600) + 64)
        let popover = NSPopover()
        func menuWillOpen(_ menu: NSMenu) {
            print("FIXTURE_MENU_OPENED"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { menu.cancelTracking() }
        }
        @objc func showPopover() {
            guard let button = item.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            print(popover.isShown ? "FIXTURE_POPOVER_OPENED" : "FIXTURE_POPOVER_FAILED"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.popover.close() }
        }
    }
    let fixture = Fixture()
    fixture.item.button?.title = "Clipy overflow fixture"
    if popover {
        let controller = NSViewController()
        controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 80))
        let label = NSTextField(labelWithString: "Overflow fixture")
        label.frame = CGRect(x: 20, y: 30, width: 180, height: 20)
        controller.view.addSubview(label)
        fixture.popover.contentViewController = controller
        fixture.popover.behavior = .transient
        fixture.item.button?.target = fixture
        fixture.item.button?.action = #selector(Fixture.showPopover)
    } else {
        let menu = NSMenu()
        menu.delegate = fixture
        menu.addItem(NSMenuItem(title: "Overflow fixture", action: nil, keyEquivalent: ""))
        fixture.item.menu = menu
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        NSStatusBar.system.removeStatusItem(fixture.item)
        app.terminate(nil)
    }
    withExtendedLifetime(fixture) { app.run() }
    exit(0)
}

private func runMenuBarOverflowLifecycleTests(item: MenuBarOverflowItem, geometry: MenuBarOverflowGeometry) {
    final class Provider: MenuBarOverflowProviding {
        let scanStarted = DispatchSemaphore(value: 0)
        let releaseScan = DispatchSemaphore(value: 0)
        let pressStarted = DispatchSemaphore(value: 0)
        let releasePress = DispatchSemaphore(value: 0)
        let item: MenuBarOverflowItem
        init(_ item: MenuBarOverflowItem) { self.item = item }
        func scan(_ context: MenuBarOverflowContext, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowScan {
            scanStarted.signal()
            _ = releaseScan.wait(timeout: .now() + 3)
            // Deliberately return a late result even when cancelled to exercise the main-thread guard.
            return .init(items: [item], isComplete: true)
        }
        func press(_ item: MenuBarOverflowItem, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowActivationResult {
            pressStarted.signal()
            _ = releasePress.wait(timeout: .now() + 3)
            return .requested
        }
    }
    func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.08)) }
    var unavailable: MenuBarOverflowStatus?
    var saved = [Bool]()
    let environment = MenuBarOverflowEnvironment(loadEnabled: { true }, saveEnabled: { saved.append($0) },
        availability: { unavailable }, context: { .init(geometry: geometry, applications: [], frontPID: nil) }, monitorInput: { _ in nil })
    let provider = Provider(item)
    let manager = MenuBarOverflowManager(provider: provider, environment: environment)
    manager.refresh()
    precondition(!manager.hasRefreshTimer, "Closed menu started periodic AX scanning")
    precondition(provider.scanStarted.wait(timeout: .now() + 1) == .success)
    manager.refresh() // Must not enqueue a second concurrent scan.
    manager.setEnabled(false)
    provider.releaseScan.signal()
    drain()
    precondition(manager.items.isEmpty && manager.status == .disabled, "Late scan repopulated disabled menu")
    precondition(provider.scanStarted.wait(timeout: .now()) == .timedOut, "Duplicate scan queued")
    precondition(saved == [false], "Unexpected settings write")

    unavailable = .needsPermission
    manager.setEnabled(true)
    precondition(manager.status == .needsPermission && manager.items.isEmpty)
    unavailable = .unsupportedDisplay
    manager.refresh()
    precondition(manager.status == .unsupportedDisplay && manager.items.isEmpty)
    unavailable = .suspended
    manager.refresh()
    precondition(manager.status == .suspended)
    unavailable = nil
    manager.activate(item) { _ in preconditionFailure("Cancelled late activation completed") }
    precondition(provider.pressStarted.wait(timeout: .now() + 1) == .success)
    manager.activate(item) { _ in preconditionFailure("Duplicate activation completed") }
    manager.setEnabled(false)
    provider.releasePress.signal()
    drain()
    precondition(provider.pressStarted.wait(timeout: .now()) == .timedOut, "Duplicate activation queued")
    precondition(manager.status == .disabled && manager.items.isEmpty, "Late activation changed disabled state")

    let snapshotProvider = Provider(item)
    snapshotProvider.releaseScan.signal()
    let snapshotManager = MenuBarOverflowManager(provider: snapshotProvider, environment: environment)
    snapshotManager.refresh()
    precondition(snapshotProvider.scanStarted.wait(timeout: .now() + 1) == .success)
    drain()
    precondition(snapshotManager.items.count == 1, "Initial snapshot not published")
    snapshotManager.workspaceDidChange()
    precondition(snapshotProvider.scanStarted.wait(timeout: .now() + 1) == .success)
    snapshotManager.refreshForMenu()
    precondition(snapshotManager.hasRefreshTimer, "Open menu did not start bounded refresh")
    precondition(snapshotManager.items.count == 1, "Opening the menu after activation cleared the cached icons")
    snapshotManager.endMenuPresentation()
    precondition(!snapshotManager.hasRefreshTimer, "Closing menu retained periodic AX scanning")
    snapshotManager.setEnabled(false)
    snapshotProvider.releaseScan.signal()
    drain()
    precondition(snapshotManager.items.isEmpty && snapshotManager.status == .disabled, "Disable must still clear preserved snapshots")
}

func runMenuBarOverflowLiveTests() {
    precondition(AXIsProcessTrusted(), "Live overflow tests require existing Accessibility permission")
    precondition(NSScreen.screens.count == 1, "Live overflow tests require a single built-in display")
    let screen = NSScreen.screens[0]
    let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    precondition(CGDisplayIsBuiltin(display) != 0)
    let geometry = MenuBarOverflowGeometry(screen: CGDisplayBounds(display), barHeight: max(24, screen.safeAreaInsets.top + 1),
                                            rightAreaMinX: screen.auxiliaryTopRightArea?.minX ?? 0)
    let provider = MenuBarItemProvider()
    for kind in ["menu", "popover"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--clipy-overflow-fixture-" + kind]
        let pipe = Pipe()
        process.standardOutput = pipe
        try! process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var entry: MenuBarOverflowItem?
        var previous: MenuBarOverflowItem?
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while entry == nil && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let observed = NSRunningApplication(processIdentifier: process.processIdentifier)
            if let application = observed, let launch = MenuBarOverflowProcessIdentity.launchDate(for: application.processIdentifier) {
                let context = MenuBarOverflowContext(geometry: geometry,
                    applications: [.init(pid: application.processIdentifier, launchDate: launch, name: "Fixture", icon: application.icon, isControlCenter: false)], frontPID: nil)
                let candidate = provider.scan(context, cancellation: MenuBarOverflowCancellation()).items.first
                // AX may be published before the hosted window finishes its first layout.
                if let candidate, let previous, candidate.frame == previous.frame,
                   candidate.id.windowID == previous.id.windowID { entry = candidate }
                previous = candidate
            }
        }
        guard let entry else { process.terminate(); process.waitUntilExit(); preconditionFailure("Fixture was not found as overflowing") }
        let result = provider.press(entry, cancellation: MenuBarOverflowCancellation())
        print("Live overflow request: \(kind), canPress=\(entry.canPress), matchedWindow=\(entry.id.windowID != nil), result=\(result)"); fflush(stdout)
        precondition(result == .requested || result == .unconfirmed, "AXPress failed")
        while process.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        precondition(output.contains(kind == "menu" ? "FIXTURE_MENU_OPENED" : "FIXTURE_POPOVER_OPENED"), "Original interface did not open")
        precondition(provider.press(entry, cancellation: MenuBarOverflowCancellation()) == .unavailable, "Exited process was accepted")
        print("Live overflow \(kind) passed: detected hosted hidden item, opened original UI, rejected stale item after exit.")
    }
}
