import SwiftUI

struct SyncRelaySettingsView: View {
    @State private var enabled = SyncRelaySettings.enabled
    @State private var url = SyncRelaySettings.url
    @State private var deviceID = SyncRelaySettings.deviceID
    @State private var accessKey = ""
    @State private var enrollment = ""
    @State private var message = ""
    @State private var showGroup = false
    private var zh: Bool { PreferencesManager.shared.appLanguage == .zh }
    var body: some View {
        Section {
            Button(zh ? "管理公网设备组…" : "Manage relay device group…") { showGroup = true }
                .sheet(isPresented: $showGroup) { SyncRelayGroupView() }
            Toggle(zh ? "启用公网中继" : "Enable Internet relay", isOn: $enabled)
            TextField(zh ? "中继地址" : "Relay URL", text: $url)
            TextField(zh ? "设备 ID" : "Device ID", text: $deviceID)
            SecureField(zh ? "公网 Key（留空保持不变）" : "Internet Key (blank keeps saved key)", text: $accessKey)
            Text(zh ? "设备 ID 与服务端登记一致；只换 Key 时保留 ID。局域网无需配置中继。" : "Use the registered device ID; keep it when replacing the key. LAN needs no relay setup.")
                .font(AppFont.caption).foregroundStyle(.secondary)
            DisclosureGroup(zh ? "首次接入 / 更新信任配置" : "Enrollment / trusted peers") {
                SecureField(zh ? "本设备接入配置 JSON" : "Device enrollment JSON", text: $enrollment)
                Text(zh ? "首次接入时导入；仅换 Key 无需重复填写。" : "Import once. Not needed when only replacing the key.")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
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
            if !message.isEmpty { Text(message).font(AppFont.caption) }
        } header: { Text(zh ? "公网中继" : "Internet relay") }
    }
}
