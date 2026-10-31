import AppKit
import SwiftUI

func runMenuBarPanelRegressionTests() {
    func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    check(DeviceConnectionInput.port("1") == 1 && DeviceConnectionInput.port("65535") == 65535, "valid port boundaries rejected")
    check(DeviceConnectionInput.port(" 5566 ") == 5566, "port whitespace not trimmed")
    for invalid in ["", "0", "65536", "-1", "+80", "1.5", "abc", "999999999999999999999"] {
        check(DeviceConnectionInput.port(invalid) == nil, "invalid port accepted: \(invalid)")
    }
    _ = NSApplication.shared
    runHistoryRowSelectionRegressionTests()
    let homeSize = MenuBarPanelPolicy.preferredSize(page: .home, tab: .clipboard)
    let toolsSize = MenuBarPanelPolicy.preferredSize(page: .home, tab: .tools)
    let devicesSize = MenuBarPanelPolicy.preferredSize(page: .home, tab: .devices)
    let suiteName = "clipy.notification-popup-tests"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    check(NotificationPopupPolicy.isEnabled(suite), "missing popup preference must stay on")
    NotificationPopupPolicy.setEnabled(false, defaults: suite)
    check(!NotificationPopupPolicy.isEnabled(suite), "popup preference did not turn off")
    NotificationPopupPolicy.setEnabled(true, defaults: suite)
    check(NotificationPopupPolicy.isEnabled(suite), "popup preference did not turn back on")
    suite.removePersistentDomain(forName: suiteName)
    check(homeSize == CGSize(width: 520, height: 640), "home panel grew beyond compact size")
    check(toolsSize == homeSize, "switching to tools must preserve the home panel frame")
    check(devicesSize.height < homeSize.height, "sparse devices page did not shrink")
    check(MenuBarPanelPolicy.preferredSize(page: .home, tab: .devices, deviceCount: 1).height == 440,
          "one-device panel retains excessive empty space")
    check(MenuBarPanelPolicy.preferredSize(page: .home, tab: .devices, deviceCount: 50).height == homeSize.height,
          "device tab grew beyond the home panel")
    let window = MenuBarControlPanel(contentRect: CGRect(origin: .zero, size: homeSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
            let frame = MenuBarPanelPolicy.frame(anchor: CGRect(x: bounds.minX + 8, y: bounds.maxY, width: 26, height: 24), visible: bounds, preferred: homeSize)
            let toolsFrame = MenuBarPanelPolicy.frame(anchor: CGRect(x: bounds.minX + 8, y: bounds.maxY, width: 26, height: 24), visible: bounds, preferred: toolsSize)
            check(toolsFrame == frame, "tools tab shifts the panel on constrained screens")
            check(bounds.contains(frame), "panel escapes screen at scale \(scale)")
            check(frame.width <= homeSize.width && frame.height <= homeSize.height, "logical size multiplied by backing scale")
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
    model.query = ""; model.selectTab(.devices)
    check(model.selectableIDs.isEmpty, "device tab exposes stale keyboard selections")
    model.selectTab(.tools)
    check(model.visibleTools == [.capture, .word, .wordBook, .password], "tools dashboard lost a launcher")
    check(model.page == .home, "tools tab hides home navigation")
    model.moveSelection(1)
    check(model.selectedID == "t:capture", "tool keyboard order must start with capture")
    model.moveSelection(1)
    model.moveSelection(1)
    check(model.selectedID == "t:wordBook", "tools are not keyboard selectable")
    var openedWordBook = false
    model.onAction = { if case .wordBook = $0 { openedWordBook = true } }
    model.useSelection()
    check(openedWordBook, "Enter did not open selected tool")
    model.query = L10n.t(.panelToolsWordBook)
    check(model.matchingTools.contains(.wordBook), "search cannot find the visible vocabulary title")
    model.query = ""
    model.useTool(.capture)
    check(model.page == .capture, "capture shortcut did not open detail page")
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
    let englishSamples: [HistoryEntry] = [
        .init(item: .text("Keep the idea. Keep the work moving."), date: Date(), sourceApp: "Notes", contentHash: "fixture-en-1"),
        .init(item: .text("developer.apple.com"), date: Date(), sourceApp: "Safari", contentHash: "fixture-en-2"),
        .init(item: .text("Design review: clearer navigation, simpler actions."), date: Date(), sourceApp: "Mail", contentHash: "fixture-en-3"),
        .init(item: .text("A small detail can make a big difference."), date: Date(), sourceApp: "Notes", contentHash: "fixture-en-4"),
        .init(item: .files([URL(fileURLWithPath: "/tmp/Example/Project brief.pdf")]), date: Date(), sourceApp: "Finder", contentHash: "fixture-en-5"),
        .init(item: .text("hello@example.com"), date: Date(), sourceApp: "Mail", contentHash: "fixture-en-6")
    ]
    final class Provider: MenuBarOverflowProviding {
        func scan(_ context: MenuBarOverflowContext, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowScan {
            let examples = [
                ("Tailscale", "/Applications/Tailscale.app"),
                ("Dropbox", "/Applications/Dropbox.app"),
                ("Docker", "/Applications/Docker.app"),
                ("Calendar", "/System/Applications/Calendar.app"),
                ("Preview", "/System/Applications/Preview.app")
            ]
            return .init(items: examples.enumerated().map { index, example in
                .init(id: .init(pid: 1, launchDate: Date(timeIntervalSince1970: 1), windowID: UInt32(index + 1), ordinal: index),
                      title: example.0, frame: CGRect(x: 0, y: 0, width: 24, height: 24), element: AXUIElementCreateApplication(1), canPress: true,
                      image: NSWorkspace.shared.icon(forFile: example.1))
            }, isComplete: true)
        }
        func press(_ item: MenuBarOverflowItem, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowActivationResult { .unavailable }
    }
    let overflow = MenuBarOverflowManager(provider: Provider(), environment: .init(loadEnabled: { true }, saveEnabled: { _ in }, availability: { nil }, context: {
        .init(geometry: .init(screen: CGRect(x: 0, y: 0, width: 1512, height: 945), barHeight: 24, rightAreaMinX: 800), applications: [], frontPID: nil)
    }, monitorInput: { _ in nil }))
    let model = MenuBarPanelModel(search: { _, _ in
        PreferencesManager.shared.appLanguage == .en ? englishSamples : samples
    })
    model.begin()
    model.folders = [.init(id: UUID(), title: "工作", snippets: [.init(id: UUID(), title: "邮件落款", content: "谢谢，祝工作顺利！", shortcut: nil)])]
    let deviceFixtures: [DeviceEntry] = [
        .init(displayName: "Pixel 9", peerId: "fixture-lan", originalName: "Pixel 9", host: "192.168.1.250", port: 5566),
        .init(displayName: "MacBook Pro with a long device name for layout checks", peerId: "fixture-relay", originalName: "MacBook Pro", host: "relay:fixture", port: 0)
    ]
    model.devices = deviceFixtures
    model.notifications = (1...5).map { index in
        NotificationManager.NotificationEntry(id: "panel-fixture-\(index)", notificationKey: nil,
            packageName: "example.panel.fixture", appName: "示例应用 \(index)",
            title: "设计评审通知 \(index)", subtitle: nil,
            body: "这是一条用于验证通知页面布局的虚构消息。标题下方应紧接通知列表，正文应自动换行，不能在三行后省略。\n" +
                String(repeating: "长通知也应可以完整阅读，更多内容通过列表滚动查看。", count: 4) + "【正文结束】",
            postTime: Date().timeIntervalSince1970, groupKey: nil, isClearable: true, extras: nil)
    }
    model.notificationCount = model.notifications.count
    overflow.refresh()
    let root = MenuBarPanelView(model: model, overflow: overflow, activateIcon: { _ in }).environmentObject(AppLanguageObserver.shared)
    let window = NSPanel(contentRect: CGRect(origin: .zero, size: MenuBarPanelPolicy.preferredSize(page: .home, tab: .clipboard)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .windowBackgroundColor
    let controller = NSHostingController(rootView: root)
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(MenuBarPanelPolicy.preferredSize(page: .home, tab: .clipboard))
    window.center(); window.orderFrontRegardless()
    var step = 0
    let steps = ["light-history", "light-tools", "dark-history", "dark-devices", "english-history", "dark-notifications", "short-notifications", "narrow-history", "light-devices", "english-devices", "empty-devices", "narrow-devices", "dark-tools", "english-tools", "narrow-tools"]
    func prepare() {
        UserDefaults.standard.setVolatileDomain(["appLanguage": step == 4 || step == 9 || step == 13 ? "en" : "zh"], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        // UI localization alone does not translate example clipboard contents.
        // Reload the locale-specific fixture before the next native capture.
        model.refreshHistory()
        let dark = step == 2 || step == 3 || step == 5 || step == 6 || step == 12
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        model.page = step == 5 || step == 6 ? .notifications : .home
        model.tab = step == 1 || step >= 12 ? .tools : (step == 3 || step >= 8 ? .devices : .clipboard)
        model.devices = step == 10 ? [] : deviceFixtures
        var size = MenuBarPanelPolicy.preferredSize(page: model.page, tab: model.tab, deviceCount: model.devices.count)
        if step == 6 { size.height = 420 }
        if step == 7 || step == 11 { size = CGSize(width: 420, height: 560) }
        if step == 14 { size = CGSize(width: 420, height: 690) }
        window.setContentSize(size)
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

/// Renders isolated window fixtures without starting the application or sync.
func runWindowSnapshots() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let directory = ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] else { exit(2) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    UserDefaults.standard.setVolatileDomain(["appLanguage": "zh", "syncRelayDeviceId": "fixture-device", "syncRelayURL": "wss://relay.example", "syncRelayEnabled": false, "syncEnabled": false], forName: UserDefaults.argumentDomain)
    let model = SearchViewModel()
    let now = Date()
    let entries: [HistoryEntry] = [
        .init(item: .text("设计评审纪要 · 周四\n参会：产品、设计、Mac 与 Android 开发。\n• 快速面板：搜索框获得焦点，⌘1–6 直接使用最近条目。\n• 片段：文件夹 / 列表 / 正文三栏，切换时保存草稿。\n下周一前完成高保真稿。"),
              date: now.addingTimeInterval(-60), sourceApp: "备忘录", sourceBundleId: "com.apple.Notes", contentHash: "fixture-window-1",
              isPinned: true, lastUsedAt: now.addingTimeInterval(-40), useCount: 3),
        .init(item: .text("https://figma.example/design/clipy-v2/设计评审-board"), date: now.addingTimeInterval(-360), sourceApp: "Safari",
              sourceBundleId: "com.apple.Safari", contentHash: "fixture-window-2", lastUsedAt: now.addingTimeInterval(-300), useCount: 1),
        .init(item: .image("/nonexistent/fixture-shot.png"), date: now.addingTimeInterval(-600), sourceApp: "Clipy",
              sourceBundleId: "com.clipyclone.fixture", contentHash: "fixture-window-3", searchIndex: "设计评审 board"),
        .init(item: .text("git commit -m \"design: 设计评审修订\" && echo { done }"), date: now.addingTimeInterval(-86_400 - 3_600), sourceApp: "终端",
              sourceBundleId: "com.apple.Terminal", contentHash: "fixture-window-4", useCount: 5),
        .init(item: .files([URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/设计评审素材.zip")]), date: now.addingTimeInterval(-86_400 - 7_200),
              sourceApp: "访达", sourceBundleId: "com.apple.finder", contentHash: "fixture-window-5", useCount: 1),
        .init(item: .text("设计评审时请重点关注：键盘操作、空状态说明、深色模式下的对比度。"), date: now.addingTimeInterval(-2 * 86_400),
              sourceApp: "小米 14", contentHash: "fixture-window-6")
    ]
    model.query = "设计评审"
    model.results = entries.map {
        HistorySearchResult(entry: $0, highlightRanges: HistorySearchRanker.highlightRanges(for: $0.item.title, terms: ["设计评审"]), score: nil)
    }
    model.totalCount = 1284
    model.statusText = L10n.format(.historyShownOfTotal, "\(entries.count)" as NSString, "1,284" as NSString)
    model.selectedIDs = [entries[0].id]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .windowBackgroundColor
    window.isReleasedWhenClosed = false
    // Fictional snippet library (isolated fixture-data store, seeded once).
    if !SnippetManager.shared.folders.contains(where: { $0.title == "工作" && $0.snippets.contains { $0.title == "会议跟进" } }) {
        for folder in SnippetManager.shared.folders { SnippetManager.shared.deleteFolder(id: folder.id) }
        let library: [(String, [(String, String)])] = [
            ("常用回复", [("好的，收到", "好的，收到，我稍后处理。"), ("稍后回复", "我现在不方便，稍后回复你。"),
                        ("感谢", "非常感谢你的帮助！"), ("示例地址", "示例市示例路 1 号")]),
            ("工作", [("会议跟进", "您好，\n\n感谢今天的详细反馈，和大家一起梳理新方向很有收获。\n\n接下来的安排：\n• 优化首次启动流程\n• 周四前分享更新后的原型\n• 约一次简短的团队评审\n\n有任何新的想法，随时在这里补充。\n\n祝好\n示例"),
                    ("项目进展", "本周完成了首版设计稿，下周进入评审。"), ("设计评审", "结束前请确认：交互是否清晰、空状态是否完整。"),
                    ("分享原型", "这是最新原型链接，欢迎直接在上面留言。"), ("每周回顾", "本周进展顺利的是什么？哪里可以改进？")]),
            ("开发", [("新建分支", "git switch -c feat/"), ("调试输出", "print(\"[debug]\", value)"), ("PR 描述", "## 改动\n- \n\n## 验证\n- ")]),
            ("个人", [("邮箱", "someone@example.com"), ("签名", "示例 · 产品设计")]),
        ]
        for (title, snippets) in library {
            SnippetManager.shared.addFolder(title: title)
            guard let id = SnippetManager.shared.folders.last?.id else { continue }
            for snippet in snippets { SnippetManager.shared.addSnippet(to: id, title: snippet.0, content: snippet.1) }
        }
    }
    let snippetModel = SnippetEditorViewModel()
    if let work = SnippetManager.shared.folders.first(where: { $0.title == "工作" }) { snippetModel.selectFolder(work.id) }
    let wordBookURL = URL(fileURLWithPath: directory).appendingPathComponent("fixture-words.json")
    try? FileManager.default.removeItem(at: wordBookURL)
    let wordStore = WordBookStore(fileURL: wordBookURL)
    let wordModel = WordLookupViewModel(wordBook: wordStore)
    // Fictional word book: recent lookups, counts and first/last lookup dates.
    func fixtureWord(_ word: String, _ ipa: String, _ meanings: [(String, String)], _ phrases: [(String, String)] = [],
                     _ examples: [(String, String, String)] = [], _ inflections: [(String, String)] = []) -> WordEntry {
        WordEntry(word: word, americanIPA: ipa, meanings: meanings.map { .init(partOfSpeech: $0.0, definition: $0.1) },
                  phrases: phrases.map { .init(text: $0.0, translation: $0.1) },
                  examples: examples.map { .init(text: $0.0, translation: $0.1, source: $0.2) },
                  inflections: inflections.map { .init(name: $0.0, value: $0.1) })
    }
    let serendipity = fixtureWord("serendipity", "ˌserənˈdɪpəti",
        [("n.", "意外发现珍奇事物的本领；机缘凑巧"), ("n.", "（偶然的）幸运发现；意外之喜")],
        [("by serendipity", "偶然地；机缘巧合地"), ("pure serendipity", "纯属巧合")],
        [("Finding that old letter in the book was pure serendipity.", "在书里发现那封旧信，纯属意外之喜。", "柯林斯例句"),
         ("Many scientific discoveries are a matter of serendipity.", "许多科学发现都源于机缘巧合。", "")],
        [("复数", "serendipities")])
    let fixtureWords: [(WordEntry, Double)] = [
        (fixtureWord("coincidence", "koʊˈɪnsɪdəns", [("n.", "巧合；巧事")]), 5),
        (fixtureWord("resilient", "rɪˈzɪliənt", [("adj.", "有弹性的；能迅速恢复的")]), 4),
        (fixtureWord("nuance", "ˈnuːɑːns", [("n.", "细微差别")]), 3),
        (fixtureWord("meticulous", "məˈtɪkjələs", [("adj.", "一丝不苟的；极其仔细的")]), 2),
        (fixtureWord("ephemeral", "əˈfemərəl", [("adj.", "短暂的；转瞬即逝的")]), 1),
    ]
    for (entry, daysAgo) in fixtureWords { wordStore.record(entry, at: Date().addingTimeInterval(-daysAgo * 86_400)) }
    wordStore.record(serendipity, at: Date().addingTimeInterval(-9 * 86_400))
    wordStore.record(serendipity, at: Date().addingTimeInterval(-3_600))
    wordStore.record(serendipity, at: Date())
    wordModel.showSaved(serendipity)
    let wordNavigation = WordWorkspaceNavigation()
    let passwordModel = PasswordViewModel()
    passwordModel.password = "Example-123!"
    let notificationModel = NotificationViewModel()
    // Fictional phone notifications across two days and several apps.
    let today = Calendar.current.startOfDay(for: Date())
    func fixtureNotification(_ id: Int, _ pkg: String, _ app: String, _ title: String, _ body: String,
                             dayOffset: Int, hour: Int, minute: Int, clearable: Bool = true,
                             subtitle: String? = nil, archived: Bool = false) -> NotificationManager.NotificationEntry {
        let time = today.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3600 + minute * 60))
        return NotificationManager.NotificationEntry(id: "fixture-notification-\(id)", notificationKey: nil,
            packageName: pkg, appName: app, title: title, subtitle: subtitle, body: body,
            postTime: time.timeIntervalSince1970, groupKey: nil, isClearable: clearable, isArchived: archived, extras: nil)
    }
    let fixtureNotifications = [
        fixtureNotification(1, "example.sms", "短信", "106****5521", "【示例银行】您尾号 0000 的卡于今日消费 268.00 元，可用余额 12,840.56 元。如非本人操作，请致电客服。", dayOffset: 0, hour: 15, minute: 40),
        fixtureNotification(2, "example.chat", "微信", "产品设计群", "王工：高保真稿我看过了，设备页的发送入口很清楚。", dayOffset: 0, hour: 15, minute: 36),
        fixtureNotification(3, "example.sms", "短信", "106****0000", "验证码 000000，5 分钟内有效，请勿泄露。", dayOffset: 0, hour: 15, minute: 31),
        fixtureNotification(4, "example.work", "钉钉", "审批通知", "你的“外出申请”已通过，审批人：示例", dayOffset: 0, hour: 14, minute: 58),
        fixtureNotification(5, "example.chat", "微信", "李想", "晚上一起吃饭吗？", dayOffset: 0, hour: 14, minute: 12),
        fixtureNotification(6, "example.parcel", "菜鸟", "包裹待取件", "您的包裹已到示例快递柜，取件码 0-0-0000", dayOffset: 0, hour: 13, minute: 20, clearable: false),
        fixtureNotification(7, "example.chat", "微信", "文件传输助手", "[文件] 评审素材.zip", dayOffset: -1, hour: 21, minute: 40, archived: true),
        fixtureNotification(8, "example.mail", "QQ邮箱", "Re: Clipy 发布计划", "附件为最新排期表，请在周五前确认。", dayOffset: -1, hour: 21, minute: 14),
    ]
    notificationModel.setSnapshot(entries: fixtureNotifications, apps: [
        .init(packageName: "example.chat", appName: "微信", count: 38),
        .init(packageName: "example.sms", appName: "短信", count: 12),
        .init(packageName: "example.work", appName: "钉钉", count: 21),
        .init(packageName: "example.parcel", appName: "菜鸟", count: 9),
        .init(packageName: "example.mail", appName: "QQ邮箱", count: 6),
    ], total: 86)
    notificationModel.selectedIDs = [fixtureNotifications[0].id]
    NotificationManager.shared.bannerApps = ["example.chat", "example.sms"] // in-memory only, never saved
    let steps = ["history-light", "history-dark", "snippets-light", "snippets-dark", "words-light", "words-dark", "notifications-light", "notifications-dark", "settings-general", "devices-lan-light", "settings-permissions", "devices-light", "password-light", "password-dark", "onboarding-light", "onboarding-dark", "onboarding-launch-light", "onboarding-launch-dark", "onboarding-devices-light", "onboarding-devices-dark", "devices-dark", "relay-light", "relay-dark", "settings-general-dark", "devices-lan-dark", "settings-permissions-dark", "settings-search-light", "settings-search-dark", "hub-history-light", "hub-snippets-dark", "hub-devices-light", "hub-notifications-light", "hub-devices-lan-light", "hub-devices-lan-dark", "hub-devices-screen-light", "hub-devices-relaysettings-dark"]
    var step = 0
    func prepare() {
        window.appearance = NSAppearance(named: step % 2 == 0 ? .aqua : .darkAqua)
        var root: AnyView
        if steps[step].hasPrefix("devices-") || steps[step].hasPrefix("relay-") {
            // Devices window fixtures (fictional peers, relay group and connection stats).
            window.appearance = NSAppearance(named: steps[step].hasSuffix("-dark") ? .darkAqua : .aqua)
            root = AnyView(DevicesView(page: steps[step].hasPrefix("relay-") ? .relay : (steps[step].hasPrefix("devices-lan-") ? .lan : .devices)).environmentObject(AppLanguageObserver.shared))
        } else if step < 2 {
            root = AnyView(SearchView(viewModel: model).environmentObject(AppLanguageObserver.shared))
        } else if step < 4 {
            root = AnyView(SnippetEditorView(viewModel: snippetModel).environmentObject(AppLanguageObserver.shared))
        } else if step < 6 {
            root = AnyView(WordWorkspaceView(model: wordModel, navigation: wordNavigation).environmentObject(AppLanguageObserver.shared))
        } else if step < 8 {
            root = AnyView(NotificationView(viewModel: notificationModel).environmentObject(AppLanguageObserver.shared))
        } else if steps[step].hasPrefix("settings-") {
            if steps[step].hasSuffix("-dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if steps[step].hasSuffix("-light") { window.appearance = NSAppearance(named: .aqua) }
            root = AnyView(SettingsView().environmentObject(AppLanguageObserver.shared))
        } else if step == 11 {
            root = AnyView(DevicesView().environmentObject(AppLanguageObserver.shared))
        } else if step < 14 {
            root = AnyView(PasswordGeneratorView(viewModel: passwordModel).environmentObject(AppLanguageObserver.shared))
        } else {
            window.appearance = NSAppearance(named: steps[step].hasSuffix("-dark") ? .darkAqua : .aqua)
            let initialStep = steps[step].contains("-launch-") ? 0 : (steps[step].contains("-devices-") ? 2 : 1)
            root = AnyView(OnboardingView(initialStep: initialStep).environmentObject(AppLanguageObserver.shared))
        }
        if steps[step].hasPrefix("hub-") {
            // Main window: the four modules with the shared section switcher in the sidebar.
            window.appearance = NSAppearance(named: steps[step].hasSuffix("-dark") ? .darkAqua : .aqua)
            let name = steps[step].dropFirst(4).split(separator: "-").first.map(String.init) ?? ""
            let section = MainWindowSection(rawValue: name) ?? .history
            let module: AnyView
            switch section {
            case .history: module = AnyView(SearchView(viewModel: model))
            case .snippets: module = AnyView(SnippetEditorView(viewModel: snippetModel))
            case .devices:
                let target: DevicesPage = steps[step].contains("-lan-") ? .lan : steps[step].contains("-screen-") ? .screenControl : steps[step].contains("-relaysettings-") ? .relaySettings : .devices
                module = AnyView(DevicesView(page: target))
            case .notifications: module = AnyView(NotificationView(viewModel: notificationModel))
            }
            root = AnyView(module.environment(\.mainWindowNavigator, MainWindowNavigator(section: section))
                .environmentObject(AppLanguageObserver.shared))
        }
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = steps[step].hasPrefix("onboarding-") ? [.minSize] : []
        window.contentViewController = controller
        window.setContentSize(step < 12 ? NSSize(width: 1100, height: 680) : NSSize(width: 640, height: 470))
        if steps[step].hasPrefix("devices-") || steps[step].hasPrefix("relay-") { window.setContentSize(NSSize(width: 1136, height: 700)) }
        if steps[step].hasPrefix("words-") { window.setContentSize(NSSize(width: 1112, height: 712)) }
        if steps[step].hasPrefix("password-") { window.setContentSize(NSSize(width: 460, height: 548)) }
        if steps[step].hasPrefix("onboarding-") { window.setContentSize(NSSize(width: 860, height: 580)) }
        if steps[step].hasPrefix("settings-") { window.setContentSize(AppWindowSize.settings) }
        if steps[step].hasPrefix("hub-") { window.setContentSize(MainWindowMetrics.size) }
        window.center()
        window.orderFrontRegardless()
        if steps[step].hasPrefix("settings-search") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: Notification.Name("clipySettingsSnapshotSearch"), object: steps[step].hasSuffix("-dark") ? "快捷键" : "麦克风")
            }
        }
        if steps[step].hasPrefix("settings-permissions") {
            let page = "permissions"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .appSettingsNavigate, object: page)
            }
        }
    }
    prepare()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { timer in
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView, let root = window.contentViewController?.view,
              root.frame.width <= view.bounds.width + 1, root.frame.height <= view.bounds.height + 1,
              root.frame.minX >= -1, root.frame.minY >= -1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(4) }
        do { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(steps[step] + ".png")) } catch { exit(5) }
        step += 1
        if step == steps.count { timer.invalidate(); window.orderOut(nil); exit(0) }
        prepare()
    }
    withExtendedLifetime((model, snippetModel, wordModel, wordNavigation, passwordModel, notificationModel, window, timer)) { app.run() }
    exit(0)
}

private struct HistorySelectionTestHost: View {
    @ObservedObject var model: SearchViewModel
    var body: some View { SearchView(viewModel: model).historyListForTesting }
}

/// Exercise real AppKit mouse dispatch into the draggable SwiftUI rows, using
/// fictional entries only. Model-only tests cannot catch gesture interception.
private func runHistoryRowSelectionRegressionTests() {
    let model = SearchViewModel()
    model.results = (0..<4).map { index in
        HistorySearchResult(entry: HistoryEntry(item: .text(index == 1
            ? "file:///Example/Design/index.html?theme=light"
            : "History click fixture \(index)"), date: Date(), sourceApp: "Fixture", contentHash: "click-\(index)"), highlightRanges: [])
    }
    let ids = model.results.map(\.id)
    model.selectedIDs = [ids[0]]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: HistorySelectionTestHost(model: model))
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
    settle()
    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    guard let table = window.contentView.flatMap(findTable) else { fatalError("History list table missing") }
    // One Today heading, then four entries (including the two-line file URL).
    precondition(table.numberOfRows == 5, "Unexpected history fixture row layout")
    func click(_ entry: Int, x: CGFloat, flags: NSEvent.ModifierFlags = []) {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let currentTable = window.contentView.flatMap(findTable), currentTable.window === window else {
            preconditionFailure("History table is not attached to the fixture window")
        }
        currentTable.scrollRowToVisible(entry + 1)
        currentTable.layoutSubtreeIfNeeded()
        let rect = currentTable.rect(ofRow: entry + 1)
        let point = currentTable.convert(NSPoint(x: x, y: rect.midY), to: nil)
        if ProcessInfo.processInfo.environment["CLIPY_SELECTION_DEBUG_DIR"] != nil {
            fputs("Click entry \(entry), tableChanged=\(currentTable !== table), rect=\(rect), point=\(point)\n", stderr)
        }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: true)
            guard let queued = NSApp.nextEvent(matching: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp,
                until: Date().addingTimeInterval(1), inMode: .default, dequeue: true) else {
                fatalError("History click event was not dispatched")
            }
            NSApp.sendEvent(queued)
        }
        settle()
    }
    func expectSelection(_ expected: Set<HistoryEntry.ID>, _ message: String) {
        let deadline = Date().addingTimeInterval(2)
        while model.selectedIDs != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if model.selectedIDs != expected,
           let directory = ProcessInfo.processInfo.environment["CLIPY_SELECTION_DEBUG_DIR"],
           let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("history-click.png"))
            fputs("Selection indices: \(ids.indices.filter { model.selectedIDs.contains(ids[$0]) }); rows: \(table.numberOfRows)\n", stderr)
        }
        precondition(model.selectedIDs == expected, message)
    }
    click(1, x: 100)
    expectSelection([ids[1]], "Click on draggable URL text failed to select row")
    click(2, x: 43)
    expectSelection([ids[2]], "Click on history icon failed to select row")
    click(1, x: 100, flags: .command)
    expectSelection([ids[1], ids[2]], "Command-click did not toggle once")
    click(3, x: 330, flags: .shift)
    expectSelection(Set(ids[1...3]), "Shift-click lost its anchor")
    click(0, x: 330)
    expectSelection([ids[0]], "Click on row whitespace failed to select row")
    print("History row mouse selection tests passed.")
}
