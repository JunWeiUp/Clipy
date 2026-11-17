import SwiftUI
import AppKit

/// Unified relay settings surface: group management and transport connection share
/// one entry in the Devices module while retaining their existing business owners.
struct RelaySettingsWorkspaceView: View {
    enum Tab: Hashable { case group, connection }
    @Binding var page: DevicesPage
    let fixture: SyncRelayGroups?
    @State private var tab: Tab

    init(page: Binding<DevicesPage>, fixture: SyncRelayGroups? = nil) {
        _page = page
        self.fixture = fixture
        _tab = State(initialValue: page.wrappedValue == .relaySettings ? .connection : .group)
    }

    var body: some View {
        VStack(spacing: 0) {
            SplitV3Toolbar {
                Text(text("中继设置", "Relay settings"))
                    .font(.system(size: 15, weight: .semibold))
                Text(text("管理公网设备组与中继连接", "Manage relay groups and connection"))
                    .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                    .lineLimit(1)
                Picker("", selection: $tab) {
                    Text(text("公网设备组", "Relay device group")).tag(Tab.group)
                    Text(text("中继连接", "Relay connection")).tag(Tab.connection)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .padding(.leading, 12)
                .accessibilityLabel(text("中继设置选项", "Relay settings section"))
                Spacer(minLength: 8)
                if tab == .connection {
                    Button { openPublicProject() } label: {
                        Label(text("中继公开项目", "Relay project"), systemImage: "arrow.up.right.square")
                    }.buttonStyle(DevicesSmallButtonStyle())
                }
            }
            if tab == .group {
                SyncRelayGroupView(embedded: true, fixture: fixture, showToolbar: false)
            } else {
                ScrollView {
                    SyncRelaySettingsView(openGroup: { tab = .group })
                        .padding(28)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                }
                .background(SplitV3Color.inspector)
            }
        }
        .onChange(of: tab) { value in page = value == .connection ? .relaySettings : .relay }
        .onChange(of: page) { value in
            let next: Tab = value == .relaySettings ? .connection : .group
            if tab != next { tab = next }
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        PreferencesManager.shared.appLanguage == .zh ? zh : en
    }

    private func openPublicProject() {
        guard let url = URL(string: "https://github.com/JunWeiUp/common-relay") else { return }
        NSWorkspace.shared.open(url)
    }
}
