import Foundation
import Security
import CommonRelay
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor final class RelayBridge {
    let root: URL
    let allowLocalTest = CommandLine.arguments.contains("--allow-local-relay-test")
    var groups = RelayGroups(config:[:])
    var client: RelayClient?
    var connectedTrust:[String:String]?
    private var journal:RelayJournal?
    var eventTask: Task<Void,Never>?
    var busyOwner:UUID?
    var busy:Bool { busyOwner != nil }
    var desiredEnabled = false
    var intentEpoch = UUID()
    var connectingClient:RelayClient?
    var groupRefreshToken:UUID?
    var pendingRevision = 0
    var authRejected = false
    var identityError:String?
    var connectionGeneration = UUID()
    weak var lan:LANService?
    var tunnels:[String:RelayStream] = [:]
    var tunnelSessions:[String:String] = [:]
    var tunnelRemote:[String:String] = [:]
    var pendingTunnels:[String:UUID] = [:]
    var tunnelTasks:[String:Task<Void,Never>] = [:]
    var reconnectTask:Task<Void,Never>?
    var reconnectToken:UUID?
    var groupRefreshTask:Task<Void,Never>?
    var connectingTask:Task<Void,Error>?
    var connectingToken:UUID?
    let service = "dev.clipy.tsx.experimental.relay"
    init(root:URL) {
        self.root = root
        do { try loadIdentity() } catch { identityError = "原中继身份不可读取或已损坏，已保留钥匙串记录；请解锁钥匙串后重新读取或恢复备份" }
    }
    func loadIdentity() throws {
        guard let bytes = try readSecret() else { return }
        guard let config = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let secret = config["secret_key"] as? String,(try? Data(relayHex:secret).count) == 32,config["url"] as? String != nil,config["device"] as? String != nil,config["app"] as? String != nil else { throw BridgeFailure(code:"IDENTITY_CORRUPT",message:"原中继身份数据无效") }
        try validateIdentityConfig(config)
        groups = RelayGroups(config:config,allowLocalTest:allowLocalTest);identityError = nil
    }
    func validateIdentityConfig(_ config:[String:Any]) throws {
        guard let app = config["app"] as? String,!app.isEmpty,app.utf8.count <= 128,let device = config["device"] as? String,!device.isEmpty,device.utf8.count <= 128,let text = config["secret_key"] as? String,let secret = try? Data(relayHex:text),secret.count == 32 else { throw BridgeFailure(code:"INVALID_IDENTITY",message:"接入身份格式无效，原配置未修改") }
        let trusted:[String:String]
        if let value = config["trusted_peers"] { guard let peers = value as? [String:String],peers.count <= 128 else { throw BridgeFailure(code:"INVALID_IDENTITY",message:"可信公钥表格式无效") };trusted = peers } else { trusted = [:] }
        let keys = try trusted.mapValues { value -> Data in let data = try Data(relayHex:value);guard data.count == 32 else { throw BridgeFailure(code:"INVALID_IDENTITY",message:"可信公钥格式无效") };return data }
        let identity = try RelayIdentity(app:app,group:config["group"] as? String ?? "",device:device,secretKey:secret,trustedPeers:keys)
        if let rawEntry = config["group_entry"] {
            guard let entry = rawEntry as? [String:Any],let state = try? RelayGroups.unpack(entry),state["app"] as? String == app,state["group"] as? String == config["group"] as? String,let members = state["members"] as? [[String:Any]],let own = members.first(where:{$0["device"] as? String == device}),own["public_key"] as? String == identity.publicKey.relayHex else { throw BridgeFailure(code:"INVALID_IDENTITY",message:"设备组身份与本机密钥不匹配，原配置未修改") }
        }
        if let token = config["token"],!(token is String) { throw BridgeFailure(code:"INVALID_IDENTITY",message:"设备 Key 格式无效") }
        if let passwords = config["server_passwords"],!(passwords is [String:String]) { throw BridgeFailure(code:"INVALID_IDENTITY",message:"服务器访问密码记录损坏") }
    }
    func readSecret() throws -> Data? {
        var item:CFTypeRef?;let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:root.path,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        let result = SecItemCopyMatching(q as CFDictionary,&item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess,let bytes = item as? Data else { throw BridgeFailure(code:"KEYCHAIN_IDENTITY_UNAVAILABLE",message:"钥匙串拒绝读取原中继身份") };return bytes
    }
    func save() throws {
        if let url = groups.config["url"] as? String,let password = groups.config["password"] as? String {
            var passwords = groups.config["server_passwords"] as? [String:String] ?? [:];passwords[url] = password;groups.config["server_passwords"] = passwords
        }
        let bytes = try JSONSerialization.data(withJSONObject:groups.config)
        let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:root.path]
        let result = SecItemUpdate(q as CFDictionary,[kSecValueData as String:bytes] as CFDictionary)
        if result == errSecItemNotFound { var add = q;add[kSecValueData as String] = bytes;add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw BridgeFailure(code:"KEYCHAIN",message:"无法安全保存中继配置") } }
        else if result != errSecSuccess { throw BridgeFailure(code:"KEYCHAIN",message:"无法更新中继配置") }
    }
    func status() -> [String:Any] {
        var out:[String:Any] = ["identityError":identityError as Any? ?? NSNull(),"enabled":desiredEnabled,"configured":groups.config["url"] != nil,"connected":client != nil]
        for key in ["url","app","group","device"] { out[key] = groups.config[key] }
        if !authRejected,let entry = groups.config["group_entry"] as? [String:Any],let body = try? RelayGroups.unpack(entry) { out["membership"] = body }
        if !authRejected,let pending = groups.config["pending_join"] as? [String:Any],let request = pending["request"] as? [String:Any],let payload = try? RelayGroups.payload(request) { out["joinPending"] = true;out["pairingCode"] = String(RelayGroups.digest(payload).prefix(12)).uppercased() }
        if !authRejected,let invitation = groups.config["ui_invitation"] as? [String:Any] { out["activeInvitation"] = ["id":invitation["id"] ?? "","mode":invitation["mode"] ?? "manual","expires":invitation["expires"] ?? 0] }
        out["authRejected"] = authRejected
        out["members"] = (out["membership"] as? [String:Any])?["members"] ?? []
        out["peers"] = lan?.status()["peers"] ?? []
        out["hasPassword"] = (groups.config["password"] as? String)?.isEmpty == false
        return out
    }
    static func qrImage(_ link:String) throws -> String {
        guard !link.isEmpty,link.utf8.count <= 8192,let filter = CIFilter(name:"CIQRCodeGenerator") else { throw BridgeFailure(code:"QR_ENCODING",message:"无法生成邀请二维码") }
        filter.setValue(Data(link.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
        guard let raw = filter.outputImage else { throw BridgeFailure(code:"QR_ENCODING",message:"邀请链接超出二维码容量") }
        let bounds = raw.extent.insetBy(dx:-4,dy:-4),background = CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:raw.extent.insetBy(dx:-4,dy:-4))
        let image = raw.composited(over:background).cropped(to:bounds).transformed(by:CGAffineTransform(scaleX:8,y:8)),context = CIContext(options:[.cacheIntermediates:false])
        guard let cg = context.createCGImage(image,from:image.extent) else { throw BridgeFailure(code:"QR_ENCODING",message:"无法渲染邀请二维码") }
        let bytes = NSMutableData();guard let destination = CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil) else { throw BridgeFailure(code:"QR_ENCODING",message:"无法编码邀请二维码") }
        CGImageDestinationAddImage(destination,cg,nil);guard CGImageDestinationFinalize(destination) else { throw BridgeFailure(code:"QR_ENCODING",message:"二维码编码失败") }
        return "data:image/png;base64,"+(bytes as Data).base64EncodedString()
    }
    func identity() throws -> RelayIdentity {
        let c = groups.config
        guard let app = c["app"] as? String,let group = c["group"] as? String,let device = c["device"] as? String,let secret = c["secret_key"] as? String else { throw BridgeFailure(code:"NOT_CONFIGURED",message:"请先创建或加入设备组") }
        let peers = try (c["trusted_peers"] as? [String:String] ?? [:]).mapValues { try Data(relayHex:$0) }
        return try RelayIdentity(app:app,group:group,device:device,secretKey:Data(relayHex:secret),trustedPeers:peers)
    }
    func required(_ p:[String:Any],_ key:String) throws -> String { guard let s = p[key] as? String,!s.isEmpty else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"缺少 \(key)") };return s }
    func trace(_ phase:String,_ owner:RelayClient?=nil) {
        if allowLocalTest { BridgeOutput.write(["event":"relay.trace","payload":["phase":phase,"owner":owner.map { String(describing:ObjectIdentifier($0)) } ?? "nil","generation":String(connectionGeneration.uuidString.prefix(6))]]) }
    }
    func close(preserveReconnect:Bool=false,preserveConnecting:Bool=false) async {
        // Detach all owners before the first await: actors can reenter while an
        // old stream drains and must never clear or accidentally close a new owner.
        let oldClient = client,oldCandidate = connectingClient;client = nil;connectingClient = nil;connectedTrust = nil;trace("close.begin",oldClient)
        let oldEvent = eventTask;eventTask = nil
        let oldStreams = Array(tunnels.values);tunnels.removeAll()
        let oldSessions = Array(tunnelSessions.values);tunnelSessions.removeAll()
        let oldTasks = Array(tunnelTasks.values);tunnelTasks.removeAll()
        if !preserveConnecting { connectingTask?.cancel();connectingTask = nil;connectingToken = nil }
        connectionGeneration = UUID();groupRefreshTask?.cancel();groupRefreshTask = nil;groupRefreshToken = nil
        if !preserveReconnect { reconnectTask?.cancel();reconnectTask = nil;reconnectToken = nil }
        oldEvent?.cancel();for task in oldTasks { task.cancel() }
        tunnelRemote.removeAll();pendingTunnels.removeAll()
        for session in oldSessions { lan?.closeTunnel(sessionId:session) }
        // Closing the socket first also unblocks a sender waiting on stream credits.
        if let oldCandidate,oldCandidate !== oldClient { await oldCandidate.close() }
        await oldClient?.close();trace("close.done",oldClient)
        for stream in oldStreams { await stream.close() }
    }
    func shutdown() async { desiredEnabled = false;intentEpoch = UUID();pendingRevision = 0;await close() }
    func invoke(_ method:String,_ p:[String:Any]) async throws -> Any {
        do { return try await perform(method,p) } catch {
            if String(describing:error).contains("401") { authRejected = true;await close();throw BridgeFailure(code:"AUTH_REJECTED",message:"中继认证失败，请检查访问密码与设备 Key，设备组信息已隐藏") };throw error
        }
    }
    func perform(_ method:String,_ p:[String:Any]) async throws -> Any {
        if method == "testCorruptIdentity",allowLocalTest,(root.path.contains("/T/clipy-") || root.path.hasPrefix("/tmp/clipy-")) {
            let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:root.path];guard SecItemUpdate(q as CFDictionary,[kSecValueData as String:Data("invalid-fixture-json".utf8)] as CFDictionary) == errSecSuccess else { throw BridgeFailure(code:"TEST_ERROR",message:"测试条目不存在") };return true
        }
        if method == "testIdentityDigest",allowLocalTest { if let data = try readSecret() { return RelayGroups.digest(data) };return NSNull() }
        if method == "testProbe",allowLocalTest {
            do { _ = try await groups.call("GET","/ws");return ["upgradeProbe":"unexpected-200"] } catch { return ["upgradeProbe":String(describing:error)] }
        }
        if method == "testCleanup",allowLocalTest {
            await close();let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:root.path];SecItemDelete(q as CFDictionary);groups = RelayGroups(config:[:],allowLocalTest:true);return true
        }
        if method == "status" { return status() }
        if method == "reloadIdentity" {
            guard !busy,client == nil,connectingTask == nil else { throw BridgeFailure(code:"BUSY",message:"请先关闭中继连接，再重新读取身份") }
            await shutdown()
            do { try loadIdentity() } catch { identityError = "原中继身份不可读取或已损坏，已保留钥匙串记录";throw BridgeFailure(code:"IDENTITY_UNAVAILABLE",message:identityError!) };return status()
        }
        if method == "disconnect" { await shutdown();return status() }
        guard identityError == nil else { throw BridgeFailure(code:"IDENTITY_UNAVAILABLE",message:identityError!) }
        guard !busy else { throw BridgeFailure(code:"BUSY",message:"中继操作进行中") }
        let operation = UUID();busyOwner = operation;defer { if busyOwner == operation { busyOwner = nil } }
        switch method {
        case "configure":
            let request = (p["config"] as? [String:Any] ?? [:]).merging(p) { _,new in new }
            var config = groups.config
            let oldURL = config["url"] as? String
            var passwords = config["server_passwords"] as? [String:String] ?? [:]
            if let oldURL,let oldPassword = config["password"] as? String { passwords[oldURL] = oldPassword }
            guard let raw = request["url"] as? String ?? oldURL,var components = URLComponents(string:raw),(components.scheme == "wss" || (allowLocalTest && components.scheme == "ws" && components.host == "127.0.0.1")),components.path == "/relay/v1/ws",components.user == nil,components.password == nil,components.query == nil,components.fragment == nil,let hostname = components.host,!hostname.isEmpty else { throw BridgeFailure(code:"INVALID_URL",message:"请填写 wss:// 中继地址，路径为 /relay/v1/ws") }
            components.scheme = components.scheme?.lowercased();components.host = hostname.lowercased()
            if components.port == (components.scheme == "wss" ? 443:80) { components.port = nil };let url = components.string!
            if oldURL != nil,url != oldURL,(config["group_entry"] != nil || config["group"] != nil || config["pending_join"] != nil) { throw BridgeFailure(code:"SERVER_CHANGE_REQUIRES_IDENTITY",message:"已有设备组不能自动迁移到另一中继服务器") }
            let fields = ["token","app","device","secret_key","trusted_peers","group","group_entry"]
            for key in fields { if let value = request[key] { if key == "token",value as? String == "" { continue };config[key] = value } }
            if request["clearPassword"] as? Bool == true { passwords.removeValue(forKey:url) }
            else if let password = request["password"] as? String,!password.isEmpty { try RelayAccess.validate(password);passwords[url] = password }
            config["url"] = url;config["password"] = passwords[url];config["server_passwords"] = passwords
            if config["app"] == nil { config["app"] = "clipy" };if config["device"] == nil { config["device"] = "mac-"+UUID().uuidString.lowercased() }
            if config["secret_key"] == nil { config["secret_key"] = RelayIdentity.generateSecretKey().relayHex }
            try validateIdentityConfig(config)
            intentEpoch = UUID();await close();groups = RelayGroups(config:config,allowLocalTest:allowLocalTest);authRejected = false;try save();if desiredEnabled,groups.config["group"] != nil,groups.config["pending_join"] == nil { try await connectTransport() };return status()
        case "create":try groups.prepareCreate(groupName:try required(p,"name"),deviceName:p["deviceName"] as? String ?? Host.current().localizedName ?? "Mac");desiredEnabled = true;intentEpoch = UUID();try save();try await groups.create()
        case "join":
            guard groups.config["group_entry"] == nil,groups.config["pending_create"] == nil else { throw BridgeFailure(code:"ALREADY_ENROLLED",message:"请先退出当前设备组") }
            intentEpoch = UUID();let epoch = intentEpoch
            let invitation = try await resolveInvitationForJoin(required(p,"link"))
            guard intentEpoch == epoch,!Task.isCancelled else { throw CancellationError() }
            desiredEnabled = true
            var config = groups.config
            if let previous = config["group"] as? String,config["pending_join"] == nil,previous != invitation["group"] as? String { throw BridgeFailure(code:"ALREADY_ENROLLED",message:"已有设备组配置，请先处理当前设备组") }
            let url = invitation["url"] as! String,app = invitation["app"] as! String
            var passwords = config["server_passwords"] as? [String:String] ?? [:]
            if let oldURL = config["url"] as? String,let password = config["password"] as? String { passwords[oldURL] = password }
            if let password = invitation["password"] as? String { try RelayAccess.validate(password);passwords[url] = password }
            let previousURL:String? = config["url"] as? String,previousApp:String? = config["app"] as? String,previousGroup:String? = config["group"] as? String,newGroup:String? = invitation["group"] as? String
            let changedScope = previousURL != url || previousApp != app || previousGroup != newGroup
            if changedScope { config.removeValue(forKey:"token") }
            if config["pending_join"] == nil { config["ui_join_previous_group"] = config["group"] ?? NSNull() }
            config["app"] = app;config["url"] = url;config["group"] = invitation["group"];config["password"] = passwords[url];config["server_passwords"] = passwords
            if config["device"] == nil { config["device"] = "mac-"+UUID().uuidString.lowercased() }
            if config["secret_key"] == nil { config["secret_key"] = RelayIdentity.generateSecretKey().relayHex }
            try validateIdentityConfig(config);groups = RelayGroups(config:config,allowLocalTest:allowLocalTest);try save()
            do { try await groups.join(invitation,name:p["deviceName"] as? String ?? "Mac");try save();guard intentEpoch == epoch,!Task.isCancelled else { throw CancellationError() };_ = try await groups.finishJoin() } catch { try save();throw error }
        case "cancelJoin":
            guard groups.config["group_entry"] == nil else { throw BridgeFailure(code:"ALREADY_ENROLLED",message:"已经加入设备组，请使用明确的退出操作") }
            if groups.config["pending_join"] != nil {
                groups.config.removeValue(forKey:"pending_join")
                if let previous = groups.config.removeValue(forKey:"ui_join_previous_group") as? String { groups.config["group"] = previous } else { groups.config.removeValue(forKey:"group") }
                try save();await shutdown()
            }
            let result = status();BridgeOutput.write(["event":"relay.status.changed","payload":result]);return result
        case "finish":let done = try await groups.finishJoin();try save();if done,desiredEnabled { try await connectTransport() };return ["joined":done,"status":status()]
        case "refresh":
            if groups.config["pending_join"] == nil,groups.config["group_entry"] == nil { if desiredEnabled,groups.config["group"] != nil,client == nil { try await connectTransport() };if client != nil { try await refreshTunnels() };return status() }
            if groups.config["pending_join"] != nil { let complete = try await groups.finishJoin();try save();if !complete { return status() } }
            _ = try await groups.refresh();authRejected = false;try save();if desiredEnabled,(client == nil || connectedTrust != (groups.config["trusted_peers"] as? [String:String] ?? [:])) { try await connectTransport() };try await refreshTunnels();return status()
        case "invite":
            let invitation = try await groups.invite(mode:p["mode"] as? String ?? "auto",compact:true);groups.config["ui_invitation"] = invitation;try save()
            let link = invitation["short_link"] as? String ?? ""
            return ["id":invitation["id"] ?? "","short_link":link,"link":link,"qrImage":try Self.qrImage(link),"expires":invitation["expires"] ?? 0,"mode":invitation["mode"] ?? "auto"]
        case "pending":
            guard let invitation = groups.config["ui_invitation"] as? [String:Any] else { return [:] };guard let request = try await groups.pending(invitation) else { return [:] }
            let payload = try RelayGroups.payload(request),value = try RelayGroups.unpack(request)
            return ["request":request,"member":value["member"] ?? [:],"name":(value["member"] as? [String:Any])?["name"] ?? "","pairingCode":String(RelayGroups.digest(payload).prefix(12)).uppercased(),"invitation":["id":invitation["id"] ?? ""]]
        case "approve":try await groups.approve(groups.config["ui_invitation"] as? [String:Any] ?? p["invitation"] as? [String:Any] ?? [:],request:p["request"] as? [String:Any] ?? [:],manager:p["manager"] as? Bool ?? false)
        case "cancel":try await groups.cancel(groups.config["ui_invitation"] as? [String:Any] ?? p["invitation"] as? [String:Any] ?? [:]);groups.config.removeValue(forKey:"ui_invitation")
        case "remove":try await groups.remove(device:required(p,"device"))
        case "rename":try await groups.rename(device:required(p,"device"),name:required(p,"name"))
        case "leave","disband":
            try await groups.prepareExit(disband:method == "disband");try save();try await groups.exit();await shutdown()
            // The SDK keeps the signed exit state for auditing. The app clears its
            // current enrollment only after the server has accepted that state.
            // LAN identity/history and the private transport key remain untouched.
            for key in ["group","group_entry","token","trusted_peers","pending_join","pending_create","pending_exit","ui_invitation","ui_join_previous_group","public_key"] { groups.config.removeValue(forKey:key) }
            groups.config["device"] = "mac-"+UUID().uuidString.lowercased()
        case "connect":
            if !desiredEnabled { intentEpoch = UUID() };desiredEnabled = true
            if groups.config["pending_join"] != nil,groups.config["group_entry"] == nil { return status() }
            if client != nil,connectedTrust == (groups.config["trusted_peers"] as? [String:String] ?? [:]) { return status() }
            try await connectTransport();return status()
        case "send":
            guard let client else { throw BridgeFailure(code:"NOT_CONNECTED",message:"中继未连接") };let data = Data(try required(p,"text").utf8);guard data.count <= 1024*1024 else { throw BridgeFailure(code:"TOO_LARGE",message:"消息超过 1 MiB") }
            let id = p["id"] as? String ?? UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            let result = try await client.message(to:required(p,"to"),data:data,offline:p["offline"] as? Bool ?? true,id:id);return result.object
        case "ack":guard let client else { throw BridgeFailure(code:"NOT_CONNECTED",message:"中继未连接") };try await client.acknowledge(id:required(p,"id"),from:required(p,"from"),offline:p["offline"] as? Bool ?? true);return true
        case "peers":guard let client else { throw BridgeFailure(code:"NOT_CONNECTED",message:"中继未连接") };return try await client.peers().map { ["device":$0.device,"app":$0.app,"group":$0.group] }
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"尚未实现中继操作 \(method)")
        }
        try save()
        if desiredEnabled,["create","join","approve","remove","rename"].contains(method),groups.config["group_entry"] != nil,(client == nil || connectedTrust != (groups.config["trusted_peers"] as? [String:String] ?? [:])) { try await connectTransport() }
        return status()
    }
    func resolveInvitationForJoin(_ text:String) async throws -> [String:Any] {
        let parsed = try RelayInvitationLinks.parse(text.trimmingCharacters(in:.whitespacesAndNewlines),allowLocalTest:allowLocalTest)
        var endpoint:[String:Any] = ["url":parsed.url]
        var password:String? = parsed.password
        let storedPasswords:[String:String] = groups.config["server_passwords"] as? [String:String] ?? [:]
        if password == nil { password = storedPasswords[parsed.url] }
        let configuredURL:String? = groups.config["url"] as? String
        if password == nil,configuredURL == parsed.url { password = groups.config["password"] as? String }
        if let password { endpoint["password"] = password }
        let resolver = RelayGroups(config:endpoint,allowLocalTest:allowLocalTest)
        let packet = try await resolver.call("GET","/enroll/\(parsed.id)/link",authorization:"InvitationLink \(try RelayInvitationLinks.readToken(parsed.key))")
        guard packet["version"] as? Int == 1,let encrypted = packet["packet"] as? String else { throw BridgeFailure(code:"INVITATION_INVALID",message:"邀请格式无效") }
        var invitation = try RelayInvitationLinks.open(encrypted,key:parsed.key)
        guard invitation["version"] as? Int == 1,invitation["url"] as? String == parsed.url,invitation["id"] as? String == parsed.id,let app = invitation["app"] as? String,!app.isEmpty,let group = invitation["group"] as? String,!group.isEmpty,(invitation["expires"] as? Double ?? 0)>Date().timeIntervalSince1970 else { throw BridgeFailure(code:"INVITATION_INVALID",message:"邀请无效或已过期") }
        if let password { invitation["password"] = password };return invitation
    }
    func connectTransport(isRetry:Bool=false) async throws {
        guard desiredEnabled else { throw BridgeFailure(code:"RELAY_DISABLED",message:"公网中继已关闭") }
        if let connectingTask { try await connectingTask.value;return }
        let token = UUID();connectingToken = token
        let task = Task<Void,Error> { try await self.establishTransport(isRetry:isRetry) };connectingTask = task
        do { try await task.value;if connectingToken == token { connectingTask = nil;connectingToken = nil } }
        catch { if connectingToken == token { connectingTask = nil;connectingToken = nil };throw error }
    }
    func establishTransport(isRetry:Bool) async throws {
        let epoch = intentEpoch
        await close(preserveReconnect:isRetry,preserveConnecting:true);let generation = connectionGeneration
        guard desiredEnabled,intentEpoch == epoch,!Task.isCancelled else { throw CancellationError() }
        let owner = busyOwner == nil ? UUID():nil;if let owner { busyOwner = owner };defer { if let owner,busyOwner == owner { busyOwner = nil } }
        if groups.config["group_entry"] != nil { _ = try await groups.refresh();guard desiredEnabled,intentEpoch == epoch,!Task.isCancelled else { throw CancellationError() };try save() }
        let identity = try identity();guard let url = URL(string:try required(groups.config,"url")) else { throw BridgeFailure(code:"INVALID_URL",message:"中继地址无效") }
        if journal == nil { journal = try RelayJournal(directory:root.appendingPathComponent("relay-journal")) };let journal = self.journal!
        var accepted:(RelayClient,AsyncThrowingStream<RelayEvent,Error>)?
        let delays:[UInt64] = [0,150_000_000,500_000_000,1_000_000_000]
        for (attempt,delay) in delays.enumerated() {
            if delay > 0 { try await Task.sleep(nanoseconds:delay) };try Task.checkCancellation()
            let candidate = RelayClient(identity:identity,journal:journal);connectingClient = candidate;trace("connect.attempt.\(attempt)",candidate)
            do { let events = try await candidate.connect(url:url,token:required(groups.config,"token"),password:groups.config["password"] as? String,allowLocalTest:allowLocalTest);accepted = (candidate,events);if connectingClient === candidate { connectingClient = nil };trace("connect.accepted",candidate);break }
            catch { trace("connect.failed.\(attempt)",candidate);await candidate.close();if connectingClient === candidate { connectingClient = nil };if let urlError = error as? URLError,urlError.code == .badServerResponse,attempt < delays.count-1 { continue };throw error }
        }
        guard let (connection,stream) = accepted else { throw BridgeFailure(code:"CONNECT_FAILED",message:"中继连接未建立") }
        guard desiredEnabled,intentEpoch == epoch,connectionGeneration == generation,!Task.isCancelled else { await connection.close();throw CancellationError() };client = connection;connectedTrust = groups.config["trusted_peers"] as? [String:String] ?? [:];authRejected = false;trace("connect.adopt",connection)
        eventTask = Task<Void,Never> { [weak self] in
            do { for try await event in stream {
                guard let self,!Task.isCancelled,self.connectionGeneration == generation else { break }
                if event["type"] as? String == "stream.open" {
                    let tunnel = try await connection.acceptStream(event)
                    guard self.desiredEnabled,self.intentEpoch == epoch,self.connectionGeneration == generation,self.client === connection,!Task.isCancelled else { await tunnel.close();break }
                    do { try await self.attachTunnel(tunnel,remote:event["from"] as? String ?? "",outbound:false,generation:generation,epoch:epoch,owner:connection) } catch { await tunnel.close() };continue
                }
                if ["peer.up","presence"].contains(event["type"] as? String ?? "") { try? await self.refreshTunnels() }
                if event["type"] as? String == "group.changed" { self.scheduleGroupRefresh(revision:event["revision"] as? Int) }
                var value = event.object
                if let data = value.removeValue(forKey:"data") as? Data { if data.count <= 1024*1024 { value["text"] = String(data:data,encoding:.utf8) ?? "" } else { value["error"] = "message_too_large" } }
                BridgeOutput.write(["event":"relay.event","payload":value])
            } } catch { if !Task.isCancelled { BridgeOutput.write(["event":"relay.disconnected","payload":["message":"中继连接中断"]]) } }
            await connection.close()
            if let self,self.connectionGeneration == generation,self.intentEpoch == epoch,self.client === connection {
                self.trace("event.end.current",connection);self.client = nil;self.connectedTrust = nil
                if self.desiredEnabled { self.scheduleReconnect() }
            } else { self?.trace("event.end.old",connection) }
        }
        do { try await refreshTunnels() } catch {
            if connectionGeneration == generation { await close(preserveReconnect:isRetry,preserveConnecting:true) } else { await connection.close() };throw error
        }
    }

    func verifiedRevision() -> Int {
        guard let entry = groups.config["group_entry"] as? [String:Any],let state = try? RelayGroups.unpack(entry) else { return 0 };return state["revision"] as? Int ?? 0
    }
    func scheduleGroupRefresh(revision:Int?) {
        let known = verifiedRevision()
        if let revision,revision <= known { return }
        pendingRevision = max(pendingRevision,revision ?? known+1)
        guard groupRefreshTask == nil else { return }
        let generation = connectionGeneration,epoch = intentEpoch,token = UUID();groupRefreshToken = token
        groupRefreshTask = Task<Void,Never> { @MainActor [weak self] in
            let operation = UUID()
            defer {
                if self?.busyOwner == operation { self?.busyOwner = nil }
                if self?.groupRefreshToken == token { self?.groupRefreshTask = nil;self?.groupRefreshToken = nil }
            }
            for _ in 0..<150 {
                guard let self,!Task.isCancelled,self.intentEpoch == epoch,self.connectionGeneration == generation else { return }
                if self.busy { try? await Task.sleep(nanoseconds:100_000_000);continue }
                if self.pendingRevision <= self.verifiedRevision() { self.pendingRevision = 0;return }
                self.busyOwner = operation;let before = self.verifiedRevision()
                do {
                    _ = try await self.groups.refresh()
                    guard !Task.isCancelled,self.intentEpoch == epoch,self.connectionGeneration == generation else { return }
                    try self.save();let verified = self.verifiedRevision(),trust = self.groups.config["trusted_peers"] as? [String:String] ?? [:]
                    if self.pendingRevision <= verified || verified <= before { self.pendingRevision = 0 }
                    if self.groupRefreshToken == token { self.groupRefreshTask = nil;self.groupRefreshToken = nil }
                    if self.desiredEnabled,(self.client == nil || self.connectedTrust != trust) { try await self.connectTransport() }
                    guard self.intentEpoch == epoch,!Task.isCancelled else { return }
                    if self.busyOwner == operation { self.busyOwner = nil }
                    BridgeOutput.write(["event":"relay.status.changed","payload":self.status()])
                    if self.pendingRevision > self.verifiedRevision() { self.scheduleGroupRefresh(revision:self.pendingRevision) }
                } catch {
                    guard !Task.isCancelled,self.intentEpoch == epoch else { return }
                    if String(describing:error).contains("401") { self.authRejected = true;await self.close();BridgeOutput.write(["event":"relay.status.changed","payload":self.status()]) }
                    BridgeOutput.write(["event":"relay.groupError","payload":["message":"设备组验证失败，请刷新检查"]])
                };return
            }
        }
    }
    func scheduleReconnect() {
        guard desiredEnabled,reconnectTask == nil,!authRejected,identityError == nil,groups.config["url"] != nil else { return }
        let token = UUID();reconnectToken = token
        reconnectTask = Task<Void,Never> { @MainActor [weak self] in
            defer { if self?.reconnectToken == token { self?.reconnectTask = nil;self?.reconnectToken = nil } }
            for delay in [1,3,10,30,60] {
                try? await Task.sleep(nanoseconds:UInt64(delay)*1_000_000_000)
                guard let self,!Task.isCancelled,self.desiredEnabled,!self.authRejected,self.client == nil else { return }
                do { try await self.connectTransport(isRetry:true);return }
                catch { if String(describing:error).contains("401") { self.authRejected = true;BridgeOutput.write(["event":"relay.status.changed","payload":self.status()]);return } }
            }
        }
    }
    func refreshTunnels() async throws {
        guard let connection = client,lan != nil else { return }
        let generation = connectionGeneration,epoch = intentEpoch
        let peers = try await connection.peers()
        guard desiredEnabled,epoch == intentEpoch,generation == connectionGeneration,client === connection,!Task.isCancelled else { return }
        for peer in peers where peer.device != groups.config["device"] as? String && !hasTunnel(remote:peer.device) && pendingTunnels[peer.device] == nil {
            let token = UUID();pendingTunnels[peer.device] = token
            Task { [weak self] in
                guard let self else { return };defer { if self.pendingTunnels[peer.device] == token { self.pendingTunnels.removeValue(forKey:peer.device) } }
                do { let stream = try await connection.openStream(to:peer.device);guard self.desiredEnabled,self.intentEpoch == epoch,self.connectionGeneration == generation,self.client === connection,!Task.isCancelled else { await stream.close();return };try await self.attachTunnel(stream,remote:peer.device,outbound:true,generation:generation,epoch:epoch,owner:connection) }
                catch { if self.desiredEnabled,self.intentEpoch == epoch,self.connectionGeneration == generation,self.client === connection { BridgeOutput.write(["event":"relay.tunnelError","payload":["device":peer.device,"message":"中继设备会话未建立"]]) } }
            }
        }
    }
    func hasTunnel(remote:String) -> Bool { tunnelRemote.values.contains(remote) }
    func attachTunnel(_ stream:RelayStream,remote:String,outbound:Bool,generation:UUID,epoch:UUID,owner:RelayClient) async throws {
        guard desiredEnabled,intentEpoch == epoch,connectionGeneration == generation,client === owner,!Task.isCancelled else { await stream.close();throw CancellationError() }
        guard let lan,!remote.isEmpty else { await stream.close();return }
        // Relay IDs and application peer UUIDs can have opposite sort orders.
        // Keep at most the two crossed streams and let the shared v3 session
        // arbiter choose by the application's authenticated handshake peer ID.
        guard tunnelRemote.values.filter({$0 == remote}).count < 2 else { await stream.close();return }
        let key = UUID().uuidString,writer = RelayTunnelWriter(stream:stream)
        let session = try lan.openTunnel(id:remote,initiator:outbound,send:{ data in try await writer.send(data) },onClose:{ Task { await stream.close() } })
        tunnels[key] = stream;tunnelSessions[key] = session;tunnelRemote[key] = remote
        tunnelTasks[key] = Task<Void,Never> { [weak self] in
            do { while !Task.isCancelled,!(await stream.receivedFinal) {
                let data = try await stream.receive();let final = await stream.receivedFinal;if data.isEmpty && final { break }
                guard let self,self.desiredEnabled,self.intentEpoch == epoch,self.connectionGeneration == generation,self.client === owner else { break };try await lan.feedTunnel(sessionId:session,data:data)
            } } catch {}
            lan.closeTunnel(sessionId:session);await stream.close()
            if let self,self.connectionGeneration == generation,self.tunnelSessions[key] == session {
                self.tunnels.removeValue(forKey:key);self.tunnelSessions.removeValue(forKey:key);self.tunnelRemote.removeValue(forKey:key);self.tunnelTasks.removeValue(forKey:key)
            }
        }
    }

}

/// Preserve whole-frame ordering across concurrent v3 ping/history/file operations.
private actor RelayTunnelWriter {
    let stream:RelayStream
    var tail:Task<Void,Error>?
    var pending = 0
    var bytes = 0
    init(stream:RelayStream) { self.stream = stream }
    func send(_ data:Data) async throws {
        guard pending < 32,bytes + data.count <= 4*1024*1024 else { throw RelayError.backpressure }
        pending += 1;bytes += data.count;defer { pending -= 1;bytes -= data.count }
        let previous = tail,stream = stream
        let operation = Task { if let previous { try await previous.value };try Task.checkCancellation();try await stream.send(data) }
        tail = operation;try await operation.value
    }
}
