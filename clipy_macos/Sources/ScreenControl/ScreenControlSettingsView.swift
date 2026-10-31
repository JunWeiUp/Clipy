import SwiftUI

struct ScreenControlSettingsView: View {
    @State private var credential = ""
    @State private var message = ""
    @State private var configured = Self.initialConfigured
    @FocusState private var fieldFocused: Bool
    private static var initialConfigured: Bool {
        #if CLIPY_CORE_TESTS
        if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return false }
        #endif
        return ScreenControlManager.shared.configured
    }
    private var unlockReady: Bool {
        #if CLIPY_CORE_TESTS
        if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return false }
        #endif
        return ScreenControlManager.unlockReady
    }
    private func t(_ zh: String, _ en: String) -> String { PreferencesManager.shared.appLanguage == .zh ? zh : en }
    var body: some View {
        SettingsSubheader(t("手机控制 Mac 屏幕", "Control Mac screen from phone"))
        SettingsCard {
            SettingsCustomRow(searchText: t("配置当前 Mac 登录密码后，手机设备页才会显示锁屏和解锁按钮。", "Configure this Mac's login password")) {
                SettingsRowIcon(symbol: "iphone", tint: .blue)
                Text(t("配置当前 Mac 登录密码后，手机设备页才会显示锁屏和解锁按钮。密码仅保存在本机钥匙串；所有已连接设备都可直接控制，无需输入密钥。", "Configure this Mac's login password to show Lock and Unlock on the phone. The password stays in this Mac's Keychain. All connected devices can control it without a key."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsPalette.text2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRow(title: configured ? t("已配置", "Configured") : t("未配置", "Not configured"))
            VStack(alignment: .leading, spacing: 8) {
                Text(t("当前 Mac 登录密码", "Current Mac login password"))
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsPalette.text)
                SecureField("", text: $credential, prompt: Text(t("点击此处输入登录密码", "Enter your Mac login password")).foregroundColor(SettingsPalette.text3))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity)
                    .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(fieldFocused ? AppColor.accent : SettingsPalette.controlLine, lineWidth: fieldFocused ? 1 : 0.5)
                    }
                    .shadow(color: fieldFocused ? AppColor.accent.opacity(0.22) : .clear, radius: 3)
                    .accessibilityLabel(t("当前 Mac 登录密码", "Current Mac login password"))
                Text(t("输入密码后即可点击“验证并保存”。配置密码不需要辅助功能权限。", "Enter your password to enable Verify and save. Accessibility permission is not required to configure it."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSearchable(t("当前 Mac 登录密码", "Current Mac login password"))
            SettingsCustomRow(searchText: t("验证并保存 关闭并删除密码", "Verify and save Disable and delete password")) {
                Button(t("验证并保存", "Verify and save")) {
                    do {
                        try ScreenControlManager.shared.configure(password: credential)
                        credential = ""; configured = true
                        message = t("已保存，连接的手机现在可以直接锁屏或解锁。", "Saved. Connected phones can now lock or unlock this Mac directly.")
                    } catch { configured = ScreenControlManager.shared.configured; credential = ""; message = t("验证或钥匙串保存失败，请确认当前账户登录密码。", "Verification or Keychain save failed. Check this account's login password.") }
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(credential.isEmpty)
                Button(t("关闭并删除密码", "Disable and delete password")) {
                    do { try ScreenControlManager.shared.disable(); configured = false; credential = ""; message = "" }
                    catch { configured = ScreenControlManager.shared.configured; message = t("钥匙串操作失败", "Keychain operation failed") }
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!configured)
                Spacer(minLength: 0)
            }
            if !message.isEmpty {
                SettingsCaptionRow(message, color: SettingsPalette.text2)
            }
            SettingsCaptionRow(
                unlockReady
                    ? t("辅助功能权限已允许", "Accessibility permission allowed")
                    : t("请允许辅助功能权限", "Allow Accessibility permission"),
                symbol: unlockReady ? "checkmark.circle" : "info.circle")
            SettingsCaptionRow(t("锁屏和解锁均通过本应用的辅助功能权限执行，无需额外组件；解锁仅支持当前已登录账户的锁屏，不支持开机 FileVault、注销或切换用户。", "Locking and unlocking use this app’s Accessibility permission; no helper is required. Unlocking supports only the current logged-in account's lock screen, not FileVault, logout or user switching."))
        }
        .onDisappear { credential = "" }
    }
}
