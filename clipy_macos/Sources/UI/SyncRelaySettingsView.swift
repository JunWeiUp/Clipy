import SwiftUI

struct SyncRelaySettingsView: View {
    var openGroup: (() -> Void)? = nil
    @State private var enabled = SyncRelaySettings.enabled
    @State private var url = SyncRelaySettings.url
    @State private var deviceID = SyncRelaySettings.deviceID
    @State private var accessKey = ""
    @State private var accessPassword = ""
    @State private var showPassword = false
    @State private var passwordSaved = false
    @ObservedObject private var connection = SyncRelayConnectionState.shared
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
            SettingsRow(title: zh ? "访问密码" : "Access password", labelWidth: 180) {
                HStack(spacing: 8) {
                    Group {
                        if showPassword { TextField(zh ? "留空保留已保存密码" : "Blank keeps saved password", text: $accessPassword) }
                        else { SecureField(zh ? "留空保留已保存密码" : "Blank keeps saved password", text: $accessPassword) }
                    }.modifier(SettingsTextFieldStyle())
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(zh ? (showPassword ? "隐藏密码" : "显示密码") : (showPassword ? "Hide password" : "Show password"))
                }
            }
            SettingsCaptionRow(zh ? "8–128 位可见 ASCII 字符，不含空格，按服务器地址保存于本机钥匙串。新邀请携带访问密码，扫码或粘贴后自动安全保存。" : "8–128 visible ASCII characters without spaces, stored in this Mac’s Keychain per server URL. New invitations include it and securely save it when scanned or pasted.")
            SettingsCaptionRow(passwordSaved ? (zh ? "此地址已保存访问密码。" : "Access password saved for this URL.") : (zh ? "尚未保存密码。可使用新邀请直接加入；创建组或使用旧邀请前需保存密码。" : "No saved password. Join directly with a new invitation; save a password before creating a group or using an older invitation."))
            SettingsRow(title: zh ? "连接状态" : "Connection status") {
                Text(connectionMessage).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
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
                        if try SyncRelaySettings.save(enabled: enabled, url: url, token: enrollment, deviceID: deviceID, accessKey: accessKey, accessPassword: accessPassword.isEmpty ? nil : accessPassword) {
                            SyncManager.shared.restartRelayConfiguration()
                        }
                        accessKey = ""; enrollment = ""; accessPassword = ""; showPassword = false
                        refreshPasswordState()
                        message = zh ? "已保存；连接状态以服务器响应为准。" : "Saved. Connection status depends on the server response."
                    } catch is SyncRelayAccessPolicy.Failure {
                        message = zh ? "请填写 8–128 位可见 ASCII 访问密码，不能包含空格或换行。" : "Enter an 8–128 character visible ASCII access password, without spaces or newlines."
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
        .onAppear { refreshPasswordState() }
        .onChange(of: url) { _ in refreshPasswordState() }
        .onDisappear { accessPassword = ""; accessKey = ""; enrollment = ""; showPassword = false }
    }
    private func refreshPasswordState() { passwordSaved = (try? SyncRelaySettings.accessPassword(url: url.trimmingCharacters(in: .whitespacesAndNewlines))) != nil }
    private var connectionMessage: String {
        switch connection.status {
        case .disabled: return zh ? "未连接" : "Not connected"
        case .connecting: return zh ? "正在连接…" : "Connecting…"
        case .connected: return zh ? "已连接 · 端到端加密" : "Connected · End-to-end encrypted"
        case .authenticationRequired: return zh ? "认证未通过：请检查访问密码、设备 Key 和组权限。" : "Authentication failed: check the access password, device key and group access."
        case .unavailable: return zh ? "暂时无法连接，请检查网络和认证设置。" : "Connection unavailable. Check the network and authentication settings."
        }
    }
}
