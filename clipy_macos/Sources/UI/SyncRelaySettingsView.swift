import SwiftUI

struct SyncRelaySettingsView: View {
    var openGroup: (() -> Void)? = nil
    @State private var enabled = SyncRelaySettings.enabled
    @State private var url = SyncRelaySettings.url
    @State private var deviceID = SyncRelaySettings.deviceID
    @State private var accessKey = ""
    @State private var enrollment = ""
    @State private var message = ""
    @State private var showGroup = false
    @State private var showEnrollment = false
    private var zh: Bool { PreferencesManager.shared.appLanguage == .zh }
    var body: some View {
        SettingsSubheader(zh ? "公网中继" : "Internet relay")
        SettingsCard {
            SettingsRow(icon: SettingsRowIcon(symbol: "globe", tint: .blue), title: zh ? "公网设备组" : "Relay device group") {
                Button(zh ? "管理公网设备组…" : "Manage relay device group…") { if let openGroup { openGroup() } else { showGroup = true } }
                    .buttonStyle(SettingsButtonStyle())
                    .sheet(isPresented: $showGroup) { SyncRelayGroupView() }
            }
            SettingsRow(title: zh ? "启用公网中继" : "Enable Internet relay") { SettingsSwitch(isOn: $enabled) }
            SettingsRow(title: zh ? "中继地址" : "Relay URL", labelWidth: 180) {
                TextField("", text: $url).modifier(SettingsTextFieldStyle())
            }
            SettingsRow(title: zh ? "设备 ID" : "Device ID", labelWidth: 180) {
                TextField("", text: $deviceID).modifier(SettingsTextFieldStyle())
            }
            SettingsRow(title: zh ? "公网 Key（留空保持不变）" : "Internet Key (blank keeps saved key)", labelWidth: 180) {
                SecureField("", text: $accessKey).modifier(SettingsTextFieldStyle())
            }
            SettingsCaptionRow(zh ? "设备 ID 与服务端登记一致；只换 Key 时保留 ID。局域网无需配置中继。" : "Use the registered device ID; keep it when replacing the key. LAN needs no relay setup.")
            SettingsCustomRow(searchText: zh ? "首次接入 / 更新信任配置" : "Enrollment / trusted peers") {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showEnrollment.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(showEnrollment ? 90 : 0))
                        Text(zh ? "首次接入 / 更新信任配置" : "Enrollment / trusted peers")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(SettingsPalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(showEnrollment ? (zh ? "已展开" : "Expanded") : (zh ? "已收起" : "Collapsed"))
            }
            if showEnrollment {
                SettingsRow(title: zh ? "本设备接入配置 JSON" : "Device enrollment JSON", labelWidth: 180) {
                    SecureField("", text: $enrollment).modifier(SettingsTextFieldStyle())
                }
                .padding(.leading, 20)
                SettingsCaptionRow(zh ? "首次接入时导入；仅换 Key 无需重复填写。" : "Import once. Not needed when only replacing the key.")
                    .padding(.leading, 20)
            }
            SettingsCustomRow(searchText: zh ? "保存中继设置" : "Save relay settings") {
                Button(zh ? "保存中继设置" : "Save relay settings") {
                    do {
                        if try SyncRelaySettings.save(enabled: enabled, url: url, token: enrollment, deviceID: deviceID, accessKey: accessKey) {
                            SyncManager.shared.restartRelayConfiguration()
                        }
                        accessKey = ""; enrollment = ""
                        message = zh ? "已保存" : "Saved"
                    } catch {
                        message = zh ? "保存失败，请检查设备 ID、WSS 地址、Key 和接入配置；首次使用需导入接入配置。" : "Could not save. Check device ID, WSS URL, key and enrollment. First setup requires enrollment."
                    }
                }
                .buttonStyle(SettingsButtonStyle())
                if !message.isEmpty {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
