import AppKit
import SwiftUI

/// 主窗口「工具 › 保持唤醒」（V3 `mac-keep-awake`）：状态卡、模式、时长、自动停止、行为、状态与诊断。
/// 剩余时间用 TimelineView 只在页面可见时刷新；进程诊断在出现时读取一次，离开即释放。
struct KeepAwakeView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject private var manager = KeepAwakeManager.shared

    private enum CustomKind: Hashable { case duration, time, app }
    @State private var showsCustom = false
    @State private var customKind: CustomKind = .duration
    @State private var customHours = 3
    @State private var customMinutes = 30
    @State private var customTime = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
    @State private var runningApps: [NSRunningApplication] = []
    @State private var selectedPID: Int32?
    @State private var assertions: [KeepAwakeAssertionInfo] = []
    @State private var power = KeepAwakePowerSnapshot.ac
    @State private var failed = false

    private func t(_ zh: String, _ en: String) -> String { KeepAwakeFormat.t(zh, en) }

    var body: some View {
        let _ = languageObserver.revision
        VStack(spacing: 0) {
            header
            Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in heroCard }
                    sectionHeader(t("模式", "Mode"))
                    modes
                    note(manager.settings.mode == .system
                         ? t("锁屏、灭屏不会中断后台运行；只有系统睡眠才会断开网络与服务。",
                             "Locking or turning off the display doesn't stop background work — only system sleep disconnects network and services.")
                         : t("屏幕常亮更耗电，离开电脑时请手动锁屏（Ctrl+⌘+Q）。",
                             "Keeping the display on uses more power. Lock manually (Ctrl+⌘+Q) when you step away."))
                    sectionHeader(t("时长", "Duration"))
                    durations
                    if showsCustom { customForm.padding(.top, 10) }
                    note(t("选择时长会立即开始（或重新计时）；结束后自动恢复正常睡眠。菜单栏快速开关使用上次的时长。",
                           "Choosing a duration starts (or restarts) immediately; normal sleep resumes when it ends. The menu bar quick toggle reuses the last duration."))
                    sectionHeader(t("自动停止", "Stop automatically"))
                    group {
                        toggleRow(t("仅在接通电源时生效", "Only while on power adapter"),
                                  t("使用电池时暂停，接回电源后自动恢复；剩余时间照常流逝",
                                    "Pauses on battery and resumes on AC; the timer keeps running"),
                                  isOn: binding(\.acPowerOnly))
                        divider
                        row(t("电量低于此值时停止", "Stop when battery is below"),
                            t("仅在使用电池时检查；停止后需手动重新开启", "Checked only on battery; turn it on again manually")) {
                            Picker("", selection: binding(\.batteryStopThreshold)) {
                                ForEach(KeepAwakeSettings.batteryThresholds, id: \.self) { value in
                                    Text(value == 0 ? t("关闭", "Off") : "\(value)%").tag(value)
                                }
                            }.labelsHidden().fixedSize()
                        }
                    }
                    sectionHeader(t("行为", "Behavior"))
                    group {
                        toggleRow(t("结束时发送通知", "Notify when it ends"),
                                  t("定时到期、目标应用退出或电量过低停止时提醒",
                                    "When the timer ends, the target app quits, or battery runs low"),
                                  isOn: binding(\.notifyOnEnd))
                        divider
                        toggleRow(t("启动 Clipy 时恢复", "Resume when Clipy launches"),
                                  t("重启或更新后继续；定时已到期或目标应用未运行时不恢复",
                                    "Continues after restart or update unless the timer expired or the app isn't running"),
                                  isOn: binding(\.restoreOnLaunch))
                    }
                    note(t("菜单栏面板底部「保持唤醒」点按即开关，旁边的 ⌄ 可快速选择时长与模式。",
                           "In the menu bar panel, click Keep Awake to toggle; use ⌄ next to it for duration and mode."))
                    sectionHeader(t("状态与诊断", "Status & diagnostics"))
                    diagnostics
                    note(t("列表在打开本页时读取；其他进程与 Clipy 是否开启无关。",
                           "Read when this page opens; other processes are independent of Clipy."))
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WordsV3Style.secondaryContent)
        .onAppear(perform: refreshDiagnostics)
        .onDisappear { assertions = []; runningApps = [] }
        .onChange(of: manager.isActive) { _ in refreshDiagnostics() }
    }

    // MARK: Header & hero

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(.keepAwakeTitle)).font(.system(size: 15, weight: .semibold))
                Text(t("防止 Mac 因闲置睡眠，让下载、同步和远程服务不断线",
                       "Stop idle sleep so downloads, sync and remote services stay connected"))
                    .font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3)
            }
            Spacer()
            Toggle(L10n.t(.keepAwakeTitle), isOn: Binding(
                get: { manager.isEnabled },
                set: { failed = !manager.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden()
                .accessibilityIdentifier("keepAwakeMaster")
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private var heroCard: some View {
        let enabled = manager.isEnabled
        let paused = manager.isPausedOnBattery
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: !enabled ? "moon.fill" : paused ? "pause.fill" : "sun.max.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(enabled ? Color.white : WordsV3Style.text3)
                    .frame(width: 48, height: 48)
                    .background(heroIconFill(enabled: enabled, paused: paused),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(heroTitle)
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundStyle(!enabled ? Color.primary : paused ? WordsV3Style.warn : AppColor.accent)
                    Text(heroSubtitle).font(.system(size: 12)).foregroundStyle(WordsV3Style.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if enabled, let fraction = manager.remainingFraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(AppColor.accent)
            }
            if enabled {
                HStack(spacing: 8) {
                    if manager.endDate != nil {
                        Button { manager.extend(by: 15 * 60) } label: { Label(t("15 分钟", "15 min"), systemImage: "plus") }
                        Button { manager.extend(by: 3600) } label: { Label(t("1 小时", "1 hour"), systemImage: "plus") }
                    }
                    Spacer()
                    Button(role: .destructive) { manager.stop() } label: { Label(t("结束", "Stop"), systemImage: "stop.fill") }
                }
                .controlSize(.small)
            }
            if failed || manager.lastError != nil {
                Text(L10n.t(.keepAwakeFailed)).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .padding(18)
        .background(WordsV3Style.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WordsV3Style.line, lineWidth: 0.5))
    }

    private func heroIconFill(enabled: Bool, paused: Bool) -> AnyShapeStyle {
        if !enabled { return AnyShapeStyle(WordsV3Style.fill2) }
        if paused {
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.56)], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.99, green: 0.73, blue: 0.45), Color(red: 0.92, green: 0.35, blue: 0.05)],
                                            startPoint: .top, endPoint: .bottom))
    }

    private var heroTitle: String {
        guard manager.isEnabled else { return L10n.t(.keepAwakeOff) }
        if manager.isPausedOnBattery { return t("已暂停", "Paused") }
        if let app = manager.targetAppName { return t("直到 \(app) 退出", "Until \(app) quits") }
        if let remaining = manager.remaining { return t("剩余 ", "") + KeepAwakeFormat.clock(remaining) + t("", " left") }
        return t("一直保持", "Indefinitely")
    }

    private var modeSummary: String {
        manager.settings.mode == .system
            ? t("保持系统唤醒，屏幕可熄灭、可锁屏", "System stays awake; display can sleep and lock")
            : t("屏幕保持常亮，闲置不会自动锁屏", "Display stays on; no idle auto-lock")
    }

    private var heroSubtitle: String {
        guard manager.isEnabled else {
            return t("Mac 按系统设置正常睡眠。选择下方时长即可开始。", "Your Mac sleeps normally. Pick a duration below to start.")
        }
        if manager.isPausedOnBattery {
            let left = manager.remaining.map { t("（剩余 ", " (") + KeepAwakeFormat.clock($0) + t("）", " left)") } ?? ""
            return t("正在使用电池 · 接回电源后自动恢复", "On battery · resumes on power adapter") + left
        }
        if let end = manager.endDate {
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDateInToday(end) ? "HH:mm" : (KeepAwakeFormat.zh() ? "M月d日 HH:mm" : "MMM d HH:mm")
            return t("将于 \(f.string(from: end)) 结束 · ", "Ends at \(f.string(from: end)) · ") + modeSummary
        }
        if manager.targetAppName != nil { return modeSummary }
        return modeSummary + t(" · 手动关闭为止", " · until turned off")
    }

    // MARK: Mode & duration

    private var modes: some View {
        HStack(alignment: .top, spacing: 10) {
            modeCard(.system, symbol: "server.rack", title: t("保持系统唤醒", "Keep system awake"),
                     detail: t("屏幕照常熄灭，也照常自动锁屏；系统不睡眠，后台服务、下载和同步不断。",
                               "Display sleeps and locks as usual; the system stays awake so services, downloads and sync continue."),
                     recommended: true)
            modeCard(.display, symbol: "display", title: t("屏幕保持常亮", "Keep display on"),
                     detail: t("屏幕不熄灭，因此闲置时也不会自动锁屏。适合演示、看监控或长时间阅读。",
                               "The display never sleeps, so it won't auto-lock. For presentations, dashboards or long reading."),
                     recommended: false)
        }
    }

    private func modeCard(_ mode: KeepAwakeMode, symbol: String, title: String, detail: String, recommended: Bool) -> some View {
        let selected = manager.settings.mode == mode
        return Button { manager.setMode(mode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(AppColor.accent)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if recommended {
                        Text(t("推荐", "Recommended")).font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(WordsV3Style.ok)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(WordsV3Style.ok.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(selected ? WordsV3Style.selection : WordsV3Style.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? AppColor.accent : WordsV3Style.line, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var currentPresetMinutes: Int? {
        guard !showsCustom else { return nil }
        return manager.activePresetMinutes
    }

    private var durations: some View {
        HStack(spacing: 6) {
            ForEach(KeepAwakeSettings.durationPresets, id: \.self) { minutes in
                chip(KeepAwakeFormat.duration(minutes: minutes), selected: currentPresetMinutes == minutes) {
                    showsCustom = false
                    failed = !manager.start(minutes: minutes)
                }
            }
            chip(t("自定义…", "Custom…"), symbol: "slider.horizontal.3", selected: showsCustom) {
                showsCustom.toggle()
                if showsCustom { runningApps = Self.candidateApps() }
            }
        }
    }

    private func chip(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Color.white : WordsV3Style.text2)
            .padding(.horizontal, 10).frame(height: 26)
            .background(selected ? AppColor.accent : WordsV3Style.fill2, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var customForm: some View {
        group {
            row(t("结束方式", "Ends"), nil) {
                Picker("", selection: $customKind) {
                    Text(t("时长", "Duration")).tag(CustomKind.duration)
                    Text(t("到指定时刻", "At time")).tag(CustomKind.time)
                    Text(t("直到应用退出", "When app quits")).tag(CustomKind.app)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            divider
            switch customKind {
            case .duration:
                row(t("保持时长", "Duration"), t("1 分钟 – 99 小时 59 分", "1 min – 99 h 59 min")) {
                    HStack(spacing: 6) {
                        Stepper(value: $customHours, in: 0...99) { Text("\(customHours)").monospacedDigit().frame(minWidth: 24, alignment: .trailing) }
                        Text(t("小时", "h")).foregroundStyle(WordsV3Style.text2)
                        Stepper(value: $customMinutes, in: 0...59, step: 5) { Text("\(customMinutes)").monospacedDigit().frame(minWidth: 24, alignment: .trailing) }
                        Text(t("分钟", "min")).foregroundStyle(WordsV3Style.text2)
                    }.font(.system(size: 12.5))
                }
            case .time:
                row(t("结束时刻", "End time"), t("早于当前时间时视为明天", "Earlier than now means tomorrow")) {
                    DatePicker("", selection: $customTime, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                }
            case .app:
                row(t("目标应用", "App"), t("从正在运行的应用中选择；它退出时自动结束", "Choose a running app; ends when it quits")) {
                    Picker("", selection: $selectedPID) {
                        Text(t("选择应用", "Choose app")).tag(Int32?.none)
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Text(app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)")
                                .tag(Int32?.some(app.processIdentifier))
                        }
                    }.labelsHidden().frame(maxWidth: 200)
                }
            }
            divider
            HStack {
                Spacer()
                Button(t("开始", "Start")) { startCustom() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!customValid)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var customValid: Bool {
        switch customKind {
        case .duration: return customHours * 60 + customMinutes > 0
        case .time: return true
        case .app: return selectedPID != nil
        }
    }

    private func startCustom() {
        switch customKind {
        case .duration:
            failed = !manager.start(minutes: customHours * 60 + customMinutes)
        case .time:
            failed = !manager.start(until: Self.nextOccurrence(of: customTime))
        case .app:
            guard let pid = selectedPID, let app = runningApps.first(where: { $0.processIdentifier == pid }) else { return }
            failed = !manager.start(untilExitOf: pid, bundleID: app.bundleIdentifier,
                                    name: app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)")
            if failed { runningApps = Self.candidateApps() }
        }
        if !failed { showsCustom = false }
    }

    /// Today's date with the picked hour/minute (the manager rolls past times to tomorrow).
    private static func nextOccurrence(of time: Date) -> Date {
        let cal = Calendar.current
        let parts = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: Date()) ?? time
    }

    private static func candidateApps() -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        group {
            row(t("电源", "Power"), nil) {
                Text(powerText).font(.system(size: 12)).foregroundStyle(WordsV3Style.text2)
            }
            divider
            row(t("合盖与手动睡眠", "Lid close & manual sleep"),
                t("未接外接显示器时合上盖子、点按「睡眠」或按电源键，Mac 仍会睡眠；Ctrl+⌘+Q 仍可立即锁屏。",
                  "Without an external display, closing the lid, choosing Sleep or pressing the power button still sleeps the Mac; Ctrl+⌘+Q still locks.")) {
                Image(systemName: "info.circle").foregroundStyle(WordsV3Style.text3)
            }
            divider
            HStack {
                Text(t("系统中正在阻止睡眠的进程", "Processes preventing sleep")).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button { refreshDiagnostics() } label: { Label(t("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if assertions.isEmpty {
                Text(t("没有进程阻止睡眠。", "Nothing is preventing sleep."))
                    .font(.system(size: 12)).foregroundStyle(WordsV3Style.text3)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            ForEach(assertions) { item in
                divider
                HStack(spacing: 10) {
                    Image(systemName: item.pid == getpid() ? "sun.max.fill" : "app.dashed")
                        .foregroundStyle(item.pid == getpid() ? AppColor.accent : WordsV3Style.text3)
                        .frame(width: 16)
                    Text(item.process).font(.system(size: 12.5, weight: .medium))
                    Text(item.name).font(.system(size: 12)).foregroundStyle(WordsV3Style.text3).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(item.preventsDisplaySleep ? t("阻止屏幕熄灭", "Display on") : t("阻止系统睡眠", "System awake"))
                        .font(.system(size: 11)).foregroundStyle(WordsV3Style.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    private var powerText: String {
        let source = power.onBattery ? t("使用电池", "Battery") : t("电源适配器", "Power adapter")
        guard let percent = power.batteryPercent else { return source }
        return source + t(" · 电量 \(percent)%", " · \(percent)%")
    }

    private func refreshDiagnostics() {
        power = KeepAwakePower.snapshot()
        assertions = KeepAwakeDiagnostics.sleepPreventingAssertions()
    }

    // MARK: Building blocks

    private func binding<Value>(_ keyPath: WritableKeyPath<KeepAwakeSettings, Value>) -> Binding<Value> {
        Binding(get: { manager.settings[keyPath: keyPath] },
                set: { value in manager.update { $0[keyPath: keyPath] = value } })
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 4).padding(.top, 22).padding(.bottom, 8)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.top, 6)
    }

    private var divider: some View { Rectangle().fill(WordsV3Style.line).frame(height: 0.5) }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(WordsV3Style.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WordsV3Style.line, lineWidth: 0.5))
    }

    private func row<Accessory: View>(_ title: String, _ detail: String?, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        row(title, detail) { Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden() }
    }
}
