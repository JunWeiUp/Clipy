import AppKit
import SwiftUI
import Network
import UniformTypeIdentifiers

// MARK: - Data

struct DevicesRow: Identifiable, Equatable {
    var id: String { peerId }
    let peerId: String
    let name: String
    let endpoint: String?
    let isOnline: Bool
    let isRelay: Bool
}

/// One device's connection card values (`SyncManager.DiagnosticsRow`).
struct DevicesConnectionStats: Equatable {
    var connectedAt: Date?
    var lastSentAt: Date?
    var lastAckAt: Date?
    var lastReceivedAt: Date?
    var pending: Int = 0
    var lastError: String?
}

enum DevicesPage: Equatable { case devices, lan, relay, relaySettings, diagnostics, screenControl }

extension Notification.Name {
    static let devicesNavigate = Notification.Name("Clipy.devicesNavigate")
}

private enum DevicesText {
    static var zh: Bool { PreferencesManager.shared.appLanguage == .zh }
    static func t(_ cn: String, _ en: String) -> String { zh ? cn : en }
}

// MARK: - Root

struct DevicesView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @State private var page: DevicesPage
    @State private var rows: [DevicesRow] = []
    @State private var selectedID: String?
    @State private var clipboardTargets = Set(PreferencesManager.shared.clipboardSyncPeerIds)
    @State private var notificationTargets = Set(PreferencesManager.shared.notificationSyncPeerIds)
    @State private var syncEnabled = PreferencesManager.shared.isSyncEnabled
    @State private var stats: [String: DevicesConnectionStats] = [:]
    @State private var refreshing = false
    @State private var refreshNote: String?
    @State private var showAddSheet = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(page: DevicesPage = .devices) {
        _page = State(initialValue: page)
    }

    private var isSnapshot: Bool {
        #if CLIPY_CORE_TESTS
        return ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil
        #else
        return false
        #endif
    }

    var body: some View {
        let _ = languageObserver.revision
        HStack(spacing: 0) {
            sidebar
            SplitV3Hairline(vertical: true)
            switch page {
            case .devices:
                deviceList.frame(width: 400)
                SplitV3Hairline(vertical: true)
                inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .relay:
                SyncRelayGroupView(embedded: true, fixture: relayFixture, openSettings: { page = .relaySettings })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .lan, .relaySettings, .screenControl:
                DeviceConnectionSettingsView(page: $page, syncEnabled: Binding(get: { syncEnabled }, set: setSyncEnabled), onlineCount: onlineRows.count)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .diagnostics:
                SyncDiagnosticsPage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, idealWidth: 1136, maxWidth: .infinity, minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .background(SplitV3Color.content)
        .ignoresSafeArea()
        .onAppear(perform: initialLoad)
        .onReceive(NotificationCenter.default.publisher(for: .devicesNavigate)) { notification in
            if let target = notification.object as? DevicesPage { page = target }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncAvailableDevicesDidChange)) { _ in reloadRows() }
        .onReceive(timer) { _ in if page == .devices { reloadStats() } }
        .sheet(isPresented: $showAddSheet) {
            DevicesManualAddSheet { reloadRows() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            MainWindowSidebarHeader()
            sidebarItem(DevicesText.t("我的设备", "My devices"), symbol: "laptopcomputer.and.iphone",
                        selected: page == .devices, count: rows.count) { page = .devices }
            sidebarItem(DevicesText.t("局域网设置", "LAN settings"), symbol: "network",
                        selected: page == .lan || page == .relaySettings) { page = .lan }
            sidebarItem(DevicesText.t("公网设备组", "Relay device group"), symbol: "person.2",
                        selected: page == .relay) { page = .relay }
            Text(DevicesText.t("维护", "Maintenance"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SplitV3Color.text3)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
            sidebarItem(DevicesText.t("同步诊断", "Sync diagnostics"), symbol: "waveform.path.ecg",
                        selected: page == .diagnostics) { page = .diagnostics }
            sidebarItem(DevicesText.t("手机控制 Mac", "Control this Mac"), symbol: "iphone",
                        selected: page == .screenControl) { page = .screenControl }
            Spacer(minLength: 0)
            SplitV3Hairline()
            HStack(spacing: 10) {
                DevicesStatusDot(active: syncEnabled)
                Text(syncEnabled ? DevicesText.t("局域网同步已启用", "LAN sync is on")
                                 : DevicesText.t("局域网同步已关闭", "LAN sync is off"))
                    .font(.system(size: 12)).foregroundStyle(SplitV3Color.text2).lineLimit(1)
            }.padding(10)
            MainWindowSidebarFooter()
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .frame(width: MainWindowMetrics.sidebarWidth).frame(maxHeight: .infinity, alignment: .top)
        .background(SplitV3Color.sidebar)
    }

    private func sidebarItem(_ title: String, symbol: String, selected: Bool, count: Int? = nil,
                             action: @escaping () -> Void) -> some View {
        DevicesSidebarItem(title: title, symbol: symbol, selected: selected, count: count, action: action)
    }

    // MARK: Device list

    private var onlineRows: [DevicesRow] { rows.filter(\.isOnline) }
    private var offlineRows: [DevicesRow] { rows.filter { !$0.isOnline } }

    private var deviceList: some View {
        VStack(spacing: 0) {
            SplitV3Toolbar {
                Text(DevicesText.t("我的设备", "My devices")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { showAddSheet = true } label: {
                    Label(DevicesText.t("手动添加设备", "Add device manually"), systemImage: "plus")
                }.buttonStyle(DevicesSmallButtonStyle()).disabled(!syncEnabled)
            }
            meCard.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 26, weight: .light))
                                .foregroundStyle(SplitV3Color.text3)
                            Text(L10n.t(.noDevicesFound)).font(.system(size: 13, weight: .medium))
                            Text(DevicesText.t("同一网段的设备会自动出现；也可以手动添加。", "Devices on the same subnet appear automatically, or add one manually."))
                                .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 20)
                    }
                    if !onlineRows.isEmpty {
                        groupHeader(DevicesText.t("在线 · \(onlineRows.count)", "Online · \(onlineRows.count)"))
                        ForEach(onlineRows) { row in deviceRow(row) }
                    }
                    if !offlineRows.isEmpty {
                        groupHeader(DevicesText.t("离线已授权设备（可删除）", "Offline authorized devices (removable)"))
                        ForEach(offlineRows) { row in deviceRow(row) }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            footer.padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 14)
        }
        .background(SplitV3Color.content)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(SplitV3Color.text3)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 6)
    }

    private var meCard: some View {
        let prefs = PreferencesManager.shared
        let ip = isSnapshot ? "192.0.2.24" : SyncManager.shared.enumerateLocalIPv4s().first
        return HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.system(size: 19))
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(prefs.deviceName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(DevicesText.t("本机", "This Mac"))
                        Text(verbatim: "ID \(prefs.syncPeerId.prefix(8).lowercased())…").font(.system(size: 11.5, design: .monospaced))
                    }
                    if let ip { Text(verbatim: "\(ip):\(prefs.syncPort)").font(.system(size: 11.5, design: .monospaced)) }
                }.font(.system(size: 11.5)).opacity(0.88).lineLimit(1)
            }
            Spacer(minLength: 0)
            DevicesSwitch(isOn: Binding(get: { syncEnabled }, set: setSyncEnabled), onBrand: true)
                .help(L10n.t(.enableLanSync))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(LinearGradient(colors: [Color(red: 0.18, green: 0.53, blue: 1), Color(red: 0.04, green: 0.42, blue: 1),
                                            Color(red: 0, green: 0.28, blue: 0.78)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color(red: 0.04, green: 0.42, blue: 1).opacity(0.45), radius: 9, y: 6)
    }

    private func deviceRow(_ row: DevicesRow) -> some View {
        let selected = selectedID == row.peerId
        return DevicesListRow(row: row, selected: selected,
                              clipboard: clipboardTargets.contains(row.peerId),
                              notification: notificationTargets.contains(row.peerId),
                              select: { selectedID = row.peerId },
                              delete: { removeOffline(row) })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: refresh) {
                HStack(spacing: 6) {
                    if refreshing { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(refreshing ? L10n.t(.refreshingDevices) : L10n.t(.refreshDevices))
                }
            }.buttonStyle(DevicesSmallButtonStyle()).disabled(!syncEnabled || refreshing)
            Text(refreshNote ?? (refreshing ? DevicesText.t("正在扫描本机 /24 网段…", "Scanning the local /24 subnet…")
                                 : DevicesText.t("同一网段自动发现；跨频段 / 跨子网可手动添加", "Same subnet is discovered automatically; add other bands or subnets manually")))
                .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SplitV3Color.controlLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let row = rows.first(where: { $0.peerId == selectedID }) ?? rows.first {
            DevicesInspector(row: row,
                             clipboard: binding(for: row.peerId, clipboard: true),
                             notification: binding(for: row.peerId, clipboard: false),
                             stats: stats[row.peerId] ?? DevicesConnectionStats(),
                             syncEnabled: syncEnabled,
                             openDiagnostics: { page = .diagnostics })
                .id(row.peerId)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 30, weight: .light))
                    .foregroundStyle(SplitV3Color.text3)
                Text(DevicesText.t("选择一台设备查看同步与发送选项", "Select a device to see sync and send options"))
                    .font(.system(size: 13)).foregroundStyle(SplitV3Color.text2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(SplitV3Color.inspector)
        }
    }

    private func binding(for peerId: String, clipboard: Bool) -> Binding<Bool> {
        Binding(get: {
            clipboard ? clipboardTargets.contains(peerId) : notificationTargets.contains(peerId)
        }, set: { enabled in
            if clipboard {
                if enabled { clipboardTargets.insert(peerId) } else { clipboardTargets.remove(peerId) }
            } else {
                if enabled { notificationTargets.insert(peerId) } else { notificationTargets.remove(peerId) }
            }
            guard !isSnapshot else { return }
            if clipboard { PreferencesManager.shared.setClipboardSync(peerId: peerId, enabled: enabled) }
            else { PreferencesManager.shared.setNotificationSync(peerId: peerId, enabled: enabled) }
            if enabled { SyncManager.shared.refreshPendingDelivery(for: peerId) }
        })
    }

    // MARK: Actions

    private func initialLoad() {
        #if CLIPY_CORE_TESTS
        if isSnapshot { loadSnapshotFixture(); return }
        #endif
        reloadRows()
        reloadStats()
        if PreferencesManager.shared.isSyncEnabled { SyncManager.shared.triggerCrossBandDiscovery() }
    }

    private func reloadRows() {
        guard !isSnapshot else { return }
        let prefs = PreferencesManager.shared
        clipboardTargets = Set(prefs.clipboardSyncPeerIds)
        notificationTargets = Set(prefs.notificationSyncPeerIds)
        syncEnabled = prefs.isSyncEnabled
        let sync = SyncManager.shared
        let online = sync.availableDeviceEntries
        let onlineIDs = Set(online.map(\.peerId))
        var next = online.map {
            DevicesRow(peerId: $0.peerId, name: $0.displayName, endpoint: $0.connectionDescription,
                       isOnline: true, isRelay: $0.host.hasPrefix("relay:"))
        }
        let offline = clipboardTargets.union(notificationTargets).subtracting(onlineIDs).sorted()
        next += offline.map { id in
            let hostPort = sync.resolvedPeerHostPort(peerId: id)
            return DevicesRow(peerId: id, name: sync.resolvedPeerLabel(peerId: id),
                              endpoint: hostPort.map { $0.hasPrefix("relay:") ? DevicesText.t("公网中继", "Internet relay") : $0 },
                              isOnline: false, isRelay: hostPort?.hasPrefix("relay:") ?? false)
        }
        rows = next
        if let selectedID, !next.contains(where: { $0.peerId == selectedID }) { self.selectedID = nil }
        if selectedID == nil { selectedID = next.first?.peerId }
    }

    private func reloadStats() {
        guard !isSnapshot else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = SyncManager.shared.diagnosticsRows()
            var map: [String: DevicesConnectionStats] = [:]
            for row in fresh {
                let r = row.record
                map[r.peerId] = DevicesConnectionStats(connectedAt: row.isOnline ? r.sessionUpAt : nil,
                                                       lastSentAt: r.lastSentAt, lastAckAt: r.lastAckAt,
                                                       lastReceivedAt: r.lastReceivedAt, pending: row.pendingCount,
                                                       lastError: r.lastError)
            }
            DispatchQueue.main.async { if map != stats { stats = map } }
        }
    }

    private func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        guard !isSnapshot else { return }
        PreferencesManager.shared.isSyncEnabled = enabled
        if enabled { SyncManager.shared.start() } else { SyncManager.shared.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reloadRows() }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshNote = nil
        // User refresh: prune ghosts + full /24 scan (same as the settings page).
        SyncManager.shared.refreshDiscovery(pruneCache: true, scanFullSubnet: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            reloadRows()
            refreshing = false
            let count = rows.filter(\.isOnline).count
            refreshNote = DevicesText.t("已刷新 · 发现 \(count) 台在线设备", "Refreshed · \(count) online")
        }
    }

    private func removeOffline(_ row: DevicesRow) {
        clipboardTargets.remove(row.peerId)
        notificationTargets.remove(row.peerId)
        rows.removeAll { $0.peerId == row.peerId }
        if selectedID == row.peerId { selectedID = rows.first?.peerId }
        guard !isSnapshot else { return }
        PreferencesManager.shared.removeAuthorizedPeer(row.peerId)
    }

    private var relayFixture: SyncRelayGroups? {
        #if CLIPY_CORE_TESTS
        if isSnapshot {
            let model = SyncRelayGroups()
            model.loaded = true
            model.enrolled = true
            model.onlineKnown = true
            model.device = "mac-7f3ac21e"
            model.group = "fixture-group"
            model.groupName = DevicesText.t("我的设备", "My devices")
            model.members = [
                ["device": "mac-7f3ac21e", "name": DevicesText.t("示例 MacBook Pro", "Example MacBook Pro"), "manager": true],
                ["device": "android-51c08d", "name": DevicesText.t("小米 14", "Pixel 9"), "manager": false],
                ["device": "ios-a2e9f4", "name": DevicesText.t("工作室 iPhone", "Studio iPhone"), "manager": false],
            ]
            model.online = ["mac-7f3ac21e", "android-51c08d"]
            model.automaticJoin = false
            model.invitation = ["short_link": "common-relay://i/7Qm2-fixture-xK9a", "mode": "manual",
                                "expires": Date().timeIntervalSince1970 + 600]
            return model
        }
        #endif
        return nil
    }

    #if CLIPY_CORE_TESTS
    /// Fictional data for isolated window snapshots only.
    private func loadSnapshotFixture() {
        let now = Date()
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        rows = [
            DevicesRow(peerId: "9b20e1d4-fixture", name: DevicesText.t("小米 14", "Pixel 9"), endpoint: "192.0.2.57:5566", isOnline: true, isRelay: false),
            DevicesRow(peerId: "c41f7a02-fixture", name: DevicesText.t("工作室 iPhone", "Studio iPhone"), endpoint: DevicesText.t("公网中继", "Internet relay"), isOnline: true, isRelay: true),
            DevicesRow(peerId: "5e8d03bb-fixture", name: DevicesText.t("家里的 MacBook Air", "Home MacBook Air"), endpoint: "192.0.2.40:5566", isOnline: false, isRelay: false),
        ]
        clipboardTargets = ["9b20e1d4-fixture", "c41f7a02-fixture", "5e8d03bb-fixture"]
        notificationTargets = ["9b20e1d4-fixture", "5e8d03bb-fixture"]
        syncEnabled = true
        stats = ["9b20e1d4-fixture": DevicesConnectionStats(connectedAt: at(30), lastSentAt: at(2), lastAckAt: at(2), lastReceivedAt: at(4), pending: 0, lastError: nil),
                 "5e8d03bb-fixture": DevicesConnectionStats(connectedAt: nil, lastSentAt: at(1100), lastAckAt: at(1100), lastReceivedAt: at(1123), pending: 3, lastError: "connect timeout")]
        selectedID = rows[0].peerId
    }
    #endif
}

// MARK: - Components

private struct DevicesSidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let count: Int?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14))
                    .foregroundStyle(selected ? AppColor.accent : SplitV3Color.text2)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(verbatim: "\(count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(SplitV3Color.text3)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? SplitV3Color.fill2 : (hovered ? SplitV3Color.fill : .clear)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

private struct DevicesStatusDot: View {
    let active: Bool
    var body: some View {
        Circle().fill(active ? Color(red: 0.19, green: 0.82, blue: 0.35) : SplitV3Color.text3)
            .frame(width: 7, height: 7)
            .background(Circle().fill(active ? Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.18) : .clear).frame(width: 13, height: 13))
    }
}

/// `.dev` gradient avatar. The protocol does not report device type, so the icon
/// only distinguishes relay vs LAN peers; colour is stable per peer.
struct DevicesAvatar: View {
    let peerId: String
    let symbol: String
    var offline = false
    var size: CGFloat = 38
    var radius: CGFloat = 10

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.29, green: 0.87, blue: 0.50), Color(red: 0.09, green: 0.64, blue: 0.29)),
        (Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.49, green: 0.23, blue: 0.93)),
        (Color(red: 0.99, green: 0.73, blue: 0.45), Color(red: 0.92, green: 0.35, blue: 0.05)),
        (Color(red: 0.36, green: 0.61, blue: 1.00), Color(red: 0.04, green: 0.42, blue: 1.00)),
    ]

    var body: some View {
        let pair: (Color, Color) = offline
            ? (Color(red: 0.63, green: 0.63, blue: 0.67), Color(red: 0.44, green: 0.44, blue: 0.48))
            : Self.palette[Self.index(peerId)]
        Image(systemName: symbol).font(.system(size: size * 0.47))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: radius))
    }

    private static func index(_ key: String) -> Int {
        var hash: UInt32 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Int(hash % UInt32(palette.count))
    }
}

private struct DevicesListRow: View {
    let row: DevicesRow
    let selected: Bool
    let clipboard: Bool
    let notification: Bool
    let select: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            DevicesAvatar(peerId: row.peerId, symbol: row.isRelay ? "globe" : "display", offline: !row.isOnline)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if row.isOnline {
                        Circle().fill(Color(red: 0.19, green: 0.82, blue: 0.35)).frame(width: 6, height: 6)
                        Text(row.endpoint ?? "").font(.system(size: 11.5, design: row.isRelay ? .default : .monospaced))
                    } else {
                        Text(L10n.t(.deviceOffline))
                        if let endpoint = row.endpoint {
                            Text("·")
                            Text(endpoint).font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                }.font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.isOnline {
                HStack(spacing: 5) {
                    Image(systemName: "clipboard")
                        .foregroundStyle(clipboard ? AppColor.accent : SplitV3Color.text3)
                    Image(systemName: notification ? "bell" : "bell.slash")
                        .foregroundStyle(notification ? AppColor.accent : SplitV3Color.text3)
                }.font(.system(size: 12))
                    .help(DevicesText.t("同步剪贴板 / 同步通知", "Sync clipboard / notifications"))
            } else {
                Button(action: delete) { Image(systemName: "trash") }
                    .buttonStyle(SplitV3IconButtonStyle()).opacity(0.8)
                    .help(L10n.t(.delete)).accessibilityLabel(L10n.t(.delete))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? SplitV3Color.selection : (hovered ? SplitV3Color.fill : .clear)))
        .opacity(!row.isOnline && !selected ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
    }
}

/// `.sw`: 32×19 switch; `onBrand` renders the white-on-blue variant of the self card.
struct DevicesSwitch: View {
    @Binding var isOn: Bool
    var onBrand = false

    var body: some View {
        let track: Color = onBrand ? (isOn ? .white : Color.white.opacity(0.35)) : (isOn ? AppColor.accent : SplitV3Color.fill2)
        let knob: Color = onBrand && isOn ? AppColor.accent : .white
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(track).frame(width: 32, height: 19)
                    .overlay(Capsule().strokeBorder(onBrand ? Color.clear : SplitV3Color.controlLine, lineWidth: 0.5))
                Circle().fill(knob).frame(width: 15, height: 15).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }.animation(.easeOut(duration: 0.15), value: isOn).contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "1" : "0")
    }
}

/// `.btn.sm`: 24pt bordered control.
struct DevicesSmallButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(DevicesButtonLabelStyle())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? AppColor.accent : SplitV3Color.control)
                .shadow(color: .black.opacity(primary ? 0 : 0.05), radius: 0.5, y: 0.5))
            .overlay { if !primary { RoundedRectangle(cornerRadius: 6).strokeBorder(SplitV3Color.controlLine, lineWidth: 0.5) } }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DevicesButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 11, weight: .medium)); configuration.title }
    }
}

// MARK: - Inspector

private struct DevicesInspector: View {
    let row: DevicesRow
    @Binding var clipboard: Bool
    @Binding var notification: Bool
    let stats: DevicesConnectionStats
    let syncEnabled: Bool
    let openDiagnostics: () -> Void
    @State private var dropTargeted = false
    @State private var sending = 0
    @State private var sendError: String?
    @State private var sendNote: String?

    var body: some View {
        ZStack(alignment: .top) {
            SplitV3Color.inspector
            // Scroll only when the window is too short for the whole inspector.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                permissions.padding(.horizontal, 24)
                sectionHeader(DevicesText.t("发送到\(row.name)", "Send to \(row.name)")) {
                    Text(DevicesText.t("无需本机授权", "No local authorization needed"))
                        .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                }
                dropZone.padding(.horizontal, 24)
                if let sendError {
                    Text(sendError).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.horizontal, 28).padding(.top, 8)
                } else if let sendNote {
                    Text(sendNote).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                        .padding(.horizontal, 28).padding(.top, 8)
                }
                sectionHeader(DevicesText.t("连接状态", "Connection")) {
                    Button(L10n.t(.syncDiagnosticsTitle), action: openDiagnostics)
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppColor.accent)
                }
                connectionGrid.padding(.horizontal, 24)
                sectionHeader(DevicesText.t("接收", "Receiving")) { EmptyView() }
                receiveCard.padding(.horizontal, 24).padding(.bottom, 24)
            }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            DevicesAvatar(peerId: row.peerId, symbol: row.isRelay ? "globe" : "display",
                          offline: !row.isOnline, size: 52, radius: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.system(size: 19, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(SplitV3Color.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
    }

    private var subtitle: String {
        var parts = [row.isOnline ? L10n.t(.deviceOnline) : L10n.t(.deviceOffline)]
        if let endpoint = row.endpoint { parts.append(endpoint) }
        parts.append(DevicesText.t("设备 ID \(row.peerId.prefix(8))…", "Device ID \(row.peerId.prefix(8))…"))
        return parts.joined(separator: " · ")
    }

    private var permissions: some View {
        VStack(spacing: 0) {
            permissionRow(symbol: "clipboard", tint: Color(red: 0.04, green: 0.42, blue: 1),
                          title: L10n.t(.syncClipboardToDevice),
                          detail: DevicesText.t("向该设备推送剪贴板历史；对方无需勾选即可接收", "Push clipboard history to this device; it receives without opting in"),
                          isOn: $clipboard)
            SplitV3Hairline()
            permissionRow(symbol: "bell", tint: Color(red: 0.76, green: 0.25, blue: 0.05),
                          title: L10n.t(.syncNotificationsToDevice),
                          detail: DevicesText.t("向该设备推送通知；对方无需勾选即可接收", "Push notifications to this device; it receives without opting in"),
                          isOn: $notification)
        }.devicesCard()
    }

    private func permissionRow(symbol: String, tint: Color, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                .frame(width: 24, height: 24).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
            }
            Spacer(minLength: 0)
            DevicesSwitch(isOn: isOn)
        }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
    }

    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            trailing()
        }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 8)
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 22)).foregroundStyle(AppColor.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(DevicesText.t("拖入文件或文件夹", "Drop files or folders")).font(.system(size: 12.5, weight: .semibold))
                Text(DevicesText.t("文件夹 ≤ 512 MiB · 10,000 项", "Folders ≤ 512 MiB · 10,000 items"))
                    .font(.system(size: 11)).foregroundStyle(SplitV3Color.text3).lineLimit(1)
            }.layoutPriority(-1)
            Spacer(minLength: 0)
            Button { sendText() } label: { Label(DevicesText.t("发送文本…", "Send text…"), systemImage: "t.square") }
                .buttonStyle(DevicesSmallButtonStyle()).fixedSize()
            Button { pickFiles() } label: {
                HStack(spacing: 5) {
                    if sending > 0 { ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 11, height: 11) }
                    else { Image(systemName: "paperclip").font(.system(size: 11, weight: .medium)) }
                    Text(sending > 0 ? DevicesText.t("发送中…", "Sending…") : DevicesText.t("发送文件或文件夹…", "Send file or folder…"))
                }
            }.buttonStyle(DevicesSmallButtonStyle()).disabled(sending > 0).fixedSize()
        }
        .padding(.horizontal, 16).frame(height: 84)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColor.accent.opacity(dropTargeted ? 0.14 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppColor.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .opacity(row.isOnline ? 1 : 0.55)
        .modifier(DevicesDropTarget(targeted: $dropTargeted, perform: handleDrop))
    }

    private var connectionGrid: some View {
        let cells: [(String, String, Bool)] = [
            (DevicesText.t("连接于", "Connected"), Self.time(stats.connectedAt), false),
            (DevicesText.t("最近发送", "Last sent"), Self.time(stats.lastSentAt), false),
            (DevicesText.t("最近 ACK", "Last ACK"), Self.time(stats.lastAckAt), false),
            (DevicesText.t("最近接收", "Last received"), Self.time(stats.lastReceivedAt), false),
            (DevicesText.t("待发送", "Pending"), "\(stats.pending)", false),
            (DevicesText.t("最近错误", "Last error"), stats.lastError ?? "—", stats.lastError != nil),
        ]
        return VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { r in
                if r == 1 { SplitV3Hairline() }
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { c in
                        if c > 0 { SplitV3Hairline(vertical: true) }
                        let cell = cells[r * 3 + c]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cell.0).font(.system(size: 11)).foregroundStyle(SplitV3Color.text3)
                            Text(cell.1).font(.system(size: 13, weight: .medium)).monospacedDigit()
                                .foregroundStyle(cell.2 ? Color(nsColor: .systemRed) : Color.primary)
                                .lineLimit(1).truncationMode(.tail).help(cell.1)
                        }.padding(.horizontal, 14).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }.devicesCard()
    }

    private var receiveCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.plus").font(.system(size: 14))
                .foregroundStyle(Color(red: 0.49, green: 0.23, blue: 0.93))
                .frame(width: 30, height: 30)
                .background(Color(red: 0.49, green: 0.23, blue: 0.93).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(DevicesText.t("收到的文件存入「下载/Clipy」", "Received files are saved to Downloads/Clipy"))
                    .font(.system(size: 12.5, weight: .medium))
                Text(DevicesText.t("同名自动另存；同时出现在剪贴板历史，并发送系统通知", "Duplicates are renamed; files also appear in clipboard history with a system notification"))
                    .font(.system(size: 11)).foregroundStyle(SplitV3Color.text3)
            }
            Spacer(minLength: 0)
            Button { Self.revealDownloads() } label: {
                Label(DevicesText.t("在访达中显示", "Show in Finder"), systemImage: "folder")
            }.buttonStyle(DevicesSmallButtonStyle())
        }.padding(.horizontal, 14).padding(.vertical, 10).devicesCard()
    }

    // MARK: Sending

    private func sendText() {
        sendNote = nil
        guard row.isOnline, syncEnabled else { sendError = L10n.t(.sendFailed); return }
        sendError = nil
        (NSApp.delegate as? AppDelegate)?.menuController?.sendText(to: row.peerId)
    }

    private func pickFiles() {
        sendNote = nil
        guard row.isOnline, syncEnabled else { sendError = L10n.t(.sendFailed); return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L10n.format(.chooseFileToSend, row.name)
        panel.prompt = L10n.t(.send)
        guard panel.runModal() == .OK else { return }
        send(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        guard row.isOnline, syncEnabled else { sendError = L10n.t(.sendFailed); return true }
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { send(urls) }
        return true
    }

    /// Each item goes through the existing per-file transfer (folders are archived by SyncManager).
    private func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        sendError = nil
        sendNote = nil
        let peerId = row.peerId
        let name = row.name
        var failures = 0
        var remaining = urls.count
        sending += urls.count
        for url in urls {
            SyncManager.shared.sendFileToPeer(at: url, peerId: peerId) { success, error in
                sending = max(0, sending - 1)
                remaining -= 1
                if !success {
                    failures += 1
                    sendError = error != nil ? L10n.t(.folderSendPreparationFailed) : L10n.t(.sendFailed)
                }
                if remaining == 0 && failures == 0 {
                    let label = urls.count == 1 ? "“\(urls[0].lastPathComponent)”"
                        : DevicesText.t("\(urls.count) 项", "\(urls.count) items")
                    sendNote = DevicesText.t("\(label)已发送到 \(name)", "\(label) sent to \(name)")
                }
            }
        }
    }

    static func revealDownloads() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let folder = downloads.appendingPathComponent("Clipy", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(downloads)
        }
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: date)
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return DevicesText.t("昨天 \(clock)", "Yesterday \(clock)") }
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

extension View {
    /// `.form` card: content background, 10pt radius, hairline outline.
    func devicesCard(radius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(SplitV3Color.content))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(SplitV3Color.line, lineWidth: 0.5))
    }
}

/// File drop handling; skipped in isolated snapshots where no drag session can exist.
private struct DevicesDropTarget: ViewModifier {
    @Binding var targeted: Bool
    let perform: ([NSItemProvider]) -> Bool
    func body(content: Content) -> some View {
        #if CLIPY_CORE_TESTS
        if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return AnyView(content) }
        #endif
        return AnyView(content.onDrop(of: [UTType.fileURL], isTargeted: $targeted, perform: perform))
    }
}

// MARK: - Manual add sheet

struct DevicesManualAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "\(PreferencesManager.shared.syncPort)"
    @State private var invalid = false
    let onAdded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DevicesText.t("手动添加设备（跨频段/跨子网兜底）", "Add a device manually (other bands / subnets)"))
                .font(.system(size: 15, weight: .semibold))
            Text(DevicesText.t("当自动发现失效（如 2.4G/5G 隔离）时，在对端查看 IP 后在此手动添加。", "When discovery fails (e.g. 2.4G/5G isolation), check the other device's IP and add it here."))
                .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2).padding(.top, 6).padding(.bottom, 14)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(DevicesText.t("IP 地址（如 192.168.1.20）", "IP address (e.g. 192.168.1.20)"), text: $host)
                    .font(.system(size: 13, design: .monospaced)).onSubmit(add)
                TextField(DevicesText.t("端口", "Port"), text: $port)
                    .font(.system(size: 13, design: .monospaced)).frame(width: 84).onSubmit(add)
            }.textFieldStyle(.roundedBorder)
            if invalid {
                Text(DevicesText.t("请输入有效的 IPv4 地址和 1–65535 的整数端口", "Enter a valid IPv4 address and an integer port from 1 to 65535"))
                    .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: .systemRed)).padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t(.cancel)) { dismiss() }.buttonStyle(SplitV3ButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.t(.syncAdd), action: add).buttonStyle(SplitV3ButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }.padding(.top, 18)
        }.padding(20).frame(width: 390)
    }

    private func add() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let portValue = DeviceConnectionInput.port(port)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let valid = parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && (Int($0).map { (0...255).contains($0) } ?? false) }
        guard valid, let portValue else { invalid = true; return }
        let entry = "\(trimmed):\(portValue)"
        if !PreferencesManager.shared.manualSyncPeers.contains(entry) {
            PreferencesManager.shared.addManualPeer(entry)
            SyncManager.shared.triggerCrossBandDiscovery()
        }
        onAdded()
        dismiss()
    }
}
