import SwiftUI
import AppKit
import CoreImage
import Vision
import CommonRelay

struct SyncRelayGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SyncRelayGroups
    @State private var text = ""
    @State private var groupName = ""
    @State private var creating = true
    @State private var name = Host.current().localizedName ?? "Mac"
    @State private var grantManager = false
    @State private var showUpgrade = false
    @State private var removing: GroupRemoval?
    @State private var exiting: GroupExit?
    @State private var renaming: GroupRemoval?
    @State private var copied = false
    /// Embedded in the Devices window: no sheet "Done" button.
    private let openSettings: (() -> Void)?
    private let embedded: Bool
    private let isFixture: Bool
    private struct GroupExit: Identifiable { let disband: Bool;var id: Bool { disband } }
    private struct GroupRemoval: Identifiable { let id: String;let name: String }

    init(embedded: Bool = false, fixture: SyncRelayGroups? = nil, openSettings: (() -> Void)? = nil) {
        self.openSettings = openSettings
        self.embedded = embedded
        self.isFixture = fixture != nil
        _model = StateObject(wrappedValue: fixture ?? SyncRelayGroups())
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                ScrollView { leftColumn.padding(.horizontal, 22).padding(.vertical, 18) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SplitV3Hairline(vertical: true)
                rightColumn.frame(width: 330).frame(maxHeight: .infinity)
                    .background(SplitV3Color.inspector)
            }
        }
        .frame(minWidth: embedded ? 700 : 900, idealWidth: 1000, minHeight: 480, idealHeight: 690)
        .background(SplitV3Color.content)
        .textFieldStyle(.roundedBorder)
        .disabled(model.busy)
        .task { if !isFixture { model.perform { try await model.refresh() } } }
        .onDisappear { if !isFixture { model.close() } }
        .sheet(item:$renaming) { item in
            RelayDeviceNameEditor(name:item.name,zh:model.t("中","en")=="中") { value in model.perform { try await model.rename(item.id,name:value) } }
        }
        .sheet(item:$exiting) { action in
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(SplitV3Color.danger)
                Text(model.revoked ? model.t("清除失效的组配置？","Clear unavailable group configuration?") : action.disband ? model.t("解散整个设备组？","Disband this group?") : model.t("退出当前设备组？","Leave this group?")).font(.system(size: 15, weight: .semibold))
                Text(model.revoked ? model.t("只清除本机已失效的公网组配置，保留历史记录和局域网设置。然后可创建或加入其他设备组。","Clear only this device’s unavailable relay configuration. Local history and LAN settings are preserved. You can then create or join another group.") : action.disband ? model.t("所有设备将失去本组公网访问权限，未使用的邀请会失效。此操作不可撤销。本机历史记录和局域网配置会保留。","All devices lose relay access and invitations expire. This cannot be undone. Local history and LAN settings are preserved.") : model.t("仅本机离开，其他设备继续使用。若组内只剩本机，空组会同时关闭。本机历史记录和局域网配置会保留。","Only this device leaves; other devices continue using the group. Empty groups close. Local history and LAN settings are preserved."))
                    .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                HStack(spacing: 8) {
                    Button(model.t("取消","Cancel")) { exiting=nil }.buttonStyle(RelayWideButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(model.revoked ? model.t("清除并继续","Clear and continue") : action.disband ? model.t("确认解散","Disband group") : model.t("确认退出","Leave group")) { exiting=nil;model.perform { try await model.exitGroup(disband:action.disband);creating=true;groupName="";text="" } }
                        .buttonStyle(RelayWideButtonStyle(kind: .dangerFill))
                }
            }.padding(20).frame(width:400)
        }
        .sheet(item:$removing) { item in
            VStack(alignment:.leading,spacing:12) {
                Text(model.t("移除设备？","Remove device?")).font(.system(size: 15, weight: .semibold))
                Text(model.t("移除 \(item.name) 后，它将无法访问本组公网中继。局域网连接与已收到的内容不受影响。","\(item.name) will lose access to this relay group. LAN connections and previously received content are unaffected."))
                    .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer();Button(model.t("取消","Cancel")) { removing = nil }.buttonStyle(SplitV3ButtonStyle());Button(model.t("移除","Remove")) { removing = nil;model.perform { try await model.remove(item.id) } }.buttonStyle(SplitV3ButtonStyle(kind: .danger)) }.padding(.top, 6)
            }.padding(20).frame(width:400)
        }
    }

    // MARK: Toolbar

    private var isFresh: Bool { model.loaded && !model.enrolled && !model.legacy && !model.revoked && model.pendingCode.isEmpty && !model.creationPending }

    private var toolbar: some View {
        SplitV3Toolbar {
            Text(model.t("公网设备组","Relay device group")).font(.system(size: 15, weight: .semibold))
            Text(model.t("在不同网络之间连接你的设备","Connect your devices across networks"))
                .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).lineLimit(1)
            Spacer(minLength: 8)
            if model.busy { ProgressView().controlSize(.small) }
            if isFresh {
                Button { creating = false } label: { Label(model.t("加入已有组","Join group"), systemImage: "link") }
                    .buttonStyle(DevicesSmallButtonStyle())
                Button { creating = true } label: { Label(model.t("创建新组","Create group"), systemImage: "plus") }
                    .buttonStyle(DevicesSmallButtonStyle(primary: true))
            }
            Button { model.perform { try await model.refresh() } } label: { Label(model.t("刷新","Refresh"), systemImage: "arrow.clockwise") }
                .buttonStyle(DevicesSmallButtonStyle())
            if !embedded {
                Button(model.t("完成","Done")) { dismiss() }.buttonStyle(DevicesSmallButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            relaySummary
            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 12)).foregroundStyle(SplitV3Color.text2)
                    .textSelection(.enabled).padding(.top, 10)
            }
            if !model.loaded {
                Text(model.t("正在读取设备组配置…", "Loading group configuration…"))
                    .font(.system(size: 13)).foregroundStyle(SplitV3Color.text2).padding(.top, 18)
            } else if model.revoked { unavailableGroup.padding(.top, 18) }
            else if model.enrolled { groupHeader; requestCard; memberList }
            else if model.legacy { existingGroup.padding(.top, 18) }
            else if !model.pendingCode.isEmpty { pendingJoin.padding(.top, 18) }
            else if creating || model.creationPending { creation.padding(.top, 18) }
            else { enrollment.padding(.top, 18) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var relaySummary: some View {
        let enabled = isFixture || SyncRelaySettings.enabled
        let url = isFixture ? "wss://relay.example.com" : SyncRelaySettings.url
        return HStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 15))
                .foregroundStyle(RelayTint.link).frame(width: 30, height: 30)
                .background(RelayTint.link.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.isEmpty ? model.t("未设置中继地址","No relay URL") : url).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Circle().fill(enabled ? Color(red: 0.19, green: 0.82, blue: 0.35) : SplitV3Color.text3).frame(width: 6, height: 6)
                    Text([enabled ? model.t("公网中继已启用","Internet relay on") : model.t("公网中继未启用","Internet relay off"),
                          model.device.isEmpty ? nil : model.t("本机 \(model.device)","This Mac \(model.device)"),
                          model.t("端到端加密","End-to-end encrypted")].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1).truncationMode(.middle)
                }.font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
            }
            Spacer(minLength: 0)
            Button(model.t("中继设置","Relay settings")) {
                if !embedded { dismiss() }
                if let openSettings { openSettings() } else { MainWindow.shared.showDevices(page: .relaySettings) }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(SplitV3Color.text2)
                .padding(.horizontal, 9).frame(height: 24).contentShape(Rectangle())
        }.padding(.horizontal, 14).padding(.vertical, 12).devicesCard(radius: 12)
    }

    private var onlineCount: Int { model.members.filter { model.online.contains($0["device"] as? String ?? "") }.count }

    private var groupHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2").font(.system(size: 20)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [Color(red: 0.38, green: 0.65, blue: 0.98), Color(red: 0.04, green: 0.42, blue: 1)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.groupName.isEmpty ? model.group : model.groupName).font(.system(size: 19, weight: .bold)).lineLimit(1)
                Text([model.t("\(model.members.count) 台设备","\(model.members.count) devices"),
                      model.manager ? model.t("你是管理员","You are a manager") : model.t("你是成员","You are a member"),
                      model.onlineKnown ? model.t("\(onlineCount) 台在线","\(onlineCount) online") : model.t("状态未刷新","Status not refreshed")].joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3)
            }
            Spacer(minLength: 0)
            RelayTag(text: model.invitation == nil ? model.t("邀请未打开","No open invitation")
                     : (model.invitation?["mode"] as? String == "auto" ? model.t("扫码后自动加入","Auto join") : model.t("手动批准","Manual approval")))
        }.padding(.top, 18).padding(.bottom, 14)
    }

    @ViewBuilder private var requestCard: some View {
        if !model.revoked, let req = model.request, let parsed = try? RelayGroups.unpack(req), let member = parsed["member"] as? [String:Any] {
            let code = ((try? SyncRelayGroups.code(req)) ?? "").replacingOccurrences(of: " ", with: "")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    DevicesAvatar(peerId: "request", symbol: "laptopcomputer", size: 36, radius: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(model.t("申请设备：","Requesting device: "))\(member["name"] as? String ?? "")").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(model.t("核对新设备上的配对码","Compare the code on the new device")).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text2)
                    }
                    Spacer(minLength: 0)
                    RelayCodeView(code: code)
                }
                HStack {
                    Toggle(model.t("允许此设备邀请和移除组成员","Allow this device to invite and remove members"), isOn: $grantManager)
                        .toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2)
                    Spacer(minLength: 8)
                    Button(model.t("配对码一致，批准加入","Codes match — approve")) { model.perform { try await model.approve(manager:grantManager);grantManager = false } }
                        .buttonStyle(DevicesSmallButtonStyle(primary: true))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(RelayTint.warn.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RelayTint.warn.opacity(0.3), lineWidth: 0.5))
            .padding(.bottom, 14)
        }
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("成员","Members")).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4).padding(.top, 4)
            VStack(spacing: 0) {
                let ids = model.members.compactMap { $0["device"] as? String }
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { SplitV3Hairline() }
                    if let m = model.members.first(where: {$0["device"] as? String == id}) { memberRow(id: id, member: m) }
                }
            }.devicesCard()
            if !model.manager {
                Text(model.t("只有管理员可以添加或移除设备。","Only managers can add or remove devices."))
                    .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).padding(.horizontal, 4)
            }
        }
    }

    private func memberRow(id: String, member m: [String:Any]) -> some View {
        let isManager = m["manager"] as? Bool == true
        let status = !model.onlineKnown ? model.t("状态未刷新","Status not refreshed") : (model.online.contains(id) ? model.t("在线","Online") : model.t("离线","Offline"))
        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: [Color(red: 0.36, green: 0.61, blue: 1), Color(red: 0.04, green: 0.42, blue: 1)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(m["name"] as? String ?? id)\(id == model.device ? model.t("（本机）"," (this device)") : "")").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(id) · \(status)").font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            RelayTag(text: isManager ? model.t("管理员","Manager") : model.t("成员","Member"), accent: isManager)
            if model.manager || id == model.device {
                Menu {
                    Button { renaming = GroupRemoval(id:id,name:m["name"] as? String ?? id) } label: { Label(model.t("修改设备名称","Rename device"), systemImage: "pencil") }
                    if model.manager && id != model.device {
                        Divider()
                        Button(role: .destructive) { removing = GroupRemoval(id:id,name:m["name"] as? String ?? id) } label: { Label(model.t("移除设备","Remove device"), systemImage: "person.badge.minus") }
                    }
                } label: { Image(systemName:"ellipsis").font(.system(size: 13)).foregroundStyle(SplitV3Color.text2).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(model.t("设备操作","Device actions"))
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var pendingJoin: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(RelayTint.warn)
            if !model.pendingAutomatic {
                Text(model.t("配对码","Pairing code")).font(.system(size: 15, weight: .semibold))
                RelayCodeView(code: model.pendingCode.replacingOccurrences(of: " ", with: ""))
                Text(model.t("在邀请设备上核对配对码并批准，批准后将自动加入。","Compare the code and approve on the inviting device. Joining will complete automatically."))
                    .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2).multilineTextAlignment(.center)
            } else {
                Text(model.t("正在自动加入…","Joining automatically…")).font(.system(size: 15, weight: .semibold))
            }
            HStack(spacing: 8) {
                Text(model.pendingAutomatic ? model.t("自动加入","Automatic joining") : model.t("批准后自动加入","Joins automatically after approval"))
                    .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                Button(model.t("放弃本次申请","Discard request")) { model.perform { try model.discard() } }.buttonStyle(SplitV3ButtonStyle())
            }.padding(.top, 6)
        }.padding(20).frame(maxWidth: .infinity).devicesCard(radius: 12)
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.enrolled && !model.revoked {
                if let inv = model.invitation { invitation(inv) }
                else if model.manager { addDeviceCard }
                if model.manager {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.t("扫码后自动加入","Join automatically after scanning")).font(.system(size: 13, weight: .medium))
                            Text(model.invitation != nil ? model.t("取消邀请后可更改。","Cancel the invitation to change this.")
                                 : model.t("关闭后需核对配对码并手动批准。","Turn off to compare pairing codes and approve manually."))
                                .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                        }
                        Spacer(minLength: 0)
                        DevicesSwitch(isOn: $model.automaticJoin)
                            .disabled(model.invitation != nil).opacity(model.invitation != nil ? 0.45 : 1)
                    }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44).devicesCard()
                }
                Spacer(minLength: 0)
                Text(model.t("退出仅影响本机；解散会撤销整个组的公网访问权限。","Leaving affects this device. Disbanding revokes access for the entire group."))
                    .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(model.t("退出当前组","Leave group")) { exiting=GroupExit(disband:false) }.buttonStyle(RelayWideButtonStyle())
                    if model.manager { Button(model.t("解散设备组","Disband group")) { exiting=GroupExit(disband:true) }.buttonStyle(RelayWideButtonStyle(kind: .danger)) }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode").font(.system(size: 30, weight: .light)).foregroundStyle(SplitV3Color.text3)
                    Text(model.t("邀请与申请","Invitations and requests")).font(.system(size: 14, weight: .semibold))
                    Text(model.t("加入设备组后，可在这里生成二维码邀请其他设备。","After joining a group, invite other devices with a QR code here."))
                        .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3).multilineTextAlignment(.center)
                }.padding(.horizontal, 16).padding(.vertical, 18).frame(maxWidth: .infinity).devicesCard(radius: 12)
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 20).padding(.vertical, 18)
    }

    private var addDeviceCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode").font(.system(size: 30, weight: .light)).foregroundStyle(SplitV3Color.text3)
            Text(model.t("添加设备","Add device")).font(.system(size: 14, weight: .semibold))
            Text(model.t("生成二维码，手机扫码或电脑粘贴邀请链接加入。","Generate a QR code; phones scan it and computers paste the invitation link."))
                .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button { model.perform { try await model.createInvitation() } } label: { Label(model.t("添加设备","Add device"), systemImage: "plus") }
                .buttonStyle(SplitV3ButtonStyle(kind: .primary))
        }.padding(.horizontal, 16).padding(.vertical, 18).frame(maxWidth: .infinity).devicesCard(radius: 12)
    }

    private func invitation(_ inv: [String:Any]) -> some View {
        let code = try? SyncRelayGroups.encode(inv)
        return VStack(spacing: 0) {
            Text(model.t("邀请设备加入","Invite a device")).font(.system(size: 14, weight: .semibold))
            Text(model.t("让新设备扫码，邀请 10 分钟内有效。","Scan on the new device. Invitation expires in 10 minutes."))
                .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).padding(.top, 4)
            if let code, let image = qr(code) {
                Image(nsImage:image).interpolation(.none).resizable().frame(width:148,height:148).padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SplitV3Color.line, lineWidth: 0.5))
                    .padding(.top, 12)
                    .accessibilityLabel(model.t("设备邀请二维码","Device invitation QR code"))
            }
            HStack(spacing: 8) {
                Text(code ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(SplitV3Color.text2)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? model.t("已复制","Copied") : model.t("复制邀请链接","Copy invitation link")) {
                    guard let code else { return }
                    NSPasteboard.general.clearContents();NSPasteboard.general.setString(code,forType:.string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }.buttonStyle(DevicesSmallButtonStyle())
            }.padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
                .background(SplitV3Color.fill, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 12)
            HStack(spacing: 6) {
                Text(inv["mode"] as? String == "auto" ? model.t("扫码后自动加入（普通成员）","Joins automatically as a member") : model.t("加入申请会自动显示","Join requests appear automatically"))
                    .foregroundStyle(SplitV3Color.text3)
                Text("·").foregroundStyle(SplitV3Color.text3)
                Button(model.t("取消邀请","Cancel invitation")) { model.perform { try await model.cancelInvitation() } }
                    .buttonStyle(.plain).foregroundStyle(SplitV3Color.danger)
            }.font(.system(size: 11.5)).padding(.top, 10)
        }.padding(16).frame(maxWidth: .infinity).devicesCard(radius: 12)
    }

    // MARK: Other states

    private var unavailableGroup: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(model.t("设备组不可用","Group unavailable"),systemImage:"exclamationmark.circle").font(.system(size: 15, weight: .semibold))
            Text(model.t("组可能已解散，或本机已被移除。旧名单不再代表当前成员，也不能用于添加设备。","The group may have been disbanded or this device removed. The saved roster is no longer current."))
                .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2)
            Button(model.t("返回创建或加入","Return to create or join")) { exiting=GroupExit(disband:false) }.buttonStyle(SplitV3ButtonStyle(kind: .primary))
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).devicesCard(radius: 12)
    }
    private var existingGroup: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(model.t("已接入设备组","Already enrolled"),systemImage:"checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
            Text(model.group).font(.system(size: 15)).textSelection(.enabled)
            Text("\(model.t("本机设备 ID","This device")): \(model.device)").font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).textSelection(.enabled)
            SplitV3Hairline()
            Label(model.t("组管理待启用","Group management pending"),systemImage:"info.circle").font(.system(size: 13, weight: .semibold))
            Text(model.t("原有设备组和同步配置已保留。新版添加、移除设备功能需要服务端升级，并为当前组启用管理权限；无需重新加入设备组。","Your existing group and sync configuration are preserved. Adding and removing devices requires the server update and management activation for this group. You do not need to join again."))
                .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2)
            if !model.trustedDevices.isEmpty {
                Text(model.t("本机已保存的可信设备","Trusted devices saved on this Mac")).font(.system(size: 13, weight: .semibold))
                ForEach(model.trustedDevices,id:\.self) { id in Text(id).font(.system(size: 11.5)).textSelection(.enabled) }
                Text(model.t("这是本机保存的信任列表，并非服务器完整成员列表。","This is the locally saved trust list, not the complete server membership list.")).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
            }
            DisclosureGroup(model.t("升级组管理配置","Upgrade group management"),isExpanded:$showUpgrade) { enrollment }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).devicesCard(radius: 12)
    }
    private var creation: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.t("创建你的设备组","Create your device group")).font(.system(size: 15, weight: .semibold))
            Text(model.t("创建后，你就是管理员，可以邀请手机和电脑加入。","You become the manager and can invite phones and computers.")).font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2)
            VStack(alignment:.leading,spacing:6) {
                Text(model.t("设备组名称","Group name")).font(.system(size: 12)).foregroundStyle(SplitV3Color.text2)
                if model.creationPending { Text(model.creationGroupName.isEmpty ? groupName : model.creationGroupName).textSelection(.enabled) } else { TextField(model.t("例如：我的设备","For example: My devices"),text:$groupName) }
            }
            VStack(alignment:.leading,spacing:6) {
                Text(model.t("本机名称","Device name")).font(.system(size: 12)).foregroundStyle(SplitV3Color.text2)
                TextField(model.t("本机名称","Device name"),text:$name).disabled(model.creationPending)
            }
            HStack {
                Spacer()
                Button { model.perform { try await model.createGroup(title:groupName,name:name) } } label: {
                    Label(model.creationPending ? model.t("继续创建","Continue creating") : model.t("创建设备组","Create group"),systemImage:"plus.circle")
                }.buttonStyle(SplitV3ButtonStyle(kind: .primary))
            }
            if model.creationPending { Text(model.t("创建进度已保存，重试不会重复建组。","Progress saved. Retrying will not create a duplicate group.")).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3) }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).devicesCard(radius: 12)
    }
    private var enrollment: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.legacy ? model.t("为当前组启用管理","Enable management for this group") : model.t("加入已有设备组","Join an existing group")).font(.system(size: 15, weight: .semibold))
            Text(model.legacy ? model.t("服务端升级后，导入当前组的初始化邀请或管理设备发出的升级邀请。现有身份和密钥会保留。","After the server update, import initialization or upgrade approval for your current group. Your identity and keys are preserved.") : model.t("在另一台设备上点击「添加设备」，然后粘贴邀请链接或读取二维码图片。","Tap Add device on another device, then paste its invitation or read a QR image."))
                .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment:.leading,spacing:6) { Text(model.t("本机名称","Device name")).font(.system(size: 12)).foregroundStyle(SplitV3Color.text2);TextField(model.t("本机名称","Device name"),text:$name) }
            TextField(model.t("邀请链接或初始化邀请","Invitation link or initialization invitation"),text:$text,axis:.vertical).lineLimit(3...5)
                .font(.system(size: 12, design: .monospaced))
            HStack(spacing:8) {
                Button { readQR() } label: { Label(model.t("从二维码图片读取","Read QR image"), systemImage: "photo") }.buttonStyle(SplitV3ButtonStyle())
                Spacer()
                Button(model.legacy ? model.t("升级当前组配置","Upgrade current group") : model.t("申请加入","Request to join")) { model.perform { try await model.join(text:text,name:name) } }.buttonStyle(SplitV3ButtonStyle(kind: .primary))
            }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).devicesCard(radius: 12)
    }
    private func qr(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name:"CIQRCodeGenerator") else { return nil };filter.setValue(Data(text.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output,from:output.extent) else { return nil };return NSImage(cgImage:image,size:NSSize(width:output.extent.width,height:output.extent.height))
    }
    private func readQR() {
        let panel = NSOpenPanel();panel.canChooseDirectories = false;panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,let url = panel.url else { return }
        model.perform {
            let value = try await Task.detached { () -> String in
                let request = VNDetectBarcodesRequest();request.symbologies = [.qr];try VNImageRequestHandler(url:url).perform([request])
                guard let code = request.results?.compactMap(\.payloadStringValue).first(where: {$0.hasPrefix("common-relay://")}) else { throw RelayError.invalid("invitation QR") };return code
            }.value
            text = value
            try await model.join(text:value,name:name)
        }
    }
}

private struct RelayDeviceNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var invalid = false
    let zh: Bool
    let save: (String) -> Void
    init(name: String, zh: Bool, save: @escaping (String) -> Void) { _name = State(initialValue:name);self.zh=zh;self.save=save }
    var body: some View {
        VStack(alignment:.leading,spacing:AppSpacing.lg) {
            Text(zh ? "修改设备名称" : "Rename device").font(.headline)
            TextField(zh ? "设备名称" : "Device name",text:$name).textFieldStyle(.roundedBorder)
            if invalid { Text(zh ? "请输入简短的设备名称" : "Enter a short device name").foregroundStyle(.red) }
            HStack(spacing:AppSpacing.sm) {
                Spacer();Button(zh ? "取消" : "Cancel") { dismiss() }
                Button(zh ? "保存名称" : "Save name") {
                    let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard (1...128).contains(value.utf8.count) else { invalid=true;return }
                    save(value);dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(AppSpacing.xl).frame(width:400)
    }
}

private enum RelayTint {
    static let link = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 60/255, green: 207/255, blue: 188/255, alpha: 1) : NSColor(srgbRed: 14/255, green: 159/255, blue: 142/255, alpha: 1) })
    static let warn = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 251/255, green: 191/255, blue: 36/255, alpha: 1) : NSColor(srgbRed: 217/255, green: 119/255, blue: 6/255, alpha: 1) })
}

/// `.tag.gray` / `.tag.text`.
private struct RelayTag: View {
    let text: String
    var accent = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            .foregroundStyle(accent ? AppColor.accent : SplitV3Color.text2)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(accent ? AppColor.accent.opacity(0.12) : SplitV3Color.fill))
    }
}

/// Pairing code shown as 3 groups of 4 character tiles (`.code`).
private struct RelayCodeView: View {
    let code: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, ch in
                if index > 0 && index % 4 == 0 { Color.clear.frame(width: 5, height: 1) }
                Text(String(ch)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .frame(width: 18, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(SplitV3Color.card))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SplitV3Color.line, lineWidth: 0.5))
            }
        }.textSelection(.enabled).accessibilityLabel(code)
    }
}

/// Full-width 28pt buttons in the danger row / confirmation sheets.
private struct RelayWideButtonStyle: ButtonStyle {
    enum Kind { case normal, danger, dangerFill }
    var kind: Kind = .normal
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(kind == .dangerFill ? Color.white : (kind == .danger ? SplitV3Color.danger : Color.primary))
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(kind == .dangerFill ? SplitV3Color.danger : SplitV3Color.control)
                .shadow(color: .black.opacity(kind == .dangerFill ? 0 : 0.06), radius: 0.75, y: 0.5))
            .overlay { if kind != .dangerFill { RoundedRectangle(cornerRadius: 7).strokeBorder(SplitV3Color.controlLine, lineWidth: 0.5) } }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
