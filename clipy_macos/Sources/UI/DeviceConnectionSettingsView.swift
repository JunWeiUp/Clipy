import SwiftUI

/// Device-local configuration. Mounted only on the active device subpage; no timers
/// or extra device caches. Name drafts flush on blur/leave, port/relay edits commit
/// explicitly. Manual addresses remain bounded by the existing preferences owner.
enum DeviceConnectionInput {
    static func port(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(value), (1...65535).contains(port) else { return nil }
        return port
    }
}

struct DeviceConnectionSettingsView: View {
    @Binding var page: DevicesPage
    @Binding var syncEnabled: Bool
    let onlineCount: Int
    @State private var deviceName = PreferencesManager.shared.deviceName
    @State private var port = String(PreferencesManager.shared.syncPort)
    @State private var manualPeers = PreferencesManager.shared.manualSyncPeers
    @State private var invalidPort = false
    @State private var showAdd = false
    @FocusState private var nameFocused: Bool

    private var isSnapshot: Bool {
        #if CLIPY_CORE_TESTS
        return ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil
        #else
        return false
        #endif
    }
    private var title: String {
        switch page {
        case .screenControl: return settingsText("手机控制 Mac", "Control this Mac")
        case .relaySettings: return settingsText("中继连接", "Relay connection")
        default: return settingsText("局域网设置", "LAN settings")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SplitV3Toolbar {
                Text(title).font(.system(size: 15, weight: .semibold))
                if page != .screenControl {
                    Picker("", selection: $page) {
                        Text(settingsText("局域网", "LAN")).tag(DevicesPage.lan)
                        Text(settingsText("中继连接", "Relay")).tag(DevicesPage.relaySettings)
                    }.pickerStyle(.segmented).frame(width: 190).padding(.leading, 12)
                        .accessibilityLabel(settingsText("连接类型", "Connection type"))
                }
                Spacer()
                Text(settingsText("本机配置", "This Mac")).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
            }
            ScrollView {
                if page == .screenControl {
                    VStack(alignment: .leading, spacing: 12) { ScreenControlSettingsView() }
                        .padding(28).frame(maxWidth: 800).frame(maxWidth: .infinity)
                } else if page == .relaySettings {
                    VStack(alignment: .leading, spacing: 12) {
                        SyncRelaySettingsView(openGroup: { page = .relay })
                    }.padding(28).frame(maxWidth: 800).frame(maxWidth: .infinity)
                } else {
                    lanContent.padding(28)
                }
            }
        }
        .background(SplitV3Color.inspector)
        .onChange(of: nameFocused) { focused in if !focused { saveName() } }
        .onChange(of: page) { _ in saveName() }
        .onDisappear { saveName() }
        .sheet(isPresented: $showAdd) {
            DevicesManualAddSheet { manualPeers = PreferencesManager.shared.manualSyncPeers }
        }
    }

    private var lanContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "network").font(.system(size: 24)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(AppColor.accent, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(settingsText("让设备在同一网络中相连", "Connect devices on your network"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(settingsText("自动发现附近设备，直接同步剪贴板与通知。", "Discover nearby devices and sync clipboard and notifications directly."))
                        .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text3)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    localSettings
                    manualSettings
                }.frame(maxWidth: .infinity)
                guide.frame(width: 216)
            }
        }.frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder private var localSettings: some View {
        SettingsSubheader(settingsText("本机", "This Mac"))
        SettingsCard {
            SettingsRow(title: L10n.t(.designDeviceName), detail: settingsText("其他设备看到的名称", "Name shown to other devices")) {
                TextField("", text: $deviceName).modifier(SettingsTextFieldStyle())
                    .frame(maxWidth: 210).focused($nameFocused).onSubmit(saveName)
                    .accessibilityLabel(L10n.t(.designDeviceName))
            }
            SettingsRow(title: settingsText("设备 ID", "Device ID")) {
                Text(String(PreferencesManager.shared.syncPeerId.prefix(8)) + "…")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(SplitV3Color.text3)
                    .textSelection(.enabled)
            }
        }
        SettingsSubheader(settingsText("局域网同步", "LAN sync"))
        SettingsCard {
            SettingsRow(title: L10n.t(.enableLanSync), detail: settingsText("同一网段内自动发现，无需配对", "Automatic discovery on the same subnet; no pairing required")) {
                SettingsSwitch(isOn: $syncEnabled).accessibilityLabel(L10n.t(.enableLanSync))
            }
            SettingsRow(title: L10n.t(.syncPort), detail: settingsText("有效范围 1–65535", "Valid range: 1–65535")) {
                TextField("5566", text: $port).modifier(SettingsTextFieldStyle()).frame(width: 76)
                    .accessibilityLabel(L10n.t(.syncPort)).onSubmit(savePort)
                Button(L10n.t(.save), action: savePort).buttonStyle(SettingsButtonStyle())
            }
            if invalidPort {
                SettingsCaptionRow(settingsText("端口必须是 1–65535 的整数。", "Port must be an integer from 1 to 65535."), color: SettingsPalette.bad)
            }
            SettingsCaptionRow(connectionStatus)
        }
    }

    private var connectionStatus: String {
        guard syncEnabled else { return settingsText("已关闭 · 暂停局域网自动发现与同步", "Off · LAN discovery and sync paused") }
        let ip = isSnapshot ? "192.0.2.24" : SyncManager.shared.enumerateLocalIPv4s().first
        return ip.map { settingsText("本机地址 ", "Local address ") + $0 + ":\(PreferencesManager.shared.syncPort)" }
            ?? settingsText("已启用 · 等待可用的局域网连接", "Enabled · Waiting for a local network")
    }

    @ViewBuilder private var manualSettings: some View {
        SettingsSubheader(title: settingsText("手动连接", "Manual connections")) {
            Spacer()
            Button { showAdd = true } label: {
                Label(settingsText("添加 IP", "Add IP"), systemImage: "plus")
            }.buttonStyle(SettingsButtonStyle()).disabled(!syncEnabled)
        }
        SettingsCard {
            if manualPeers.isEmpty {
                SettingsCaptionRow(settingsText("暂无手动地址，设备仍会自动发现。", "No manual addresses. Devices are still discovered automatically."))
            }
            ForEach(manualPeers, id: \.self) { entry in
                SettingsRow(icon: SettingsRowIcon(symbol: "server.rack"), title: entry) {
                    Button {
                        PreferencesManager.shared.removeManualPeer(entry)
                        manualPeers = PreferencesManager.shared.manualSyncPeers
                        SyncManager.shared.triggerCrossBandDiscovery()
                    } label: {
                        Image(systemName: "minus.circle").frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(L10n.t(.delete))
                }
            }
        }
        SettingsFootnote(L10n.t(.syncManualDeviceHint))
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(settingsText("我的设备", "My devices"), systemImage: "laptopcomputer.and.iphone").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(onlineCount)").font(.system(size: 32, weight: .semibold))
                Text(settingsText("台在线", "online")).font(.system(size: 12)).foregroundStyle(SplitV3Color.text3)
            }
            Text(settingsText("查看在线与离线设备，按设备管理剪贴板和通知同步。", "View online and offline devices and manage clipboard and notification sync per device."))
                .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3).fixedSize(horizontal: false, vertical: true)
            Button { page = .devices } label: {
                HStack { Text(settingsText("管理设备", "Manage devices")); Spacer(); Image(systemName: "arrow.right") }
            }.buttonStyle(SettingsButtonStyle())
            Divider().padding(.vertical, 8)
            Label(settingsText("不在同一个网络？", "On another network?"), systemImage: "globe").font(.system(size: 13, weight: .semibold))
            Text(settingsText("通过公网设备组连接异地设备。局域网无需配置中继。", "Connect remote devices through a relay group. LAN needs no relay setup."))
                .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3).fixedSize(horizontal: false, vertical: true)
            Button(settingsText("管理公网设备组 →", "Manage relay group →")) { page = .relay }
                .buttonStyle(.plain).foregroundStyle(AppColor.accent).font(.system(size: 12))
        }.padding(20).devicesCard(radius: 12).padding(.top, 12)
    }

    private func saveName() {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { deviceName = PreferencesManager.shared.deviceName; return }
        deviceName = name
        guard !isSnapshot, name != PreferencesManager.shared.deviceName else { return }
        PreferencesManager.shared.deviceName = name
        if syncEnabled { SyncManager.shared.restartService() }
    }

    private func savePort() {
        guard let value = DeviceConnectionInput.port(port) else { invalidPort = true; return }
        invalidPort = false
        port = String(value)
        guard !isSnapshot, value != PreferencesManager.shared.syncPort else { return }
        PreferencesManager.shared.syncPort = value
        if syncEnabled { SyncManager.shared.restartService() }
    }
}
