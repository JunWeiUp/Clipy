import AppKit
import SwiftUI
import UserNotifications

final class OnboardingWindow {
    static let shared = OnboardingWindow()
    static let completedKey = "onboardingV3Completed"
    private let session = WindowSession<OnboardingView>()
    private init() {}

    func show() {
        session.present(create: { [weak self] in
            HostingWindow(title: "Clipy", size: OnboardingView.contentSize,
                          minSize: OnboardingView.contentSize, resizable: false, fullSizeContent: true) {
                OnboardingView(onFinish: { self?.session.close() })
            }
        }, onPrepareForClose: {}, update: { _ in })
    }
}

/// V3 palette for the onboarding window (UI/design-v3/tokens.css + mac.css).
private enum OnboardingStyle {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    static let content = dynamic(.white, rgb(30, 30, 33))
    static let card = dynamic(.white, NSColor(white: 1, alpha: 0.04))
    static let line = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09))
    static let fill = dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06))
    static let fill2 = dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.10))
    static let control = dynamic(.white, NSColor(white: 1, alpha: 0.08))
    static let controlLine = dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.10))
    static let text2 = dynamic(rgb(29, 29, 31, 0.66), rgb(242, 242, 245, 0.66))
    static let text3 = dynamic(rgb(29, 29, 31, 0.42), rgb(242, 242, 245, 0.40))
    static let ok = dynamic(rgb(22, 163, 74), rgb(52, 211, 153))
    static let okBackground = dynamic(rgb(22, 163, 74, 0.12), rgb(52, 211, 153, 0.15))
    static let accentBackground = dynamic(rgb(10, 108, 255, 0.11), rgb(61, 139, 255, 0.18))
}

private enum PermissionState { case granted, missing, unknown }

struct OnboardingView: View {
    static let contentSize = CGSize(width: 860, height: 580)
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @State private var step: Int
    @State private var searchShortcut = PreferencesManager.shared.searchHistoryShortcut
    @State private var launchAtLogin = OnboardingView.isSnapshot ? true : LaunchAtLoginManager.isEnabled
    @State private var accessibility: PermissionState = .unknown
    @State private var screenCapture: PermissionState = .unknown
    @State private var notifications: PermissionState = .unknown
    @State private var peers: [DiscoveredPeer] = []
    @State private var refreshing = false
    @State private var pulse = false
    var onFinish: () -> Void = {}

    init(initialStep: Int = 0, onFinish: @escaping () -> Void = {}) {
        _step = State(initialValue: max(0, min(2, initialStep)))
        self.onFinish = onFinish
    }

    private static var isSnapshot: Bool {
        ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil
    }
    private var chinese: Bool { PreferencesManager.shared.appLanguage == .zh }
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    private let statusTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = languageObserver.revision
        HStack(spacing: 0) {
            hero.frame(width: 340)
            steps.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OnboardingStyle.content)
        }
        // Bound flexible gradients and spacers before NSHostingView measures
        // its intrinsic size; this wizard is intentionally not resizable.
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { refreshStatus() }
        .onReceive(statusTimer) { _ in if step > 0 { refreshStatus() } }
        .onReceive(NotificationCenter.default.publisher(for: .syncAvailableDevicesDidChange)) { _ in
            peers = SyncManager.shared.availablePeers
            refreshing = false
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                LinearGradient(colors: [Color(nsColor: OnboardingStyle.rgb(31, 123, 255)), Color(nsColor: OnboardingStyle.rgb(10, 79, 214))],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(nsColor: OnboardingStyle.rgb(94, 161, 255)), .clear],
                               center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Color(nsColor: OnboardingStyle.rgb(124, 58, 237)), .clear],
                               center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 240)
                RoundedRectangle(cornerRadius: 40)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(18))
                    .offset(x: 135, y: -punchOffset)
            }
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().interpolation(.high)
                    .frame(width: 80, height: 80)
                    .padding(12)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 30))
                    .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                    .shadow(color: Color(nsColor: OnboardingStyle.rgb(0, 20, 80, 0.5)), radius: 18, y: 14)
                    .padding(.top, 92)
                Text(text("欢迎使用 Clipy", "Welcome to Clipy"))
                    .font(.system(size: 30, weight: .bold)).tracking(-0.6)
                    .padding(.top, 24).padding(.bottom, 10)
                Text(text("复制过的内容随手可取，常用文字一键输入，手机和 Mac 之间自由流转。",
                          "Everything you copy stays at hand, frequent text is one keystroke away, and content flows between your phone and Mac."))
                    .font(.system(size: 14)).lineSpacing(5).opacity(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 10) {
                    feature("clock.arrow.circlepath", text("剪贴板历史与片段", "Clipboard history and snippets"))
                    feature("laptopcomputer.and.iphone", text("与 Android、iOS、Windows 同步", "Sync with Android, iOS and Windows"))
                    feature("viewfinder", text("截图、标注、录屏与文字识别", "Capture, annotate, record and recognize text"))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30).padding(.bottom, 30)
        }
        .clipped()
    }

    private var punchOffset: CGFloat { 60 }

    private func feature(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
            Text(title).font(.system(size: 13))
        }
        .opacity(0.95)
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text("第 \(step + 1) 步，共 3 步", "Step \(step + 1) of 3"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppColor.accent)
            Text(stepTitle).font(.system(size: 22, weight: .bold)).tracking(-0.3)
                .padding(.top, 6).padding(.bottom, 6)
            Text(stepLead).font(.system(size: 13.5)).foregroundStyle(OnboardingStyle.text2).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            Group {
                switch step {
                case 0: launchStep
                case 1: permissionStep
                default: deviceStep
                }
            }
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 24)
    }

    private var stepTitle: String {
        [text("随时唤起 Clipy", "Open Clipy anytime"),
         text("开启需要的权限", "Enable the permissions you need"),
         text("连接你的设备（可选）", "Connect your devices (optional)")][step]
    }

    private var stepLead: String {
        [text("Clipy 常驻菜单栏。点按菜单栏图标打开面板，查看最近复制、片段、设备与工具。",
              "Clipy lives in the menu bar. Click its icon to open the panel with recent copies, snippets, devices and tools."),
         text("Clipy 只在本机处理你的数据。以下权限可现在授权，也会在首次用到时再请求；之后可在「偏好设置 › 权限」查看。",
              "Clipy processes your data on this Mac only. Grant these now or when first needed; review them later in Settings › Permissions."),
         text("在 Android、iOS 或 Windows 上打开 Clipy，与这台 Mac 连接同一局域网，即可同步剪贴板、互传文件，并在 Mac 上查看手机通知。",
              "Open Clipy on Android, iOS or Windows on the same local network as this Mac to sync clipboards, send files and see phone notifications here.")][step]
    }

    private var launchStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            card(highlighted: true) {
                iconTile("keyboard", foreground: AppColor.accent, background: OnboardingStyle.accentBackground)
                titleBlock(L10n.t(.searchGlobalShortcut), detail: text("在任何应用中按下此快捷键打开历史搜索窗口。", "Press this shortcut in any app to open history search."))
                ShortcutRecorderRepresentable(combo: $searchShortcut) { combo in
                    PreferencesManager.shared.searchHistoryShortcut = combo
                    PreferencesManager.shared.isSearchGlobalShortcutEnabled = combo != nil
                    SearchGlobalHotKeyManager.register()
                }
                .frame(width: 130, height: 28)
            }
            card {
                iconTile("power", foreground: OnboardingStyle.text2, background: OnboardingStyle.fill)
                titleBlock(L10n.t(.launchAtLogin), detail: text("开机后自动在菜单栏常驻", "Stay in the menu bar after you log in"))
                Toggle(L10n.t(.launchAtLogin), isOn: $launchAtLogin)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .onChange(of: launchAtLogin) { value in
                        guard !OnboardingView.isSnapshot else { return }
                        do { try LaunchAtLoginManager.setEnabled(value) }
                        catch { launchAtLogin = LaunchAtLoginManager.isEnabled }
                    }
            }
            infoRow("info.circle", text("快捷键与开机启动可随时在「偏好设置」中修改。", "You can change the shortcut and login item in Settings anytime."))
        }
    }

    private var permissionStep: some View {
        let order: [(PermissionState, Int)] = [(accessibility, 0), (screenCapture, 1), (notifications, 2)]
        let current = order.first { $0.0 != .granted }?.1
        return VStack(alignment: .leading, spacing: 10) {
            permissionCard(index: 0, current: current, state: accessibility, symbol: "accessibility",
                           title: text("辅助功能", "Accessibility"), tag: nil,
                           detail: text("自动粘贴、截图元素吸附、读取隐藏的菜单栏图标；未授权时仍会复制成功",
                                        "Auto-paste, element snapping and hidden menu bar icons; copying still works without it"),
                           action: text("去授权", "Grant")) {
                AccessibilityManager.requestSystemPrompt()
            }
            permissionCard(index: 1, current: current, state: screenCapture, symbol: "display",
                           title: text("屏幕录制", "Screen Recording"), tag: (text("截图需要", "For capture"), true),
                           detail: text("截图 / 录屏必需", "Required for screenshots and recording"),
                           action: text("去授权", "Grant")) {
                _ = ScreenCapturePermissionManager.requestAccess()
            }
            permissionCard(index: 2, current: current, state: notifications, symbol: "bell",
                           title: text("通知", "Notifications"), tag: (text("可选", "Optional"), false),
                           detail: text("收到手机发来的文件时提醒", "Alerts when a phone sends you a file"),
                           action: text("允许", "Allow")) {
                guard Self.canUseNotificationCenter else { return }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    DispatchQueue.main.async { refreshStatus() }
                }
            }
            infoRow("lock", text("输入监控、麦克风、摄像头仅在开启录屏按键显示 / 麦克风 / 摄像头时请求。",
                                 "Input Monitoring, microphone and camera are requested only when you enable those recording options."))
        }
    }

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    iconTile("laptopcomputer", foreground: AppColor.accent, background: OnboardingStyle.accentBackground)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(macName).font(.system(size: 13.5, weight: .semibold))
                        Text(macAddress).font(.system(size: 12, design: .monospaced)).foregroundStyle(OnboardingStyle.text3)
                    }
                    Spacer()
                    Button {
                        refreshing = true
                        SyncManager.shared.refreshDiscovery()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            refreshing = false
                            peers = SyncManager.shared.availablePeers
                        }
                    } label: {
                        Label(text("刷新设备", "Refresh devices"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(OnboardingButtonStyle(kind: .secondary, small: true))
                    .disabled(!PreferencesManager.shared.isSyncEnabled || refreshing)
                }
                VStack(spacing: 0) {
                    if peers.isEmpty {
                        HStack(spacing: 10) {
                            Circle().fill(PreferencesManager.shared.isSyncEnabled ? OnboardingStyle.ok : OnboardingStyle.text3)
                                .frame(width: 8, height: 8)
                                .opacity(refreshing && pulse ? 0.35 : 1)
                                .animation(refreshing ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
                                .onAppear { pulse = true }
                            Text(PreferencesManager.shared.isSyncEnabled
                                 ? text("正在查找同一网络中的设备…", "Looking for devices on this network…")
                                 : text("局域网同步未开启，可稍后在「设备 → 局域网设置」中开启。", "Local sync is off. Turn it on later in Devices → LAN settings."))
                                .font(.system(size: 12)).foregroundStyle(OnboardingStyle.text2)
                            Spacer()
                        }
                        .padding(.vertical, 9)
                    }
                    ForEach(Array(peers.enumerated()), id: \.element.peerId) { index, peer in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone").font(.system(size: 15)).foregroundStyle(OnboardingStyle.ok)
                                .frame(width: 30, height: 30)
                                .background(OnboardingStyle.okBackground, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName).font(.system(size: 13))
                                Text(SyncEndpointDisplay.label(host: peer.host, port: peer.port))
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(OnboardingStyle.text3)
                            }
                            Spacer()
                            Text(text("已发现", "Found")).font(.system(size: 12)).foregroundStyle(OnboardingStyle.ok)
                        }
                        .padding(.vertical, 9)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(OnboardingStyle.line).frame(height: 0.5) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(OnboardingStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppColor.accent, lineWidth: 1.5))
            .shadow(color: AppColor.accent.opacity(0.18), radius: 9, y: 6)
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 14)).foregroundStyle(OnboardingStyle.text2)
                Text(text("不在同一网络？稍后可在「公网设备组」中加入。", "Not on the same network? Join a relay device group later."))
                    .font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                Button(text("了解", "Learn more")) { MainWindow.shared.showDevices(page: .devices) }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppColor.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(OnboardingStyle.fill, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 4)
        }
        .onAppear {
            if OnboardingView.isSnapshot { return }
            peers = SyncManager.shared.availablePeers
        }
    }

    private var macName: String {
        OnboardingView.isSnapshot ? "Example MacBook Pro" : SyncManager.shared.displayName
    }

    private var macAddress: String {
        if OnboardingView.isSnapshot { return "192.0.2.24:5566" }
        guard let ip = SyncManager.shared.enumerateLocalIPv4s().first else {
            return text("未连接局域网", "No local network")
        }
        return "\(ip):\(SyncManager.shared.syncPort)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? AppColor.accent : (index < step ? AppColor.accent.opacity(0.45) : OnboardingStyle.fill2))
                        .frame(width: index == step ? 20 : 7, height: 7)
                }
            }
            Spacer()
            Button(step == 2 ? text("稍后连接", "Connect later") : text("跳过", "Skip")) {
                if step == 2 { finish() } else { step = 2 }
            }
            .buttonStyle(OnboardingButtonStyle(kind: .plain))
            Button(text("上一步", "Back")) { step -= 1 }
                .buttonStyle(OnboardingButtonStyle(kind: .secondary))
                .opacity(step == 0 ? 0 : 1)
                .disabled(step == 0)
            Button(step == 2 ? text("开始使用", "Get started") : text("继续", "Continue")) {
                if step == 2 { finish() } else { step += 1 }
            }
            .buttonStyle(OnboardingButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Components

    private func card<Content: View>(highlighted: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) { content() }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlighted ? AppColor.accent : OnboardingStyle.line, lineWidth: highlighted ? 1.5 : 0.5))
            .shadow(color: highlighted ? AppColor.accent.opacity(0.18) : .clear, radius: 9, y: 6)
    }

    private func iconTile(_ symbol: String, foreground: Color, background: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 17))
            .foregroundStyle(foreground)
            .frame(width: 38, height: 38)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func titleBlock(_ title: String, tag: (String, Bool)? = nil, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                if let tag {
                    Text(tag.0).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tag.1 ? AppColor.accent : OnboardingStyle.text2)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(tag.1 ? OnboardingStyle.accentBackground : OnboardingStyle.fill,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(OnboardingStyle.text3).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionCard(index: Int, current: Int?, state: PermissionState, symbol: String, title: String,
                                tag: (String, Bool)?, detail: String, action: String,
                                perform: @escaping () -> Void) -> some View {
        let granted = state == .granted
        let highlighted = current == index
        return HStack(spacing: 14) {
            iconTile(symbol, foreground: granted ? OnboardingStyle.ok : (highlighted ? AppColor.accent : OnboardingStyle.text2),
                     background: granted ? OnboardingStyle.okBackground : (highlighted ? OnboardingStyle.accentBackground : OnboardingStyle.fill))
            titleBlock(title, tag: tag, detail: detail)
            if granted {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(OnboardingStyle.ok, in: Circle())
                    .accessibilityLabel(text("已授权", "Granted"))
            } else {
                Button(action, action: perform)
                    .buttonStyle(OnboardingButtonStyle(kind: highlighted ? .primary : .secondary, small: true))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(granted ? OnboardingStyle.okBackground : OnboardingStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(granted ? Color.clear : (highlighted ? AppColor.accent : OnboardingStyle.line),
                          lineWidth: highlighted && !granted ? 1.5 : 0.5))
        .shadow(color: highlighted && !granted ? AppColor.accent.opacity(0.18) : .clear, radius: 9, y: 6)
    }

    private func infoRow(_ symbol: String, _ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(OnboardingStyle.text2)
            Text(message).font(.system(size: 12.5)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(OnboardingStyle.fill, in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 4)
    }

    // MARK: - State

    /// Reads current status only; never triggers a permission request.
    private func refreshStatus() {
        accessibility = AccessibilityManager.isTrusted ? .granted : .missing
        screenCapture = ScreenCapturePermissionManager.isAuthorized ? .granted : .missing
        guard Self.canUseNotificationCenter else { notifications = .missing; return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: PermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional: state = .granted
            default: state = .missing
            }
            DispatchQueue.main.async { notifications = state }
        }
    }

    /// UNUserNotificationCenter aborts outside an app bundle (core tests/snapshots).
    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingWindow.completedKey)
        onFinish()
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 13 : 13.5, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.white : (kind == .plain ? OnboardingStyle.text2 : Color.primary))
            .padding(.horizontal, small ? 12 : 16)
            .frame(height: small ? 28 : 34)
            .background(background, in: RoundedRectangle(cornerRadius: small ? 7 : 9))
            .overlay(RoundedRectangle(cornerRadius: small ? 7 : 9)
                .strokeBorder(kind == .secondary ? OnboardingStyle.controlLine : Color.clear, lineWidth: 0.5))
            .shadow(color: kind == .primary ? AppColor.accent.opacity(0.35) : .clear, radius: 1, y: 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }

    private var background: Color {
        switch kind {
        case .primary: return AppColor.accent
        case .secondary: return OnboardingStyle.control
        case .plain: return .clear
        }
    }
}
