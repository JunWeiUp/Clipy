import SwiftUI
import AppKit

struct SyncRelaySettingsView: View {
    var openGroup: (() -> Void)? = nil
    @State private var enabled = SyncRelaySettings.enabled
    @State private var url = SyncRelaySettings.url
    @State private var deviceID = SyncRelaySettings.deviceID
    @State private var accessKey = ""
    @State private var showKey = false
    @State private var accessPassword = ""
    @State private var showPassword = false
    @State private var passwordSaved = false
    @ObservedObject private var connection = SyncRelayConnectionState.shared
    @State private var enrollment = ""
    @State private var showEnrollmentText = true
    @State private var message = ""
    @State private var showGroup = false
    @State private var showEnrollment = false
    private var zh: Bool { PreferencesManager.shared.appLanguage == .zh }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSubheader(zh ? "中继连接" : "Relay connection")
            SettingsCard {
                SettingsRow(icon: SettingsRowIcon(symbol: "globe", tint: .blue), title: zh ? "公网设备组" : "Relay device group") {
                    Button(zh ? "管理公网设备组…" : "Manage relay device group…") { if let openGroup { openGroup() } else { showGroup = true } }
                        .buttonStyle(SettingsButtonStyle())
                        .sheet(isPresented: $showGroup) { SyncRelayGroupView() }
                }
                SettingsRow(title: zh ? "启用公网中继" : "Enable Internet relay") { SettingsSwitch(isOn: $enabled) }
                SettingsRow(title: zh ? "中继地址" : "Relay URL", labelWidth: 180) {
                    TextField("wss://relay.example/v2/ws", text: $url).modifier(SettingsTextFieldStyle())
                }
                SettingsRow(title: zh ? "访问密码" : "Access password", labelWidth: 180) {
                    HStack(spacing: 8) {
                        Group {
                            if showPassword { TextField(zh ? "留空保留已保存密码" : "Blank keeps saved password", text: $accessPassword) }
                            else { SecureField(zh ? "留空保留已保存密码" : "Blank keeps saved password", text: $accessPassword) }
                        }.modifier(SettingsTextFieldStyle())
                        Button {
                            if !showPassword, accessPassword.isEmpty,
                               let saved = try? SyncRelaySettings.effectiveAccessPassword(for: url.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                accessPassword = saved
                            }
                            showPassword.toggle()
                        } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(zh ? (showPassword ? "隐藏密码" : "显示密码") : (showPassword ? "Hide password" : "Show password"))
                    }
                }
                SettingsCaptionRow(zh ? "8–128 位可见 ASCII 字符，不含空格，按服务器地址保存于本机钥匙串。点右侧眼睛可载入并修改已保存密码；同域名切换 v1/v2 路径时留空会自动沿用原密码。" : "8–128 visible ASCII characters without spaces, stored in this Mac’s Keychain per server URL. Click the eye icon to load and edit the saved password; switching paths on the same host carries it over automatically.")
                SettingsCaptionRow(passwordSaved ? (zh ? "此地址已保存访问密码（可随时修改）。" : "Access password saved for this URL (editable anytime).") : (zh ? "尚未保存密码。请填写后保存，或使用新邀请加入。" : "No saved password. Enter one and save, or join with a new invitation."))
                SettingsRow(title: zh ? "连接状态" : "Connection status") {
                    Text(connectionMessage).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                SettingsRow(title: zh ? "设备 ID" : "Device ID", labelWidth: 180) {
                    TextField("", text: $deviceID).modifier(SettingsTextFieldStyle())
                }
                SettingsRow(title: zh ? "公网 Key（留空保持不变）" : "Internet Key (blank keeps saved key)", labelWidth: 180) {
                    HStack(spacing: 8) {
                        Group {
                            if showKey { TextField(zh ? "留空保持已保存 Key" : "Blank keeps saved key", text: $accessKey) }
                            else { SecureField(zh ? "留空保持已保存 Key" : "Blank keeps saved key", text: $accessKey) }
                        }.modifier(SettingsTextFieldStyle())
                        Button {
                            if !showKey, accessKey.isEmpty,
                               let saved = SyncRelayClient.Access.parse(SyncRelaySettings.token())?.token {
                                accessKey = saved
                            }
                            showKey.toggle()
                        } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(zh ? (showKey ? "隐藏 Key" : "显示并编辑 Key") : (showKey ? "Hide key" : "Show and edit key"))
                    }
                }
                SettingsCaptionRow(zh ? "设备 ID 与服务端登记一致；点右侧眼睛可载入已保存的 Key 直接修改。局域网无需配置中继。" : "Use the registered device ID; click the eye icon to load and edit the saved key. LAN needs no relay setup.")
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
                    SettingsCustomRow(searchText: zh ? "本设备接入配置 JSON" : "Device enrollment JSON", minHeight: 36) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(zh ? "本设备接入配置 JSON" : "Device enrollment JSON")
                                    .font(.system(size: 13))
                                    .foregroundStyle(SettingsPalette.text)
                                Spacer(minLength: 0)
                                Button(zh ? "载入当前配置" : "Load current") {
                                    let current = SyncRelaySettings.token()
                                    if current.isEmpty {
                                        message = zh ? "本机尚未保存接入配置 JSON。" : "No saved enrollment JSON yet."
                                    } else {
                                        enrollment = current
                                        showEnrollmentText = true
                                        syncDeviceFromEnrollment(current)
                                        message = zh ? "已载入当前保存的配置，可直接修改后点保存。" : "Loaded current saved configuration; edit and save anytime."
                                    }
                                }.buttonStyle(SettingsButtonStyle())
                                Button(zh ? "粘贴剪贴板" : "Paste") {
                                    if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                        enrollment = clip
                                        showEnrollmentText = true
                                        syncDeviceFromEnrollment(clip)
                                    }
                                }.buttonStyle(SettingsButtonStyle())
                                Button {
                                    showEnrollmentText.toggle()
                                } label: { Image(systemName: showEnrollmentText ? "eye.slash" : "eye") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(zh ? (showEnrollmentText ? "隐藏配置" : "显示配置") : (showEnrollmentText ? "Hide JSON" : "Show JSON"))
                            }
                            if showEnrollmentText {
                                TextEditor(text: $enrollment)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(minHeight: 74, maxHeight: 140)
                                    .padding(6)
                                    .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(SettingsPalette.controlLine, lineWidth: 0.5)
                                            .allowsHitTesting(false)
                                    )
                            } else {
                                SecureField(zh ? "粘贴接入配置 JSON" : "Paste enrollment JSON", text: $enrollment)
                                    .modifier(SettingsTextFieldStyle())
                            }
                            Text(zh ? "支持多行或单行 JSON，随时可点「载入当前配置」修改后重新保存；粘贴新 JSON 时会自动同步上方的设备 ID。" : "Supports single-line or multiline JSON. Click Load current anytime to edit and re-save; pasting valid JSON automatically updates Device ID.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsPalette.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 20)
                }
                SettingsCustomRow(searchText: zh ? "保存中继设置" : "Save relay settings") {
                    Button(zh ? "保存中继设置" : "Save relay settings") {
                        saveRelaySettings()
                    }
                    .buttonStyle(SettingsButtonStyle())
                    if !message.isEmpty {
                        Text(message).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .onAppear {
                refreshPasswordState()
            }
            .onChange(of: url) { _ in refreshPasswordState() }
            .onChange(of: enrollment) { newValue in syncDeviceFromEnrollment(newValue) }
            .onDisappear {
                accessPassword = ""; accessKey = ""; enrollment = ""
                showPassword = false; showKey = false
            }
        }
    }

    private func syncDeviceFromEnrollment(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dev = obj["device"] as? String,
              SyncRelaySettings.validDeviceID(dev) else { return }
        if deviceID != dev {
            deviceID = dev
        }
    }

    private func saveRelaySettings() {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnroll = enrollment.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPass = accessPassword.trimmingCharacters(in: .newlines)

        // If the user pasted a valid JSON with a device ID, sync deviceID before validation.
        if !trimmedEnroll.isEmpty {
            syncDeviceFromEnrollment(trimmedEnroll)
        }
        let trimmedDevice = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)

        if enabled && !SyncRelayClient.validURL(trimmedURL) {
            message = zh ? "中继地址无效：请填写 wss://…/v2/ws 或 wss://…/relay/v1/ws。" : "Invalid relay URL: use wss://…/v2/ws or wss://…/relay/v1/ws."
            return
        }
        if !SyncRelaySettings.validDeviceID(trimmedDevice) {
            message = zh ? "设备 ID 格式无效（仅允许字母、数字、-、_，1–80 位）。" : "Invalid device ID (1–80 alphanumeric, - or _ characters)."
            return
        }
        if !trimmedEnroll.isEmpty {
            guard let data = trimmedEnroll.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                message = zh ? "接入配置 JSON 格式错误，请确认完整复制。" : "Invalid enrollment JSON syntax."
                return
            }
            if let dev = obj["device"] as? String, dev != trimmedDevice {
                message = zh ? "设备 ID（\(trimmedDevice)）与 JSON 中的 device（\(dev)）不一致。" : "Device ID (\(trimmedDevice)) does not match JSON device (\(dev))."
                return
            }
            if SyncRelayClient.Access.parse(trimmedEnroll) == nil {
                message = zh ? "接入配置 JSON 缺少有效字段（需含 app=\"clipy\"、group、device、token≥32位、secret_key、trusted_peers）。" : "Enrollment JSON is missing required valid fields."
                return
            }
        }
        do {
            let changed = try SyncRelaySettings.save(
                enabled: enabled,
                url: trimmedURL,
                token: trimmedEnroll,
                deviceID: trimmedDevice,
                accessKey: trimmedKey,
                accessPassword: cleanPass.isEmpty ? nil : cleanPass
            )
            if changed {
                SyncManager.shared.restartRelayConfiguration()
            }
            url = SyncRelaySettings.url
            deviceID = SyncRelaySettings.deviceID
            accessKey = ""; enrollment = ""; accessPassword = ""
            showPassword = false; showKey = false
            refreshPasswordState()
            message = zh ? "已保存并重连；所有字段随时可继续修改。" : "Saved and reconnecting; all fields remain editable anytime."
        } catch is SyncRelayAccessPolicy.Failure {
            message = zh ? "请填写 8–128 位可见 ASCII 访问密码，不能包含空格或换行。" : "Enter an 8–128 character visible ASCII access password, without spaces or newlines."
        } catch {
            message = zh ? "保存失败：\(error.localizedDescription)" : "Could not save: \(error.localizedDescription)"
        }
    }

    private func refreshPasswordState() {
        passwordSaved = (try? SyncRelaySettings.effectiveAccessPassword(for: url.trimmingCharacters(in: .whitespacesAndNewlines))) != nil
    }

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
