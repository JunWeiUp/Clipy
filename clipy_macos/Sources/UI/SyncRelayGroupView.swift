import SwiftUI
import AppKit
import CoreImage
import Vision
import CommonRelay

struct SyncRelayGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SyncRelayGroups()
    @State private var text = ""
    @State private var groupName = ""
    @State private var creating = true
    @State private var name = Host.current().localizedName ?? "Mac"
    @State private var grantManager = false
    @State private var showUpgrade = false
    @State private var removing: GroupRemoval?
    @State private var exiting: GroupExit?
    @State private var renaming: GroupRemoval?
    private struct GroupExit: Identifiable { let disband: Bool;var id: Bool { disband } }
    private struct GroupRemoval: Identifiable { let id: String;let name: String }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:AppSpacing.sm) { Text(model.t("公网设备组","Relay device group")).font(.title2);Spacer();Button(model.t("刷新","Refresh")) { model.perform { try await model.refresh() } };Button(model.t("完成","Done")) { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment:.leading,spacing:AppSpacing.xl) {
                    if model.busy { ProgressView().controlSize(.small) }
                    if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled) }
                    if !model.loaded { Text(model.t("正在读取设备组配置…","Loading group configuration…")) }
                    else if model.revoked { unavailableGroup }
                    else if model.enrolled { memberList;exitActions }
                    else if model.legacy { existingGroup }
                    else if model.pendingCode.isEmpty {
                        if !model.creationPending { Picker(model.t("接入方式","Get started"),selection:$creating) { Text(model.t("创建新组","Create group")).tag(true);Text(model.t("加入已有组","Join group")).tag(false) }.pickerStyle(.segmented) }
                        if creating || model.creationPending { creation } else { enrollment }
                    }
                    if !model.revoked && !model.pendingCode.isEmpty {
                        if !model.pendingAutomatic { Text("\(model.t("配对码","Pairing code")): \(model.pendingCode)").font(.title2).monospaced().textSelection(.enabled)
                        Text(model.t("在邀请设备上核对配对码并批准，批准后将自动加入。","Compare the code and approve on the inviting device. Joining will complete automatically.")).foregroundStyle(.secondary)
                        } else { Text(model.t("正在自动加入…","Joining automatically…")) }
                        HStack(spacing:AppSpacing.sm) { Text(model.pendingAutomatic ? model.t("自动加入","Automatic joining") : model.t("批准后自动加入","Joins automatically after approval"));Button(model.t("放弃本次申请","Discard request")) { model.perform { try model.discard() } } }
                    }
                    if !model.revoked, let req = model.request, let parsed = try? RelayGroups.unpack(req), let member = parsed["member"] as? [String:Any] {
                        Text("\(model.t("申请设备","Requesting device")): \(member["name"] as? String ?? "")")
                        Text("\(model.t("核对新设备上的配对码","Compare the code on the new device")): \((try? SyncRelayGroups.code(req)) ?? "")").monospaced().textSelection(.enabled)
                        Toggle(model.t("允许此设备邀请和移除组成员","Allow this device to invite and remove members"),isOn:$grantManager)
                        Button(model.t("配对码一致，批准加入","Codes match — approve")) { model.perform { try await model.approve(manager:grantManager);grantManager = false } }.buttonStyle(.borderedProminent)
                    }
                    if !model.revoked, let inv = model.invitation { invitation(inv) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(AppSpacing.xl).frame(minWidth:560,idealWidth:640,minHeight:480,idealHeight:720)
        .background(Color(nsColor:.windowBackgroundColor))
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .disabled(model.busy)
        .task { model.perform { try await model.refresh() } }
        .onDisappear { model.close() }
        .sheet(item:$renaming) { item in
            RelayDeviceNameEditor(name:item.name,zh:model.t("中","en")=="中") { value in model.perform { try await model.rename(item.id,name:value) } }
        }
        .sheet(item:$exiting) { action in
            VStack(alignment:.leading,spacing:AppSpacing.lg) {
                Text(model.revoked ? model.t("清除失效的组配置？","Clear unavailable group configuration?") : action.disband ? model.t("解散整个设备组？","Disband this group?") : model.t("退出当前设备组？","Leave this group?")).font(.headline)
                Text(model.revoked ? model.t("只清除本机已失效的公网组配置，保留历史记录和局域网设置。然后可创建或加入其他设备组。","Clear only this device’s unavailable relay configuration. Local history and LAN settings are preserved. You can then create or join another group.") : action.disband ? model.t("所有设备将失去本组公网访问权限，未使用的邀请会失效。此操作不可撤销。本机历史记录和局域网配置会保留。","All devices lose relay access and invitations expire. This cannot be undone. Local history and LAN settings are preserved.") : model.t("仅本机离开，其他设备继续使用。若组内只剩本机，空组会同时关闭。本机历史记录和局域网配置会保留。","Only this device leaves; other devices continue using the group. Empty groups close. Local history and LAN settings are preserved."))
                HStack(spacing:AppSpacing.sm) {
                    Spacer();Button(model.t("取消","Cancel")) { exiting=nil }
                    Button(model.revoked ? model.t("清除并继续","Clear and continue") : action.disband ? model.t("确认解散","Disband group") : model.t("确认退出","Leave group"),role:.destructive) { exiting=nil;model.perform { try await model.exitGroup(disband:action.disband);creating=true;groupName="";text="" } }
                }
            }.padding(AppSpacing.xl).frame(width:440)
        }
        .sheet(item:$removing) { item in
            VStack(alignment:.leading,spacing:16) {
                Text(model.t("移除设备？","Remove device?")).font(.headline)
                Text(model.t("移除 \(item.name) 后，它将无法访问本组公网中继。局域网连接与已收到的内容不受影响。","\(item.name) will lose access to this relay group. LAN connections and previously received content are unaffected."))
                HStack { Spacer();Button(model.t("取消","Cancel")) { removing = nil };Button(model.t("移除","Remove"),role:.destructive) { removing = nil;model.perform { try await model.remove(item.id) } } }
            }.padding(AppSpacing.xl).frame(width:400)
        }
    }
    private var unavailableGroup: some View {
        VStack(alignment:.leading,spacing:AppSpacing.lg) {
            Label(model.t("设备组不可用","Group unavailable"),systemImage:"exclamationmark.circle").font(.headline)
            Text(model.t("组可能已解散，或本机已被移除。旧名单不再代表当前成员，也不能用于添加设备。","The group may have been disbanded or this device removed. The saved roster is no longer current.")).foregroundStyle(.secondary)
            Button(model.t("返回创建或加入","Return to create or join")) { exiting=GroupExit(disband:false) }.buttonStyle(.borderedProminent)
        }.padding(AppSpacing.lg).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
    private var exitActions: some View {
        VStack(alignment:.leading,spacing:AppSpacing.md) {
            Text(model.t("离开设备组","Leave this group")).font(.headline)
            Text(model.t("退出仅影响本机；解散会撤销整个组的公网访问权限。","Leaving affects this device. Disbanding revokes access for the entire group.")).foregroundStyle(.secondary)
            HStack(spacing:AppSpacing.sm) {
                Button(model.t("退出当前组","Leave group")) { exiting=GroupExit(disband:false) }
                if model.manager && !model.revoked { Button(model.t("解散设备组","Disband group"),role:.destructive) { exiting=GroupExit(disband:true) } }
            }
        }.padding(AppSpacing.lg).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
    private var memberList: some View {
        VStack(alignment:.leading,spacing:AppSpacing.lg) {
            Text("\(model.groupName.isEmpty ? model.group : model.groupName) · \(model.members.count) \(model.t("台设备","devices"))").font(.headline)
            ForEach(model.members.compactMap { $0["device"] as? String },id:\.self) { id in
                if let m = model.members.first(where: {$0["device"] as? String == id}) {
                    HStack {
                        Image(systemName:"desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment:.leading) { Text("\(m["name"] as? String ?? id)\(id == model.device ? model.t("（本机）"," (this device)") : "")");Text("\(id) · \(m["manager"] as? Bool == true ? model.t("管理员","Manager") : model.t("成员","Member")) · \(!model.onlineKnown ? model.t("状态未刷新","Status not refreshed") : (model.online.contains(id) ? model.t("在线","Online") : model.t("离线","Offline")))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.manager || id == model.device {
                            Menu {
                                Button(model.t("修改设备名称","Rename device")) { renaming = GroupRemoval(id:id,name:m["name"] as? String ?? id) }
                                if model.manager && id != model.device { Button(model.t("移除设备","Remove device"),role:.destructive) { removing = GroupRemoval(id:id,name:m["name"] as? String ?? id) } }
                            } label: { Image(systemName:"ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help(model.t("设备操作","Device actions"))
                        }
                    }.padding(10).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
                }
            }
            if model.manager && model.invitation == nil { Toggle(model.t("扫码后自动加入","Join automatically after scanning"),isOn:$model.automaticJoin);Text(model.t("关闭后需核对配对码并手动批准。","Turn off to compare pairing codes and approve manually.")).font(.caption).foregroundStyle(.secondary);Button { model.perform { try await model.createInvitation() } } label: { Label(model.t("添加设备","Add device"),systemImage:"plus") }.buttonStyle(.borderedProminent) }
            if !model.manager { Text(model.t("只有管理员可以添加或移除设备。","Only managers can add or remove devices.")).foregroundStyle(.secondary) }
        }.padding(AppSpacing.lg).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
    private var existingGroup: some View {
        VStack(alignment:.leading,spacing:14) {
            Label(model.t("已接入设备组","Already enrolled"),systemImage:"checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            Text(model.group).font(.title3).textSelection(.enabled)
            Text("\(model.t("本机设备 ID","This device")): \(model.device)").font(.caption).textSelection(.enabled)
            Divider()
            Label(model.t("组管理待启用","Group management pending"),systemImage:"info.circle").font(.headline)
            Text(model.t("原有设备组和同步配置已保留。新版添加、移除设备功能需要服务端升级，并为当前组启用管理权限；无需重新加入设备组。","Your existing group and sync configuration are preserved. Adding and removing devices requires the server update and management activation for this group. You do not need to join again."))
            if !model.trustedDevices.isEmpty {
                Text(model.t("本机已保存的可信设备","Trusted devices saved on this Mac")).font(.headline)
                ForEach(model.trustedDevices,id:\.self) { id in Text(id).font(.caption).textSelection(.enabled) }
                Text(model.t("这是本机保存的信任列表，并非服务器完整成员列表。","This is the locally saved trust list, not the complete server membership list.")).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(model.t("升级组管理配置","Upgrade group management"),isExpanded:$showUpgrade) { enrollment }
        }
    }
    private var creation: some View {
        VStack(alignment:.leading,spacing:AppSpacing.lg) {
            Text(model.t("创建你的设备组","Create your device group")).font(.title3.weight(.semibold))
            Text(model.t("创建后，你就是管理员，可以邀请手机和电脑加入。","You become the manager and can invite phones and computers.")).foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:8) {
                Text(model.t("设备组名称","Group name")).font(.callout)
                if model.creationPending { Text(model.creationGroupName.isEmpty ? groupName : model.creationGroupName).textSelection(.enabled) } else { TextField(model.t("例如：我的设备","For example: My devices"),text:$groupName) }
            }
            VStack(alignment:.leading,spacing:8) {
                Text(model.t("本机名称","Device name")).font(.callout)
                TextField(model.t("本机名称","Device name"),text:$name).disabled(model.creationPending)
            }
            Button { model.perform { try await model.createGroup(title:groupName,name:name) } } label: {
                Label(model.creationPending ? model.t("继续创建","Continue creating") : model.t("创建设备组","Create group"),systemImage:"plus.circle")
            }.buttonStyle(.borderedProminent)
            if model.creationPending { Text(model.t("创建进度已保存，重试不会重复建组。","Progress saved. Retrying will not create a duplicate group.")).font(.callout).foregroundStyle(.secondary) }
        }.padding(AppSpacing.lg).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
    private var enrollment: some View {
        VStack(alignment:.leading,spacing:AppSpacing.lg) {
            Text(model.legacy ? model.t("为当前组启用管理","Enable management for this group") : model.t("加入已有设备组","Join an existing group")).font(.headline)
            Text(model.legacy ? model.t("服务端升级后，导入当前组的初始化邀请或管理设备发出的升级邀请。现有身份和密钥会保留。","After the server update, import initialization or upgrade approval for your current group. Your identity and keys are preserved.") : model.t("在另一台设备上点击「添加设备」，然后粘贴邀请链接或读取二维码图片。","Tap Add device on another device, then paste its invitation or read a QR image.")).font(.callout)
            VStack(alignment:.leading,spacing:8) { Text(model.t("本机名称","Device name")).font(.callout).foregroundStyle(.secondary);TextField(model.t("本机名称","Device name"),text:$name) }
            TextField(model.t("邀请链接或初始化邀请","Invitation link or initialization invitation"),text:$text,axis:.vertical).lineLimit(3...5)
            HStack(spacing:AppSpacing.sm) { Button(model.t("从二维码图片读取","Read QR image")) { readQR() };Button(model.legacy ? model.t("升级当前组配置","Upgrade current group") : model.t("申请加入","Request to join")) { model.perform { try await model.join(text:text,name:name) } }.buttonStyle(.borderedProminent) }
        }.padding(AppSpacing.lg).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
    private func invitation(_ inv: [String:Any]) -> some View {
        VStack(alignment:.leading,spacing:AppSpacing.lg) {
            Text(model.t("让新设备扫码，邀请 10 分钟内有效。","Scan on the new device. Invitation expires in 10 minutes."))
            if let code = try? SyncRelayGroups.encode(inv), let image = qr(code) { Image(nsImage:image).interpolation(.none).resizable().frame(width:260,height:260).padding(16).background(.white).accessibilityLabel(model.t("设备邀请二维码","Device invitation QR code")) }
            VStack(alignment:.leading,spacing:AppSpacing.sm) { Button(model.t("复制邀请链接","Copy invitation link")) { if let code = try? SyncRelayGroups.encode(inv) { NSPasteboard.general.clearContents();NSPasteboard.general.setString(code,forType:.string) } };Text(inv["mode"] as? String == "auto" ? model.t("扫码后自动加入（普通成员）","Joins automatically as a member") : model.t("加入申请会自动显示","Join requests appear automatically"));Button(model.t("取消邀请","Cancel invitation")) { model.perform { try await model.cancelInvitation() } } }
        }.padding(AppSpacing.lg).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
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
