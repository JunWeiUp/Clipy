import Foundation
import Security
import CommonRelay

@MainActor
final class SyncRelayGroups: ObservableObject {
    @Published var members: [[String:Any]] = []
    @Published var online = Set<String>()
    @Published var invitation: [String:Any]?
    @Published var request: [String:Any]?
    @Published var pendingCode = ""
    @Published var automaticJoin = true
    @Published var pendingAutomatic = false
    @Published var message = ""
    @Published var busy = false
    @Published var revoked = false
    @Published var accessDenied = false
    @Published var hasAccessPassword = false
    @Published var device = ""
    @Published var group = ""
    @Published var groupName = ""
    @Published var creationPending = false
    @Published var creationGroupName = ""
    @Published var enrolled = false
    @Published var loaded = false
    @Published var legacy = false
    @Published var trustedDevices: [String] = []
    @Published var onlineKnown = false
    private var task: Task<Void,Never>?
    private var watchTask: Task<Void,Never>?
    private var closed = false
    private var watchStopped = false
    var manager: Bool { members.contains { $0["device"] as? String == device && $0["manager"] as? Bool == true } }
    private var zh: Bool { PreferencesManager.shared.appLanguage == .zh }
    func t(_ cn: String,_ en: String) -> String { zh ? cn : en }
    private static func query(_ account: String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.clipy.relay-groups",kSecAttrAccount as String:account] }
    private static func read(_ account: String) throws -> [String:Any]? {
        var q = query(account);q[kSecReturnData as String] = true;q[kSecMatchLimit as String] = kSecMatchLimitOne;var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&value);if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = value as? Data, let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw RelayError.invalid("Keychain") };return object
    }
    private static func write(_ account: String,_ value: [String:Any]?) throws {
        let q = query(account);guard let value else { let s = SecItemDelete(q as CFDictionary);guard s == errSecSuccess || s == errSecItemNotFound else { throw RelayError.invalid("Keychain") };return }
        let data = try JSONSerialization.data(withJSONObject:SyncRelayAccessPolicy.applying(nil,to:value));var status = SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound { var add = q;add[kSecValueData as String] = data;add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;status = SecItemAdd(add as CFDictionary,nil) }
        guard status == errSecSuccess else { throw RelayError.invalid("Keychain") }
    }
    nonisolated static func isAuthenticationFailure(_ error: Error) -> Bool {
        if error is SyncRelayAccessPolicy.Failure { return true }
        if case RelayError.invalid(let message) = error { return SyncRelayAccessPolicy.isAuthenticationMessage(message) }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorUserAuthenticationRequired
    }
    func handleFailure(_ error: Error) {
        if case SyncRelayAccessPolicy.InvitationFailure.missingPassword = error {
            message = t("此旧邀请未携带访问密码。请让邀请设备重新生成二维码，或在中继设置保存该服务器的访问密码后重试。", "This older invitation has no access password. Ask for a new QR code, or save this server’s access password in Relay settings and retry.")
        } else if case SyncRelayAccessPolicy.InvitationFailure.differentRelay = error {
            message = t("邀请属于其他服务器。请先在中继设置确认对应地址，再重新读取邀请；密码尚未导入。", "This invitation belongs to another server. Confirm its URL in Relay settings, then read the invitation again. No password was imported.")
        } else if Self.isAuthenticationFailure(error) {
            accessDenied = true; members = []; online = []; onlineKnown = false; request = nil; invitation = nil
            SyncRelayConnectionState.shared.update(.authenticationRequired)
            message = t("中继认证未通过。请检查访问密码；设备 Key 失效、被移除或组已解散也可能导致拒绝。身份与局域网配置已保留。", "Relay authentication failed. Check the access password; an invalid device key, removal or a closed group may also cause this. Identity and LAN settings are preserved.")
        } else if case RelayError.invalid(let reason) = error,
                  reason == "invitation relay differs from settings" || reason == "pending relay differs from settings" {
            message = t("此邀请或未完成申请属于其他中继。请先在中继设置确认对应地址，并单独保存该服务器的访问密码。", "This invitation or pending request belongs to another relay. Confirm its URL in Relay settings and save that server’s access password separately.")
        } else {
            message = t("操作失败，请检查网络、邀请有效期或管理权限。", "Could not complete. Check connection, invitation expiry and permissions.")
        }
    }
    /// Rehydrate every retry from the current scoped credential, never a stale pending draft.
    private static func authenticated(_ config: [String:Any]) throws -> RelayGroups {
        let configuredURL = SyncRelaySettings.url.isEmpty ? "wss://relay.example.test/relay/v1/ws" : SyncRelaySettings.url
        guard config["url"] as? String == configuredURL else { throw RelayError.invalid("pending relay differs from settings") }
        let secret = try SyncRelaySettings.accessPassword(url: configuredURL)
        try SyncRelayAccessPolicy.validate(secret ?? "")
        return RelayGroups(config: SyncRelayAccessPolicy.applying(secret, to: config))
    }
    static func load(requirePassword: Bool = false) throws -> RelayGroups {
        let raw = SyncRelaySettings.token();var c = raw.isEmpty ? [:] : (try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] ?? [:])
        c["url"] = SyncRelaySettings.url.isEmpty ? (c["url"] ?? "wss://relay.example.test/relay/v1/ws") : SyncRelaySettings.url
        let secret = try SyncRelaySettings.accessPassword(url:c["url"] as? String ?? "")
        if requirePassword { try SyncRelayAccessPolicy.validate(secret ?? "") }
        return RelayGroups(config:SyncRelayAccessPolicy.applying(secret,to:c))
    }
    /// Serialized on MainActor; reject an older completion overwriting a newer tip.
    static func persist(_ g: RelayGroups, activate: Bool = false) throws {
        let current = try load()
        guard current.config["url"] as? String == g.config["url"] as? String,
              current.config["password"] as? String == g.config["password"] as? String else { throw RelayError.invalid("configuration changed during request") }
        if current.config["token"] == nil && !activate { throw RelayError.invalid("enrollment no longer active") }
        if current.config["token"] != nil && ["device","group","token","secret_key"].contains(where: { current.config[$0] as? String != g.config[$0] as? String }) { throw RelayError.invalid("configuration changed during request") }
        if let a = current.config["group_entry"] as? [String:Any], let b = g.config["group_entry"] as? [String:Any], current.config["device"] as? String == g.config["device"] as? String,
           (try RelayGroups.unpack(a)["revision"] as? Int ?? 0) > (try RelayGroups.unpack(b)["revision"] as? Int ?? 0) { return }
        var saved = SyncRelayAccessPolicy.applying(nil,to:g.config);saved.removeValue(forKey:"enrollment_invitation");saved.removeValue(forKey:"enrollment_name");saved.removeValue(forKey:"creation_draft")
        let raw = String(decoding:try JSONSerialization.data(withJSONObject:saved),as:UTF8.self)
        let changed = try SyncRelaySettings.save(enabled:activate || SyncRelaySettings.enabled,url:g.config["url"] as? String ?? SyncRelaySettings.url,token:raw,deviceID:g.config["device"] as? String)
        if changed { SyncManager.shared.restartRelayConfiguration() }
    }
    static func refreshedConfiguration(_ raw: String, url: String, accessPassword: String?) async throws -> String {
        guard var c = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any], c["group_entry"] != nil else { return raw }
        c["url"] = url;c = SyncRelayAccessPolicy.applying(accessPassword,to:c);let g = RelayGroups(config:c);_ = try await g.refresh();try persist(g)
        return String(decoding:try JSONSerialization.data(withJSONObject:SyncRelayAccessPolicy.applying(nil,to:g.config)),as:UTF8.self)
    }
    static func encode(_ inv: [String:Any]) throws -> String {
        let inv = SyncRelayAccessPolicy.invitationForExport(inv)
        if let link = inv["short_link"] as? String {
            let parsed = try RelayInvitationLinks.parse(link)
            let current = try load(requirePassword:true)
            guard parsed.url == current.config["url"] as? String,
                  inv["url"] as? String == parsed.url, inv["id"] as? String == parsed.id,
                  inv["group"] as? String == current.config["group"] as? String else { throw RelayError.invalid("invitation scope") }
            // Rebuild even cached pre-v0.1.5 links with the current scoped credential.
            return try RelayInvitationLinks.make(inv,key:parsed.key,password:current.config["password"] as? String)
        };let data = try JSONSerialization.data(withJSONObject:inv,options:[.sortedKeys]);return "common-relay://join#" + data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_")
    }
    static func decode(_ text: String) throws -> [String:Any] {
        guard text.utf8.count <= 8192 else { throw RelayError.invalid("invitation length") };let raw = text.trimmingCharacters(in:.whitespacesAndNewlines);var data = Data(raw.utf8)
        if raw.hasPrefix("common-relay://join#") { var code = String(raw.dropFirst("common-relay://join#".count)).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");while code.count % 4 != 0 { code += "=" };guard let decoded = Data(base64Encoded:code) else { throw RelayError.invalid("invitation") };data = decoded }
        guard let c = try JSONSerialization.jsonObject(with:data) as? [String:Any], c["version"] as? Int == 1, c["app"] as? String == "clipy", c["group"] is String, c["password"] == nil else { throw RelayError.invalid("invitation") };return c
    }
    static func code(_ request: [String:Any]) throws -> String { let h = String(RelayGroups.digest(try RelayGroups.payload(request)).prefix(12)).uppercased();return stride(from:0,to:12,by:4).map { String(Array(h)[$0..<$0+4]) }.joined(separator:" ") }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return };closed = false;busy = true;message = "";watchStopped = false
        task = Task { do { try await action() } catch is CancellationError { } catch { handleFailure(error) };busy = false;scheduleWatch() }
    }
    func close() { closed = true;watchTask?.cancel();watchTask = nil;task?.cancel();task = nil }
    private func scheduleWatch() {
        watchTask?.cancel();watchTask = nil
        guard !closed, !busy, !revoked, !accessDenied, !watchStopped, !pendingCode.isEmpty || invitation != nil else { return }
        watchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, !self.closed else { return }
            guard !self.busy else { return }
            self.busy = true
            do {
                if !self.pendingCode.isEmpty { try await self.finish() }
                else if let invitation = self.invitation {
                    if (invitation["expires"] as? Double ?? 0) <= Date().timeIntervalSince1970 {
                        self.watchStopped = true
                        self.message = self.t("邀请已过期，请重新添加设备。","Invitation expired. Add the device again.")
                    } else { try await self.checkRequest() }
                }
            } catch is CancellationError { }
            catch {
                let description = String(describing:error)
                self.watchStopped = ["401","403","404","410"].contains { description.contains($0) }
                self.handleFailure(error)
            }
            self.busy = false
            self.scheduleWatch()
        }
    }
    func refresh() async throws {
        let g = try Self.load();hasAccessPassword = g.config["password"] as? String != nil;device = g.config["device"] as? String ?? ""
        group = g.config["group"] as? String ?? ""
        let status = SyncRelayGroupState.classify(g.config)
        legacy = status == .legacy;enrolled = status == .managed;loaded = true;onlineKnown = false
        trustedDevices = (g.config["trusted_peers"] as? [String:String] ?? [:]).keys.filter { $0 != device }.sorted()
        if enrolled, !accessDenied, let entry = g.config["group_entry"] as? [String:Any] { members = try RelayGroups.unpack(entry)["members"] as? [[String:Any]] ?? [] }
        if enrolled { try SyncRelayAccessPolicy.validate(g.config["password"] as? String ?? "");let result = try await g.refresh();try Self.persist(g);let state = result["state"] as? [String:Any] ?? [:];members = state["members"] as? [[String:Any]] ?? [];group = state["group"] as? String ?? "";groupName = state["name"] as? String ?? group;online = Set(result["online"] as? [String] ?? []);onlineKnown = true;enrolled = true;revoked = false;accessDenied = false }
        if let inv = try Self.read("outgoing") { if (inv["expires"] as? Double ?? 0) > Date().timeIntervalSince1970 { invitation = inv } else { try Self.write("outgoing",nil);invitation = nil;request = nil } }
        creationPending = try Self.read("pending")?["creation_draft"] as? Bool == true
        if !enrolled && hasAccessPassword { accessDenied = false }
        if creationPending, let p = try Self.read("pending"), let entry = (p["pending_create"] ?? p["group_entry"]) as? [String:Any] { creationGroupName = try RelayGroups.unpack(entry)["name"] as? String ?? "" }
        if let p = try Self.read("pending"), let join = p["pending_join"] as? [String:Any], let request = join["request"] as? [String:Any] { pendingCode = try Self.code(request);pendingAutomatic = (join["invitation"] as? [String:Any])?["mode"] as? String == "auto" }
    }
    func createInvitation() async throws {
        let g = try Self.authenticated(Self.load().config)
        let next = try await g.invite(mode:automaticJoin ? "auto" : "manual",compact:true)
        try Task.checkCancellation()
        try Self.persist(g)
        try Self.write("outgoing",next)
        invitation = next;request = nil
    }
    func checkRequest() async throws { guard let invitation else { return };let next = try await Self.load(requirePassword:true).pending(invitation);try Task.checkCancellation();if invitation["mode"] as? String == "auto" {
            request = nil;try await refresh()
            if let next, let member = try RelayGroups.unpack(next)["member"] as? [String:Any], members.contains(where: { $0["device"] as? String == member["device"] as? String }) { try Self.write("outgoing",nil);self.invitation = nil;message = t("新设备已自动加入。","Device joined automatically.") };return
        };request = next;message = "";if request == nil { message = t("还没有设备申请加入。","No device has requested to join yet.") } }
    func approve(manager: Bool) async throws { guard let invitation,let request else { return };let g = try Self.load(requirePassword:true);try await g.approve(invitation,request:request,manager:manager);try Self.persist(g);try Self.write("outgoing",nil);self.invitation = nil;self.request = nil;try await refresh();message = t("已批准，新设备将自动加入。","Approved. The new device will join automatically.") }
    func cancelInvitation() async throws { guard let invitation else { return };try await Self.load(requirePassword:true).cancel(invitation);try Self.write("outgoing",nil);self.invitation = nil;request = nil }
    func remove(_ id: String) async throws { let g = try Self.load(requirePassword:true);try await g.remove(device:id);try Self.persist(g);try await refresh() }
    func rename(_ id: String, name: String) async throws {
        let g = try Self.load(requirePassword:true);try await g.rename(device:id,name:name);try Self.persist(g);try await refresh();message = t("设备名称已更新。","Device name updated.")
    }
    func exitGroup(disband: Bool) async throws {
        let current = try Self.load()
        var saved = try Self.read("exit")
        if let value = saved, ["device","group","token","url"].contains(where: { value[$0] as? String != current.config[$0] as? String }) { try Self.write("exit",nil);saved=nil }
        let g = try Self.authenticated(saved ?? current.config)
        if !revoked && saved != nil && g.config["exit_disband"] as? Bool != disband { throw RelayError.invalid("retry pending exit") }
        if !disband && !revoked && saved == nil && manager && members.count > 1 && members.filter({$0["manager"] as? Bool == true}).count == 1 {
            message = t("你是最后一位管理员。请让另一台管理设备加入，或选择解散设备组。","You are the last manager. Invite another manager or disband the group.");return
        }
        do {
            if !revoked { try await g.prepareExit(disband:disband);g.config["exit_disband"] = disband;try Self.write("exit",g.config);try await g.exit() }
        } catch {
            if String(describing:error).contains("409") { try Self.write("exit",g.config) }
            // An authentication failure must not silently remove local enrollment.
            throw error
        }
        if let secret = g.config["secret_key"] as? String { try Self.write("identity",["secret_key":secret]) }
        try SyncRelaySettings.clearEnrollment();SyncManager.shared.restartRelayConfiguration()
        try Self.write("pending",nil);try Self.write("outgoing",nil);try Self.write("exit",nil)
        members=[];online=[];invitation=nil;request=nil;pendingCode="";creationPending=false;enrolled=false;legacy=false;revoked=false
        try await refresh();message = disband ? t("设备组已解散。你可以创建或加入其他组。","Group disbanded. You can create or join another group.") : t("已退出当前组。你可以创建或加入其他组。","You left the group. You can create or join another group.")
    }
    func clearUnavailableEnrollment() async throws {
        let current = try Self.load()
        if let secret = current.config["secret_key"] as? String { try Self.write("identity",["secret_key":secret]) }
        try SyncRelaySettings.clearEnrollment(); SyncManager.shared.restartRelayConfiguration()
        try Self.write("pending",nil); try Self.write("outgoing",nil); try Self.write("exit",nil)
        members=[];online=[];invitation=nil;request=nil;pendingCode="";creationPending=false;enrolled=false;legacy=false;revoked=false;accessDenied=false
        try await refresh()
    }
    func createGroup(title: String, name: String) async throws {
        if !creationPending && (!(1...128).contains(title.trimmingCharacters(in:.whitespacesAndNewlines).utf8.count) || !(1...128).contains(name.trimmingCharacters(in:.whitespacesAndNewlines).utf8.count)) { message = t("请填写简短的设备组名称和本机名称。","Enter a short group name and device name.");return }
        let current = try Self.load()
        guard current.config["token"] == nil else { throw RelayError.invalid("already enrolled") }
        var c: [String:Any]
        if let saved = try Self.read("pending") {
            guard saved["creation_draft"] as? Bool == true else { throw RelayError.invalid("pending invitation") };c = saved
        } else {
            let identity = try Self.read("identity") ?? ["secret_key":RelayIdentity.generateSecretKey().relayHex]
            try Self.write("identity",identity)
            c = ["url":current.config["url"] ?? "wss://relay.example.test/relay/v1/ws","app":"clipy","device":SyncRelaySettings.deviceID,"secret_key":identity["secret_key"] ?? ""]
        }
        let g = try Self.authenticated(c)
        if g.config["group_entry"] == nil {
            try g.prepareCreate(groupName:title,deviceName:name);g.config["creation_draft"] = true;try Self.write("pending",g.config)
            creationPending = true
            try await g.create();try Self.write("pending",g.config)
        }
        try Self.persist(g,activate:true);try Self.write("pending",nil);creationPending = false
        try await refresh();message = t("设备组已创建，你是管理员。现在可以添加其他设备。","Group created. You are the manager and can now add devices.")
    }
    func join(text: String,name: String) async throws {
        let current = try Self.load();current.config["app"] = "clipy"
        let raw = text.trimmingCharacters(in:.whitespacesAndNewlines)
        try Task.checkCancellation()
        guard current.config["group_entry"] == nil else { throw RelayError.invalid("already enrolled") }
        let snapshot = current.config
        let configuredURL = snapshot["url"] as? String ?? ""
        let compact = raw.hasPrefix("common-relay://") && !raw.hasPrefix("common-relay://join#")
        let resolved: [String:Any]
        var importedPassword: String?
        if compact {
            let link = try RelayInvitationLinks.parse(raw)
            // Check scope before any HTTP request or credential write.
            let secret = try SyncRelayAccessPolicy.invitationPassword(url:link.url,configuredURL:configuredURL,
                supplied:link.password,saved:snapshot["password"] as? String)
            let resolver = RelayGroups(config:SyncRelayAccessPolicy.applying(secret,to:snapshot))
            resolved = try await resolver.resolveInvitation(raw)
            importedPassword = link.password
        } else {
            resolved = try Self.decode(raw)
            _ = try SyncRelayAccessPolicy.invitationPassword(url:resolved["url"] as? String ?? configuredURL,
                configuredURL:configuredURL,supplied:nil,saved:snapshot["password"] as? String)
        }
        try Task.checkCancellation()
        guard SyncRelayAccessPolicy.sameRequestConfiguration(snapshot,try Self.load().config) else {
            throw RelayError.invalid("configuration changed during request")
        }
        // The SDK returns the link credential in the resolved dictionary. Strip it
        // before placing the invitation in enrollment_invitation or pending_join.
        let inv = SyncRelayAccessPolicy.applying(nil,to:resolved)
        if current.config["token"] != nil && (current.config["group"] as? String != inv["group"] as? String || (inv["url"] != nil && current.config["url"] as? String != inv["url"] as? String)) { throw RelayError.invalid("existing identity scope") }
        // Require explicit settings for a different relay before making any enrollment request.
        guard (inv["url"] as? String ?? current.config["url"] as? String) == current.config["url"] as? String else { throw RelayError.invalid("invitation relay differs from settings") }
        if let importedPassword {
            try SyncRelaySettings.saveInvitationPassword(importedPassword,url:configuredURL)
            current.config["password"] = importedPassword
            hasAccessPassword = true
        }
        var c = current.config
        if let saved = try Self.read("pending"), let previous = saved["enrollment_invitation"] as? [String:Any], previous["group"] as? String == inv["group"] as? String, previous["url"] as? String == inv["url"] as? String {
            if let id = inv["id"] as? String, previous["id"] as? String == id, previous["secret"] as? String == inv["secret"] as? String { c = saved }
            if let secret = inv["bootstrap"] as? String, previous["bootstrap"] as? String == secret { c = saved }
        }
        if c["secret_key"] == nil {
            let identity = try Self.read("identity") ?? ["secret_key":RelayIdentity.generateSecretKey().relayHex]
            try Self.write("identity",identity);c["secret_key"] = identity["secret_key"]
        }
        c["device"] = c["device"] ?? SyncRelaySettings.deviceID;c["app"] = "clipy";c["group"] = inv["group"];c["url"] = inv["url"] ?? c["url"];c["trusted_peers"] = c["trusted_peers"] ?? [String:String]();c["token"] = c["token"] ?? RelayIdentity.generateSecretKey().relayHex
        c["enrollment_invitation"] = inv;c["enrollment_name"] = c["enrollment_name"] ?? name
        let g = try Self.authenticated(c);try Self.write("pending",g.config)
        if inv["bootstrap"] != nil { try await g.bootstrap(inv,name:c["enrollment_name"] as? String ?? name);try Self.persist(g,activate:true);try Self.write("pending",nil);try await refresh();return }
        do { try await g.join(inv,name:c["enrollment_name"] as? String ?? name) } catch { try Self.write("pending",g.config);throw error }
        try Self.write("pending",g.config);accessDenied = false;pendingAutomatic = inv["mode"] as? String == "auto";if let p = g.config["pending_join"] as? [String:Any], let e = p["request"] as? [String:Any] { pendingCode = try Self.code(e) };if pendingAutomatic { try await finish() } else { message = t("请在邀请设备上核对配对码并批准。","Verify the pairing code and approve on the inviting device.") }
    }
    func finish() async throws {
        guard let c = try Self.read("pending") else { return };let g = try Self.authenticated(c)
        let finished: Bool
        do { finished = try await g.finishJoin() } catch { try Self.write("pending",g.config);throw error }
        try Self.write("pending",g.config)
        if finished { try Task.checkCancellation();try Self.persist(g,activate:true);try Self.write("pending",nil);pendingCode = "";try await refresh();message = t("已加入，公网中继已启用。","Joined. Internet relay enabled.") }
        else { message = pendingAutomatic ? t("正在自动加入…","Joining automatically…") : t("正在等待邀请设备批准。","Waiting for approval on the inviting device.") }
    }
    func discard() throws { try Self.write("pending",nil);pendingCode = "" }
}
