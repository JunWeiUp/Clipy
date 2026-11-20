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
    // CLIPY_SNAPSHOT_LANGUAGE=en renders the same windows with English fixtures (README pairs).
    let isEnglish = ProcessInfo.processInfo.environment["CLIPY_SNAPSHOT_LANGUAGE"] == "en"
    func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
    UserDefaults.standard.setVolatileDomain(["appLanguage": isEnglish ? "en" : "zh", "syncRelayDeviceId": "fixture-device", "syncRelayURL": "wss://relay.example", "syncRelayEnabled": false, "syncEnabled": false], forName: UserDefaults.argumentDomain)
    let model = SearchViewModel()
    let now = Date()
    let entries: [HistoryEntry] = [
        .init(item: .text(t("设计评审纪要 · 周四\n参会：产品、设计、Mac 与 Android 开发。\n• 快速面板：搜索框获得焦点，⌘1–6 直接使用最近条目。\n• 片段：文件夹 / 列表 / 正文三栏，切换时保存草稿。\n下周一前完成高保真稿。", "Design review notes · Thursday\nAttendees: product, design, Mac and Android.\n• Quick panel: search field focused, ⌘1–6 pastes recent items.\n• Snippets: folders / list / editor in three columns, drafts saved on switch.\nHigh-fidelity mockups due Monday.")),
              date: now.addingTimeInterval(-60), sourceApp: t("备忘录", "Notes"), sourceBundleId: "com.apple.Notes", contentHash: "fixture-window-1",
              isPinned: true, lastUsedAt: now.addingTimeInterval(-40), useCount: 3),
        .init(item: .text(t("https://figma.example/design/clipy-v2/设计评审-board", "https://figma.example/design/clipy-v2/design-review-board")), date: now.addingTimeInterval(-360), sourceApp: "Safari",
              sourceBundleId: "com.apple.Safari", contentHash: "fixture-window-2", lastUsedAt: now.addingTimeInterval(-300), useCount: 1),
        .init(item: .image("/nonexistent/fixture-shot.png"), date: now.addingTimeInterval(-600), sourceApp: "Clipy",
              sourceBundleId: "com.clipyclone.fixture", contentHash: "fixture-window-3", searchIndex: t("设计评审 board", "design review board")),
        .init(item: .text(t("git commit -m \"design: 设计评审修订\" && echo { done }", "git commit -m \"design: design review fixes\" && echo { done }")), date: now.addingTimeInterval(-86_400 - 3_600), sourceApp: t("终端", "Terminal"),
              sourceBundleId: "com.apple.Terminal", contentHash: "fixture-window-4", useCount: 5),
        .init(item: .files([URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/" + t("设计评审素材.zip", "design-review-assets.zip"))]), date: now.addingTimeInterval(-86_400 - 7_200),
              sourceApp: t("访达", "Finder"), sourceBundleId: "com.apple.finder", contentHash: "fixture-window-5", useCount: 1),
        .init(item: .text(t("设计评审时请重点关注：键盘操作、空状态说明、深色模式下的对比度。", "For the design review, focus on keyboard flow, empty states and dark-mode contrast.")), date: now.addingTimeInterval(-2 * 86_400),
              sourceApp: t("小米 14", "Pixel 9"), contentHash: "fixture-window-6")
    ]
    let query = t("设计评审", "design review")
    model.query = query
    model.results = entries.map {
        HistorySearchResult(entry: $0, highlightRanges: HistorySearchRanker.highlightRanges(for: $0.item.title, terms: query.split(separator: " ").map(String.init)), score: nil)
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
    if !SnippetManager.shared.folders.contains(where: { $0.title == t("工作", "Work") && $0.snippets.contains { $0.title == t("会议跟进", "Meeting follow-up") } }) {
        for folder in SnippetManager.shared.folders { SnippetManager.shared.deleteFolder(id: folder.id) }
        let zhLibrary: [(String, [(String, String)])] = [
            ("常用回复", [("好的，收到", "好的，收到，我稍后处理。"), ("稍后回复", "我现在不方便，稍后回复你。"),
                        ("感谢", "非常感谢你的帮助！"), ("示例地址", "示例市示例路 1 号")]),
            ("工作", [("会议跟进", "您好，\n\n感谢今天的详细反馈，和大家一起梳理新方向很有收获。\n\n接下来的安排：\n• 优化首次启动流程\n• 周四前分享更新后的原型\n• 约一次简短的团队评审\n\n有任何新的想法，随时在这里补充。\n\n祝好\n示例"),
                    ("项目进展", "本周完成了首版设计稿，下周进入评审。"), ("设计评审", "结束前请确认：交互是否清晰、空状态是否完整。"),
                    ("分享原型", "这是最新原型链接，欢迎直接在上面留言。"), ("每周回顾", "本周进展顺利的是什么？哪里可以改进？")]),
            ("开发", [("新建分支", "git switch -c feat/"), ("调试输出", "print(\"[debug]\", value)"), ("PR 描述", "## 改动\n- \n\n## 验证\n- ")]),
            ("个人", [("邮箱", "someone@example.com"), ("签名", "示例 · 产品设计")]),
        ]
        let enLibrary: [(String, [(String, String)])] = [
            ("Quick replies", [("Got it", "Got it, I will take care of it shortly."), ("Reply later", "I can't talk right now, I'll get back to you soon."),
                        ("Thanks", "Thanks a lot for your help!"), ("Sample address", "1 Example Street, Sample City")]),
            ("Work", [("Meeting follow-up", "Hi team,\n\nThanks for the detailed feedback today. It was great to shape the new direction together.\n\nNext steps:\n• Polish the first-launch flow\n• Share the updated prototype by Thursday\n• Schedule a short team review\n\nAdd any new ideas here at any time.\n\nBest,\nAlex"),
                    ("Project update", "The first design draft is done; review starts next week."), ("Design review", "Before we wrap up: is the interaction clear and are empty states covered?"),
                    ("Share prototype", "Here is the latest prototype link. Feel free to comment directly."), ("Weekly retro", "What went well this week? What could be better?")]),
            ("Dev", [("New branch", "git switch -c feat/"), ("Debug print", "print(\"[debug]\", value)"), ("PR template", "## Changes\n- \n\n## Verification\n- ")]),
            ("Personal", [("Email", "someone@example.com"), ("Signature", "Alex · Product Design")]),
        ]
        let library = isEnglish ? enLibrary : zhLibrary
        for (title, snippets) in library {
            SnippetManager.shared.addFolder(title: title)
            guard let id = SnippetManager.shared.folders.last?.id else { continue }
            for snippet in snippets { SnippetManager.shared.addSnippet(to: id, title: snippet.0, content: snippet.1) }
        }
    }
    let snippetModel = SnippetEditorViewModel()
    if let work = SnippetManager.shared.folders.first(where: { $0.title == t("工作", "Work") }) { snippetModel.selectFolder(work.id) }
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
        [("n.", t("意外发现珍奇事物的本领；机缘凑巧", "the faculty of making fortunate discoveries by accident")), ("n.", t("（偶然的）幸运发现；意外之喜", "a happy accident; a pleasant surprise"))],
        [("by serendipity", t("偶然地；机缘巧合地", "by happy chance")), ("pure serendipity", t("纯属巧合", "sheer luck"))],
        [("Finding that old letter in the book was pure serendipity.", t("在书里发现那封旧信，纯属意外之喜。", "Finding that old letter in the book was a happy accident."), t("柯林斯例句", "Collins")),
         ("Many scientific discoveries are a matter of serendipity.", t("许多科学发现都源于机缘巧合。", "Many discoveries in science came about by chance."), "")],
        [(t("复数", "Plural"), "serendipities")])
    let fixtureWords: [(WordEntry, Double)] = [
        (fixtureWord("coincidence", "koʊˈɪnsɪdəns", [("n.", t("巧合；巧事", "a chance occurrence"))]), 5),
        (fixtureWord("resilient", "rɪˈzɪliənt", [("adj.", t("有弹性的；能迅速恢复的", "able to recover quickly"))]), 4),
        (fixtureWord("nuance", "ˈnuːɑːns", [("n.", t("细微差别", "a subtle difference"))]), 3),
        (fixtureWord("meticulous", "məˈtɪkjələs", [("adj.", t("一丝不苟的；极其仔细的", "showing great attention to detail"))]), 2),
        (fixtureWord("ephemeral", "əˈfemərəl", [("adj.", t("短暂的；转瞬即逝的", "lasting a very short time"))]), 1),
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
    let fixtureNotifications = isEnglish ? [
        fixtureNotification(1, "example.sms", "Messages", "Example Bank", "Your card ending 0000 was charged $26.80 today. Available balance $1,284.56. Not you? Call support.", dayOffset: 0, hour: 15, minute: 40),
        fixtureNotification(2, "example.chat", "WhatsApp", "Design team", "Sam: Reviewed the hi-fi mockups. The send button on Devices is really clear.", dayOffset: 0, hour: 15, minute: 36),
        fixtureNotification(3, "example.sms", "Messages", "Example Service", "Your code is 000000. It expires in 5 minutes. Do not share it.", dayOffset: 0, hour: 15, minute: 31),
        fixtureNotification(4, "example.work", "Slack", "Approvals", "Your time-off request was approved by Example.", dayOffset: 0, hour: 14, minute: 58),
        fixtureNotification(5, "example.chat", "WhatsApp", "Jamie", "Dinner tonight?", dayOffset: 0, hour: 14, minute: 12),
        fixtureNotification(6, "example.parcel", "Parcels", "Ready for pickup", "Your parcel is at the Example locker. Pickup code 0-0-0000", dayOffset: 0, hour: 13, minute: 20, clearable: false),
        fixtureNotification(7, "example.chat", "WhatsApp", "Notes to self", "[File] review-assets.zip", dayOffset: -1, hour: 21, minute: 40, archived: true),
        fixtureNotification(8, "example.mail", "Gmail", "Re: Clipy release plan", "Attached is the latest schedule. Please confirm by Friday.", dayOffset: -1, hour: 21, minute: 14),
    ] : [
        fixtureNotification(1, "example.sms", "短信", "106****5521", "【示例银行】您尾号 0000 的卡于今日消费 268.00 元，可用余额 12,840.56 元。如非本人操作，请致电客服。", dayOffset: 0, hour: 15, minute: 40),
        fixtureNotification(2, "example.chat", "微信", "产品设计群", "王工：高保真稿我看过了，设备页的发送入口很清楚。", dayOffset: 0, hour: 15, minute: 36),
        fixtureNotification(3, "example.sms", "短信", "106****0000", "验证码 000000，5 分钟内有效，请勿泄露。", dayOffset: 0, hour: 15, minute: 31),
        fixtureNotification(4, "example.work", "钉钉", "审批通知", "你的“外出申请”已通过，审批人：示例", dayOffset: 0, hour: 14, minute: 58),
        fixtureNotification(5, "example.chat", "微信", "李想", "晚上一起吃饭吗？", dayOffset: 0, hour: 14, minute: 12),
        fixtureNotification(6, "example.parcel", "菜鸟", "包裹待取件", "您的包裹已到示例快递柜，取件码 0-0-0000", dayOffset: 0, hour: 13, minute: 20, clearable: false),
        fixtureNotification(7, "example.chat", "微信", "文件传输助手", "[文件] 评审素材.zip", dayOffset: -1, hour: 21, minute: 40, archived: true),
        fixtureNotification(8, "example.mail", "QQ邮箱", "Re: Clipy 发布计划", "附件为最新排期表，请在周五前确认。", dayOffset: -1, hour: 21, minute: 14),
    ]
    notificationModel.setSnapshot(entries: fixtureNotifications, apps: isEnglish ? [
        .init(packageName: "example.chat", appName: "WhatsApp", count: 38),
        .init(packageName: "example.sms", appName: "Messages", count: 12),
        .init(packageName: "example.work", appName: "Slack", count: 21),
        .init(packageName: "example.parcel", appName: "Parcels", count: 9),
        .init(packageName: "example.mail", appName: "Gmail", count: 6),
    ] : [
        .init(packageName: "example.chat", appName: "微信", count: 38),
        .init(packageName: "example.sms", appName: "短信", count: 12),
        .init(packageName: "example.work", appName: "钉钉", count: 21),
        .init(packageName: "example.parcel", appName: "菜鸟", count: 9),
        .init(packageName: "example.mail", appName: "QQ邮箱", count: 6),
    ], total: 86)
    notificationModel.selectedIDs = [fixtureNotifications[0].id]
    NotificationManager.shared.bannerApps = ["example.chat", "example.sms"] // in-memory only, never saved
    // Only real windows: the unified main window (hub-*) and the onboarding window.
    // Old standalone module windows were merged into the main window and are not rendered.
    let steps = ["hub-history-light", "hub-history-dark", "hub-snippets-light", "hub-snippets-dark",
                 "hub-devices-light", "hub-devices-dark", "hub-devices-lan-light", "hub-devices-lan-dark",
                 "hub-devices-relay-light", "hub-devices-relay-dark", "hub-devices-screen-light", "hub-devices-relaysettings-dark",
                 "hub-notifications-light", "hub-notifications-dark",
                 "hub-tools-light", "hub-tools-dark", "hub-tools-utilities-light", "hub-tools-utilities-dark",
                 "hub-tools-keepawake-light", "hub-tools-keepawake-dark",
                 "hub-settings-light", "hub-settings-dark", "hub-settings-search-light", "hub-settings-search-dark",
                 "hub-settings-permissions-light", "hub-settings-permissions-dark",
                 "onboarding-light", "onboarding-dark", "onboarding-launch-light", "onboarding-launch-dark",
                 "onboarding-devices-light", "onboarding-devices-dark"]
    var step = 0
    func prepare() {
        let name = steps[step]
        window.appearance = NSAppearance(named: name.hasSuffix("-dark") ? .darkAqua : .aqua)
        let root: AnyView
        if name.hasPrefix("hub-") {
            // Main window: the six modules with the shared section switcher in the sidebar.
            let sectionName = name.dropFirst(4).split(separator: "-").first.map(String.init) ?? ""
            let section = MainWindowSection(rawValue: sectionName) ?? .history
            let module: AnyView
            switch section {
            case .history: module = AnyView(SearchView(viewModel: model))
            case .snippets: module = AnyView(SnippetEditorView(viewModel: snippetModel))
            case .devices:
                let target: DevicesPage = name.contains("-lan-") ? .lan : name.contains("-screen-") ? .screenControl
                    : name.contains("-relaysettings-") ? .relaySettings : name.contains("-relay-") ? .relay : .devices
                module = AnyView(DevicesView(page: target))
            case .notifications: module = AnyView(NotificationView(viewModel: notificationModel))
            case .tools:
                if name.contains("-keepawake-") {
                    // Fixture: a running 2-hour session in "system" mode (display may sleep and lock).
                    if !KeepAwakeManager.shared.isEnabled { KeepAwakeManager.shared.start(minutes: 120) }
                    wordNavigation.page = .keepAwake
                } else {
                    wordNavigation.page = name.contains("-utilities-") ? .utilities : .lookup
                }
                module = AnyView(WordWorkspaceView(model: wordModel, navigation: wordNavigation, passwordModel: passwordModel))
            case .settings: module = AnyView(SettingsView())
            }
            root = AnyView(module.environment(\.mainWindowNavigator, MainWindowNavigator(section: section))
                .environmentObject(AppLanguageObserver.shared))
        } else {
            let initialStep = name.contains("-launch-") ? 0 : (name.contains("-devices-") ? 2 : 1)
            root = AnyView(OnboardingView(initialStep: initialStep).environmentObject(AppLanguageObserver.shared))
        }
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = name.hasPrefix("onboarding-") ? [.minSize] : []
        window.contentViewController = controller
        window.setContentSize(name.hasPrefix("onboarding-") ? NSSize(width: 860, height: 580) : MainWindowMetrics.size)
        window.center()
        window.orderFrontRegardless()
        if name.hasPrefix("hub-settings-search") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: Notification.Name("clipySettingsSnapshotSearch"), object: name.hasSuffix("-dark") ? t("快捷键", "shortcut") : t("麦克风", "microphone"))
            }
        }
        if name.hasPrefix("hub-settings-permissions") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .appSettingsNavigate, object: "permissions")
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

/// Give mouse regressions a real AppKit lifecycle and target their own window.
/// Hosted runners need not grant global activation. The shell checks success.
func runHistorySelectionApplicationTests() {
    guard let index = CommandLine.arguments.firstIndex(of: "--result-file"),
          CommandLine.arguments.indices.contains(index + 1) else { exit(64) }
    let resultPath = CommandLine.arguments[index + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        runHistoryRowSelectionRegressionTests()
        do { try "passed\n".write(toFile: resultPath, atomically: true, encoding: .utf8) }
        catch { fputs("Unable to write UI regression result\n", stderr); exit(1) }
        app.terminate(nil)
    }
    app.run()
}

private struct HistorySelectionTestHost: View {
    @ObservedObject var model: SearchViewModel
    var body: some View { SearchView(viewModel: model).historyListForTesting }
}

/// Exercise real AppKit mouse dispatch into the draggable SwiftUI rows, using
/// fictional entries only. Model-only tests cannot catch gesture interception.
private func runHistoryRowSelectionRegressionTests() {
    let previousPolicy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.accessory)
    defer { NSApp.setActivationPolicy(previousPolicy) }
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
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let activationDeadline = Date().addingTimeInterval(3)
    while (!NSApp.isActive || !window.isKeyWindow) && Date() < activationDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    fputs("History UI fixture active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible)\n", stderr)
    // The runner may prohibit focus stealing. Dispatch only to this fixture's
    // window; process-global activation is not the gesture contract under test.
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
            window.sendEvent(queued)
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
