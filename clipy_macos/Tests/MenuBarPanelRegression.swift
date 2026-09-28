import AppKit
import SwiftUI

func runMenuBarPanelRegressionTests() {
    func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    _ = NSApplication.shared
    let window = MenuBarControlPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 716), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    check(window.styleMask.contains(.nonactivatingPanel) && !window.canBecomeMain && window.canBecomeKey, "panel steals main-window ownership")
    window.menuDepth = 1
    check(!window.canBecomeKey, "panel fights native menu key ownership")
    window.menuDepth = 0
    let ids = ["first", "second", "third"]
    check(MenuBarPanelPolicy.nextSelection(ids: ids, selected: nil, delta: -1) == "third", "initial up must select last")
    check(MenuBarPanelPolicy.nextSelection(ids: ids, selected: "third", delta: 1) == "first", "navigation does not wrap")
    check(MenuBarPanelPolicy.nextSelection(ids: [], selected: nil, delta: 1) == nil, "empty selection")
    for scale in [1.0, 2.0] {
        for bounds in [CGRect(x: 0, y: 0, width: 1512, height: 945), CGRect(x: -1280, y: 50, width: 1280, height: 650), CGRect(x: 0, y: 0, width: 420, height: 580)] {
            let frame = MenuBarPanelPolicy.frame(anchor: CGRect(x: bounds.minX + 8, y: bounds.maxY, width: 26, height: 24), visible: bounds, preferred: CGSize(width: 560, height: 716))
            check(bounds.contains(frame), "panel escapes screen at scale \(scale)")
            check(frame.width <= 560 && frame.height <= 716, "logical size multiplied by backing scale")
        }
    }
    func canPaste(ticket: UInt64 = 2, version: Int = 9, target: pid_t? = 42, front: pid_t? = 42, visible: Bool = false, key: Bool = false) -> Bool {
        MenuBarPanelPolicy.mayPaste(ticket: ticket, current: 2, copiedVersion: 9, currentVersion: version,
                                   targetPID: target, frontPID: front, panelVisible: visible, hasKeyWindow: key)
    }
    check(canPaste(), "legitimate paste rejected")
    check(!canPaste(ticket: 1), "late paste after reopen")
    check(!canPaste(version: 10), "paste overwrote newer clipboard")
    check(!canPaste(front: 43), "paste sent to another app")
    check(!canPaste(target: nil, front: nil), "missing caller accepted")
    check(!canPaste(visible: true), "paste into own panel")
    check(!canPaste(key: true), "paste into another Clipy window")

    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    func entry(_ value: String) -> HistoryEntry {
        .init(item: .text(value), date: Date(timeIntervalSince1970: 1), sourceApp: nil, contentHash: value)
    }
    let model = MenuBarPanelModel(search: { options, token in
        if options.query == "slow" { started.signal(); _ = finish.wait(timeout: .now() + 3) }
        return [entry(options.query.isEmpty ? "recent" : options.query)]
    })
    func spin(_ condition: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(condition(), "panel async query timed out")
    }
    model.begin(); spin { !model.loading }
    model.query = "slow"
    check(started.wait(timeout: .now() + 2) == .success, "slow query never began")
    model.query = "latest"
    check(model.history.isEmpty && model.selectedID == nil, "old query remains executable")
    finish.signal(); spin { !model.loading }
    check(model.history.first?.contentHash == "latest", "late response overwrites current query")
    model.query = "discard"
    model.end()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    check(model.history.isEmpty && !model.loading, "closed panel retained query results")
    model.begin(); spin { !model.loading }
    check(model.history.first?.contentHash == "recent", "reopen leaked last query")
    let folder = UUID(), other = UUID()
    let snippet = Snippet(id: UUID(), title: "Find me", content: "text", shortcut: nil)
    model.folders = [SnippetFolder(id: folder, title: "A", snippets: [snippet]), SnippetFolder(id: other, title: "B", snippets: [])]
    model.folderID = other
    check(model.visibleSnippets.isEmpty, "folder filter ignored")
    model.query = "Find"
    check(model.visibleSnippets.count == 1, "global search is limited by old folder")
    model.query = ""; model.selectTab(.tools)
    model.moveSelection(1)
    check(model.selectedID == "t:capture", "tools are not keyboard selectable")
    model.useSelection()
    check(model.page == .capture, "Enter did not open selected tool")
    model.escape(); check(model.page == .home, "Escape did not leave detail page")
    model.end()
    print("Menu bar panel regressions passed (geometry, keyboard, focus/clipboard guards, stale searches, close/reopen, global snippet search).")
}

/// Optional app-owned render fixture: fictional content only, no live clipboard,
/// AX actions, status items, device discovery or changes to installed app data.
func runMenuBarPanelSnapshot() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let directory = ProcessInfo.processInfo.environment["CLIPY_PANEL_SNAPSHOT_DIR"] else { exit(2) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let samples: [HistoryEntry] = [
        .init(item: .text("把想法留住，让工作继续。"), date: Date(), sourceApp: "Notes", contentHash: "fixture-1"),
        .init(item: .text("developer.apple.com"), date: Date(), sourceApp: "Safari", contentHash: "fixture-2"),
        .init(item: .text("设计讨论：入口更清晰，操作更直接"), date: Date(), sourceApp: "Mail", contentHash: "fixture-3"),
        .init(item: .text("A small detail can make a big difference."), date: Date(), sourceApp: "Notes", contentHash: "fixture-4"),
        .init(item: .files([URL(fileURLWithPath: "/tmp/Example/项目说明.pdf")]), date: Date(), sourceApp: "Finder", contentHash: "fixture-5"),
        .init(item: .text("hello@example.com"), date: Date(), sourceApp: "Mail", contentHash: "fixture-6")
    ]
    final class Provider: MenuBarOverflowProviding {
        func scan(_ context: MenuBarOverflowContext, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowScan {
            .init(items: ["Tailscale", "Dropbox", "Docker"].enumerated().map { index, name in
                .init(id: .init(pid: 1, launchDate: Date(timeIntervalSince1970: 1), windowID: UInt32(index + 1), ordinal: index),
                      title: name, frame: CGRect(x: 0, y: 0, width: 24, height: 24), element: AXUIElementCreateApplication(1), canPress: true,
                      image: NSWorkspace.shared.icon(forFile: "/Applications/\(name).app"))
            }, isComplete: true)
        }
        func press(_ item: MenuBarOverflowItem, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowActivationResult { .unavailable }
    }
    let overflow = MenuBarOverflowManager(provider: Provider(), environment: .init(loadEnabled: { true }, saveEnabled: { _ in }, availability: { nil }, context: {
        .init(geometry: .init(screen: CGRect(x: 0, y: 0, width: 1512, height: 945), barHeight: 24, rightAreaMinX: 800), applications: [], frontPID: nil)
    }, monitorInput: { _ in nil }))
    let model = MenuBarPanelModel(search: { _, _ in samples })
    model.begin()
    model.folders = [.init(id: UUID(), title: "工作", snippets: [.init(id: UUID(), title: "邮件落款", content: "谢谢，祝工作顺利！", shortcut: nil)])]
    model.devices = [.init(displayName: "Pixel 9", peerId: "fixture", originalName: "Pixel 9")]
    model.notifications = (1...5).map { index in
        NotificationManager.NotificationEntry(id: "panel-fixture-\(index)", notificationKey: nil,
            packageName: "example.panel.fixture", appName: "示例应用 \(index)",
            title: "设计评审通知 \(index)", subtitle: nil,
            body: "这是一条用于验证通知页面布局的虚构消息。标题下方应紧接通知列表，正文应自动换行，不能在三行后省略。\n" +
                String(repeating: "长通知也应可以完整阅读，更多内容通过列表滚动查看。", count: 4) + "【正文结束】",
            postTime: Date().timeIntervalSince1970, groupKey: nil, isClearable: true, extras: nil)
    }
    model.notificationCount = model.notifications.count
    let usage = TokenCounts(input: 182_400, output: 28_600, cacheRead: 94_000)
    TokenUsageManager.shared.setPreview(
        report: TokenUsageReport(
            lines: [TokenUsageLine(id: "panel-fixture-usage", day: TokenUsageFormat.day(Date()),
                                   agent: .codex, model: "sample-model", counts: usage,
                                   estimatedUSD: 1.8425, unpricedEvents: 0)],
            days: [TokenUsageDay(day: TokenUsageFormat.day(Date()), counts: usage,
                                estimatedUSD: 1.8425, unpricedEvents: 0)]),
        statuses: [:])
    overflow.refresh()
    let root = MenuBarPanelView(model: model, overflow: overflow, activateIcon: { _ in }).environmentObject(AppLanguageObserver.shared)
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 716), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .windowBackgroundColor
    let controller = NSHostingController(rootView: root)
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(CGSize(width: 560, height: 716))
    window.center(); window.orderFrontRegardless()
    var step = 0
    let steps = ["light-history", "light-tools", "dark-history", "dark-devices", "english-history", "dark-notifications", "short-notifications"]
    func prepare() {
        UserDefaults.standard.setVolatileDomain(["appLanguage": step == 4 ? "en" : "zh"], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        let dark = step == 2 || step == 3 || step >= 5
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(CGSize(width: 560, height: step == 6 ? 580 : 716))
        model.page = step >= 5 ? .notifications : step == 3 ? .devices : .home
        model.tab = step == 1 ? .tools : .clipboard
        model.selectedID = step == 0 || step == 2 ? "h:" + samples[0].id : nil
    }
    prepare()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { timer in
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(4) }
        do { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(steps[step] + ".png")) } catch { exit(5) }
        step += 1
        if step == steps.count { timer.invalidate(); window.orderOut(nil); print("Native panel snapshots saved."); exit(0) }
        prepare()
    }
    withExtendedLifetime((model, overflow, window, timer)) { app.run() }
    exit(0)
}
