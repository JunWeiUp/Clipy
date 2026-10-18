import Foundation
import Clibsodium

/// The app owns private persistence of config, including the verified chain tip.
/// Never initialize trust from a server-supplied public key; use a QR/invitation.
public final class RelayGroups: @unchecked Sendable {
    public var config: [String: Any]
    private let allowLocalTest: Bool
    public init(config: [String: Any], allowLocalTest: Bool = false) { self.config = config; self.allowLocalTest = allowLocalTest }
    public static func digest(_ data: Data) -> String { var out = [UInt8](repeating: 0,count: 32); crypto_hash_sha256(&out, Array(data), UInt64(data.count)); return Data(out).relayHex }
    public static func payload(_ entry: [String: Any]) throws -> Data { guard let text = entry["payload"] as? String, let raw = Data(base64Encoded: text), raw.count <= 32768 else { throw RelayError.invalid("membership payload") }; return raw }
    public static func unpack(_ entry: [String: Any]) throws -> [String: Any] { try dictionary(payload(entry)) }
    private func signing() throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard let text = config["secret_key"] as? String else { throw RelayError.invalid("identity") }
        let secret = try Data(relayHex: text); guard secret.count == 32 else { throw RelayError.invalid("identity") }
        let seed = try Data(relayHex: Self.digest(Data("common-relay/group-signing/v1\0".utf8) + secret))
        var pk = [UInt8](repeating: 0,count: 32), sk = [UInt8](repeating: 0,count: 64); try checked(crypto_sign_seed_keypair(&pk,&sk,Array(seed))); return (pk,sk)
    }
    public func sign(_ value: [String: Any]) throws -> [String: Any] {
        var pair = try signing(); defer { pair.secretKey.withUnsafeMutableBytes { sodium_memzero($0.baseAddress,$0.count) } }
        let bytes = try json(value); var signature = [UInt8](repeating: 0,count: 64)
        try checked(crypto_sign_detached(&signature,nil,Array(bytes),UInt64(bytes.count),pair.secretKey))
        return ["payload":bytes.base64EncodedString(),"signature":Data(signature).relayHex,"signer":config["device"] ?? ""]
    }
    public static func verify(_ entry: [String: Any], key: String) throws {
        let bytes = try payload(entry), pk = try Data(relayHex:key), sig = try Data(relayHex:entry["signature"] as? String ?? "")
        guard pk.count == 32, sig.count == 64 else { throw RelayError.invalid("signature") }
        try checked(crypto_sign_verify_detached(Array(sig),Array(bytes),UInt64(bytes.count),Array(pk)))
    }
    public func member(name: String) throws -> [String: Any] {
        var pair = try signing(); defer { pair.secretKey.withUnsafeMutableBytes { sodium_memzero($0.baseAddress,$0.count) } }
        let secret = try Data(relayHex:config["secret_key"] as? String ?? "")
        let identity = try RelayIdentity(app: "",group: "",device: "",secretKey:secret,trustedPeers:[:])
        return ["device":config["device"] ?? "","name":name,"public_key":identity.publicKey.relayHex,"signing_key":Data(pair.publicKey).relayHex,"manager":false]
    }
    private func validate(_ g: [String: Any]) throws {
        guard g["version"] as? Int == 1, g["app"] as? String == config["app"] as? String, g["group"] as? String == config["group"] as? String,
              let members = g["members"] as? [[String:Any]], members.count <= 32, ((g["closed"] as? Bool == true) ? members.isEmpty : !members.isEmpty), Set(members.compactMap { $0["device"] as? String }).count == members.count, (g["closed"] as? Bool == true || members.contains(where: {$0["manager"] as? Bool == true})) else { throw RelayError.invalid("membership") }
    }
    public func advance(_ oldEntry: [String:Any], _ entry: [String:Any]) throws -> [String:Any] {
        let old = try Self.unpack(oldEntry), next = try Self.unpack(entry); try validate(next)
        guard let before = old["members"] as? [[String:Any]], let after = next["members"] as? [[String:Any]],
              let actor = before.first(where: {$0["device"] as? String == entry["signer"] as? String}), old["closed"] as? Bool != true,
              let key = actor["signing_key"] as? String else { throw RelayError.invalid("untrusted manager") }
        if entry["authorization"] == nil { try Self.verify(entry,key:key) }
        guard (next["name"] as? String ?? "") == (old["name"] as? String ?? ""), next["revision"] as? Int == (old["revision"] as? Int ?? 0) + 1, next["previous"] as? String == Self.digest(try Self.payload(oldEntry)) else { throw RelayError.invalid("membership chain") }
        if entry["authorization"] != nil { try advanceAuto(oldEntry,entry,old,next,actor);return entry }
        var added = after.filter { m in !before.contains { $0["device"] as? String == m["device"] as? String } }
        let removed = before.filter { m in !after.contains { $0["device"] as? String == m["device"] as? String } }
        var renamed = [String]()
        for m in after { if let prior = before.first(where: {$0["device"] as? String == m["device"] as? String}), !(NSDictionary(dictionary:m).isEqual(to:prior)) { var same = prior;same["name"] = m["name"];if NSDictionary(dictionary:m).isEqual(to:same) { renamed.append(m["device"] as? String ?? "");continue };if prior["signing_key"] as? String == "", m["signing_key"] as? String != "", prior["public_key"] as? String == m["public_key"] as? String { added.append(m) } else { throw RelayError.invalid("identity replacement") } } }
        if !renamed.isEmpty {
            guard renamed.count == 1, added.isEmpty, removed.isEmpty, next["invitation"] as? String == "", next["request_hash"] as? String == "", actor["manager"] as? Bool == true || renamed[0] == entry["signer"] as? String else { throw RelayError.invalid("rename permission") };return entry
        }
        let add = actor["manager"] as? Bool == true && added.count == 1 && removed.isEmpty && next["invitation"] as? String != "" && next["request_hash"] as? String != ""
        let remove = removed.count == 1 && added.isEmpty && next["invitation"] as? String == "" && next["request_hash"] as? String == "" && (actor["manager"] as? Bool == true || removed[0]["device"] as? String == entry["signer"] as? String)
        let close = next["closed"] as? Bool == true && actor["manager"] as? Bool == true && after.isEmpty && next["invitation"] as? String == "" && next["request_hash"] as? String == ""
        guard add || remove || close else { throw RelayError.invalid("membership transition") }; return entry
    }
    public func call(_ method: String, _ path: String, value: [String:Any]? = nil, authorization: String? = nil) async throws -> [String:Any] {
        guard let text = config["url"] as? String, var url = URLComponents(string:text), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path == "/relay/v1/ws", url.scheme == "wss" || (allowLocalTest && url.scheme == "ws" && url.host == "127.0.0.1") else { throw RelayError.invalid("WSS required") }
        url.scheme = url.scheme == "wss" ? "https" : "http"; url.path = "/relay/v1"
        guard let base = url.url, let endpoint = URL(string:base.absoluteString + path) else { throw RelayError.invalid("URL") }
        var req = URLRequest(url:endpoint);req.httpMethod = method;req.timeoutInterval = 15
        req.setValue(authorization ?? "Bearer \(config["token"] as? String ?? "")",forHTTPHeaderField:"Authorization")
        if let value { req.httpBody = try json(value); req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let session = URLSession(configuration:.ephemeral,delegate:GroupRedirectBlocker(),delegateQueue:nil); defer { session.invalidateAndCancel() }
        let (bytes,response) = try await session.bytes(for:req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RelayError.invalid("group HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        var data = Data();for try await byte in bytes { data.append(byte); if data.count > 3*1024*1024 { throw RelayError.invalid("response too large") } };return try dictionary(data)
    }
    public func accept(_ entry: [String:Any]) throws {
        let g = try Self.unpack(entry);config["group_entry"] = entry;var trusted:[String:String] = [:]
        for m in g["members"] as? [[String:Any]] ?? [] { if let id = m["device"] as? String, id != config["device"] as? String { trusted[id] = m["public_key"] as? String } };config["trusted_peers"] = trusted;config["public_key"] = try member(name:"")["public_key"]
    }
    public func refresh() async throws -> [String:Any] {
        guard var current = config["group_entry"] as? [String:Any] else { throw RelayError.invalid("group enrollment required") }
        while true {
            let state = try Self.unpack(current);let result = try await call("GET","/group?after=\(state["revision"] as? Int ?? 0)")
            let entries = result["entries"] as? [[String:Any]] ?? [];for entry in entries { current = try advance(current,entry) };try accept(current)
            let latest = try Self.unpack(current);if entries.isEmpty || (latest["revision"] as? Int ?? 0) >= (result["revision"] as? Int ?? 0) { return ["state":latest,"online":result["online"] ?? []] }
        }
    }
    public func prepareCreate(groupName: String, deviceName: String) throws {
        guard config["group_entry"] == nil, config["pending_join"] == nil else { throw RelayError.invalid("already enrolled or joining") }
        if config["pending_create"] != nil { return }
        let title = groupName.trimmingCharacters(in:.whitespacesAndNewlines), name = deviceName.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...128).contains(title.utf8.count), (1...128).contains(name.utf8.count), config["group"] == nil else { throw RelayError.invalid("name or existing group") }
        config["group"] = "g-" + String(RelayIdentity.generateSecretKey().relayHex.prefix(32))
        if config["token"] == nil { config["token"] = RelayIdentity.generateSecretKey().relayHex }
        var own = try member(name:name); own["manager"] = true
        config["pending_create"] = try sign(["version":1,"app":config["app"] ?? "","group":config["group"] ?? "","name":title,"revision":1,"previous":"","members":[own],"invitation":"","request_hash":""])
    }
    public func create() async throws {
        guard let entry = config["pending_create"] as? [String:Any], let token = config["token"] as? String else { throw RelayError.invalid("prepare creation first") }
        _ = try await call("POST","/group/create",value:["entry":entry,"token_hash":Self.digest(Data(token.utf8))]); try accept(entry); config.removeValue(forKey:"pending_create")
    }
    public func bootstrap(_ code: [String:Any], name: String) async throws {
        guard code["app"] as? String == config["app"] as? String, code["group"] as? String == config["group"] as? String, let capability = code["bootstrap"] as? String else { throw RelayError.invalid("bootstrap scope") }
        if config["token"] == nil { config["token"] = RelayIdentity.generateSecretKey().relayHex }
        var own = try member(name:name);own["manager"] = true
        var members = [own];for (id,pk) in config["trusted_peers"] as? [String:String] ?? [:] where id != config["device"] as? String { members.append(["device":id,"name":id,"public_key":pk,"signing_key":"","manager":false]) }
        let e = try sign(["version":1,"app":config["app"] ?? "","group":config["group"] ?? "","revision":1,"previous":"","members":members,"invitation":"","request_hash":""])
        _ = try await call("POST","/group/bootstrap",value:["entry":e,"token_hash":Self.digest(Data((config["token"] as? String ?? "").utf8))],authorization:"Bootstrap \(capability)");try accept(e)
    }
    public func invite(mode: String = "manual", compact: Bool = false) async throws -> [String:Any] {
        guard ["manual","auto"].contains(mode) else { throw RelayError.invalid("unknown invitation mode") }
        _ = try await refresh();guard let current = config["group_entry"] as? [String:Any] else { throw RelayError.invalid("missing group") };let state = try Self.unpack(current)
        guard let own = (state["members"] as? [[String:Any]])?.first(where: {$0["device"] as? String == config["device"] as? String}), own["manager"] as? Bool == true else { throw RelayError.invalid("manager permission required") }
        let secret = RelayIdentity.generateSecretKey().relayHex
        var data: [String:Any] = ["secret_hash":Self.digest(Data(secret.utf8))], extra: [String:Any] = [:]
        if mode == "auto" {
            let delegate = RelayIdentity.generateSecretKey().relayHex
            let signer = delegateSigner(delegate,device:config["device"] as? String ?? "")
            let grant = try sign(["version":1,"purpose":"common-relay/admission/v1","mode":"auto","app":config["app"]!,"group":config["group"]!,"invitation":String(RelayIdentity.generateSecretKey().relayHex.prefix(32)),"expires":Int(Date().timeIntervalSince1970)+600,"secret_hash":data["secret_hash"]!,"delegate_key":try signer.member(name:"")["signing_key"]!,"anchor_revision":state["revision"]!,"anchor_hash":Self.digest(try Self.payload(current))])
            data["mode"] = mode;data["grant"] = grant;extra = ["grant":grant,"delegate_secret":delegate]
        }
        let result = try await call("POST","/group/invitations",value:data)
        if mode == "auto" {
            let g = try Self.unpack(extra["grant"] as? [String:Any] ?? [:])
            guard result["mode"] as? String == mode, result["id"] as? String == g["invitation"] as? String, result["expires"] as? Int == g["expires"] as? Int else { throw RelayError.invalid("automatic admission unsupported") }
        }
        extra.merge(["version":1,"mode":mode,"url":config["url"]!,"app":config["app"]!,"group":config["group"]!,"id":result["id"]!,"expires":result["expires"]!,"secret":secret,"manager":own]) { _, new in new };if compact { _ = try await publishInvitation(&extra) };return extra
    }
    public func publishInvitation(_ invitation: inout [String:Any]) async throws -> String {
        let key=RelayIdentity.generateSecretKey(),nonce=RelayIdentity.generateSecretKey().prefix(24)
        let packet=try RelayInvitationLinks.seal(invitation,key:key,nonce:Data(nonce))
        guard let id=invitation["id"] as? String else { throw RelayError.invalid("invitation id") }
        _ = try await call("POST","/group/invitations/\(id)/link",value:["read_hash":Self.digest(Data(try RelayInvitationLinks.readToken(key).utf8)),"packet":packet])
        let link=try RelayInvitationLinks.make(invitation,key:key);invitation["short_link"]=link;return link
    }
    public func resolveInvitation(_ text: String) async throws -> [String:Any] {
        let p=try RelayInvitationLinks.parse(text.trimmingCharacters(in:.whitespacesAndNewlines),allowLocalTest:allowLocalTest)
        let endpoint=RelayGroups(config:["url":p.url],allowLocalTest:allowLocalTest)
        let result=try await endpoint.call("GET","/enroll/\(p.id)/link",authorization:"InvitationLink \(try RelayInvitationLinks.readToken(p.key))")
        guard result["version"] as? Int == 1,let packet=result["packet"] as? String else { throw RelayError.invalid("invitation packet version") }
        let inv=try RelayInvitationLinks.open(packet,key:p.key)
        guard inv["version"] as? Int == 1,inv["url"] as? String == p.url,inv["id"] as? String == p.id,inv["app"] as? String == config["app"] as? String,(inv["expires"] as? Double ?? 0)>Date().timeIntervalSince1970 else { throw RelayError.invalid("invalid or expired invitation scope") };return inv
    }
    public func pending(_ invitation: [String:Any]) async throws -> [String:Any]? {
        let result = try await call("GET","/group/invitations/\(invitation["id"] as? String ?? "")")
        guard let e = result["request"] as? [String:Any] else { return nil };let j = try Self.unpack(e)
        guard let m = j["member"] as? [String:Any], let key = m["signing_key"] as? String, j["invitation"] as? String == invitation["id"] as? String, j["app"] as? String == config["app"] as? String, j["group"] as? String == config["group"] as? String, e["signer"] as? String == m["device"] as? String else { throw RelayError.invalid("join scope") };try Self.verify(e,key:key);return e
    }
    public func join(_ invitation: [String:Any], name: String) async throws {
        guard invitation["version"] as? Int == 1, (invitation["expires"] as? Double ?? 0) > Date().timeIntervalSince1970, ["url","app","group"].allSatisfy({invitation[$0] as? String == config[$0] as? String}) else { throw RelayError.invalid("expired invitation or scope") }
        let mode = invitation["mode"] as? String ?? "manual"
        guard ["manual","auto"].contains(mode) else { throw RelayError.invalid("unknown invitation mode") }
        if mode == "auto" { _ = try invitationGrant(invitation) }
        if config["token"] == nil { config["token"] = RelayIdentity.generateSecretKey().relayHex }
        var e = try sign(["version":1,"app":config["app"] ?? "","group":config["group"] ?? "","invitation":invitation["id"] ?? "","member":try member(name:name),"token_hash":Self.digest(Data((config["token"] as? String ?? "").utf8))])
        if let pending = config["pending_join"] as? [String:Any], let inv = pending["invitation"] as? [String:Any], inv["id"] as? String == invitation["id"] as? String, let saved = pending["request"] as? [String:Any] { e = saved }
        config["pending_join"] = ["invitation":invitation,"request":e]
        _ = try await call("POST","/enroll/\(invitation["id"] as? String ?? "")",value:e,authorization:"Invitation \(invitation["secret"] as? String ?? "")")
    }
    public func finishJoin() async throws -> Bool {
        guard let p = config["pending_join"] as? [String:Any], let inv = p["invitation"] as? [String:Any], let manager = inv["manager"] as? [String:Any], let reqEntry = p["request"] as? [String:Any] else { throw RelayError.invalid("pending join") }
        if inv["mode"] as? String == "auto" { return try await finishAuto(p) }
        let result = try await call("GET","/enroll/\(inv["id"] as? String ?? "")",authorization:"Claim \(config["token"] as? String ?? "")")
        guard let e = result["entry"] as? [String:Any] else { return false };guard e["authorization"] == nil else { throw RelayError.invalid("unexpected delegated approval") };try Self.verify(e,key:manager["signing_key"] as? String ?? "")
        let g = try Self.unpack(e), req = try Self.unpack(reqEntry);try validate(g)
        guard let own = (g["members"] as? [[String:Any]])?.first(where: {$0["device"] as? String == config["device"] as? String}), var expected = req["member"] as? [String:Any] else { throw RelayError.invalid("missing member") };expected["manager"] = own["manager"]
        guard e["signer"] as? String == manager["device"] as? String, g["invitation"] as? String == inv["id"] as? String, g["request_hash"] as? String == Self.digest(try Self.payload(reqEntry)), NSDictionary(dictionary:own).isEqual(to:expected) else { throw RelayError.invalid("approval mismatch") }
        try accept(e);config.removeValue(forKey:"pending_join");return true
    }
    private func delegateSigner(_ secret: String, device: String) -> RelayGroups {
        var c = config;c["secret_key"] = secret;c["device"] = device
        return RelayGroups(config:c,allowLocalTest:allowLocalTest)
    }
    private func validateGrant(_ entry: [String:Any], owner: [String:Any], state: [String:Any]) throws -> [String:Any] {
        guard entry["authorization"] == nil, owner["manager"] as? Bool == true, entry["signer"] as? String == owner["device"] as? String else { throw RelayError.invalid("invalid admission grant") }
        try Self.verify(entry,key:owner["signing_key"] as? String ?? "");let g = try Self.unpack(entry)
        guard g["version"] as? Int == 1, g["purpose"] as? String == "common-relay/admission/v1", g["mode"] as? String == "auto", g["app"] as? String == state["app"] as? String, g["group"] as? String == state["group"] as? String, let revision = g["anchor_revision"] as? Int, revision >= 1, revision <= (state["revision"] as? Int ?? 0), (g["expires"] as? Int ?? 0) > 0 else { throw RelayError.invalid("admission grant scope") }
        for field in ["invitation","secret_hash","delegate_key","anchor_hash"] {
            guard let text = g[field] as? String, text.count == (field == "invitation" ? 32 : 64), text.allSatisfy({"0123456789abcdef".contains($0)}) else { throw RelayError.invalid("admission grant encoding") }
        };return g
    }
    private func advanceAuto(_ current: [String:Any], _ entry: [String:Any], _ old: [String:Any], _ next: [String:Any], _ actor: [String:Any]) throws {
        guard let authorization = entry["authorization"] as? [String:Any] else { throw RelayError.invalid("admission grant") }
        let grant = try validateGrant(authorization,owner:actor,state:old);try Self.verify(entry,key:grant["delegate_key"] as? String ?? "")
        guard let before = old["members"] as? [[String:Any]], let after = next["members"] as? [[String:Any]] else { throw RelayError.invalid("membership") }
        let added = after.filter { m in !before.contains(where: {$0["device"] as? String == m["device"] as? String}) }
        guard next["closed"] as? Bool != true, next["invitation"] as? String == grant["invitation"] as? String, let hash = next["request_hash"] as? String, hash.count == 64, hash.allSatisfy({"0123456789abcdef".contains($0)}), after.count == before.count+1, added.count == 1, added[0]["manager"] as? Bool == false, before.allSatisfy({m in after.contains(where: {NSDictionary(dictionary:$0).isEqual(to:m)})}) else { throw RelayError.invalid("invalid automatic admission") }
        if old["revision"] as? Int == grant["anchor_revision"] as? Int { guard Self.digest(try Self.payload(current)) == grant["anchor_hash"] as? String else { throw RelayError.invalid("admission anchor mismatch") } }
    }
    private func invitationGrant(_ inv: [String:Any]) throws -> [String:Any] {
        guard let e = inv["grant"] as? [String:Any], let manager = inv["manager"] as? [String:Any], let secret = inv["secret"] as? String, let delegate = inv["delegate_secret"] as? String else { throw RelayError.invalid("invitation grant missing") }
        let g = try Self.unpack(e)
        _ = try validateGrant(e,owner:manager,state:["app":config["app"] ?? "","group":config["group"] ?? "","revision":g["anchor_revision"] ?? 0])
        let key = try delegateSigner(delegate,device:manager["device"] as? String ?? "").member(name:"")["signing_key"] as? String
        guard g["invitation"] as? String == inv["id"] as? String, g["expires"] as? Int == inv["expires"] as? Int, g["secret_hash"] as? String == Self.digest(Data(secret.utf8)), g["delegate_key"] as? String == key else { throw RelayError.invalid("invitation grant mismatch") };return g
    }
    private func finishAuto(_ pending: [String:Any]) async throws -> Bool {
        guard let inv = pending["invitation"] as? [String:Any], let request = pending["request"] as? [String:Any], let id = inv["id"] as? String, let token = config["token"] as? String,
              let manager = inv["manager"] as? [String:Any], let issuer = manager["device"] as? String, let delegate = inv["delegate_secret"] as? String, let signedGrant = inv["grant"] as? [String:Any] else { throw RelayError.invalid("pending auto join") }
        let grant = try invitationGrant(inv), req = try Self.unpack(request)
        guard let anchor = grant["anchor_revision"] as? Int, let requestedMember = req["member"] as? [String:Any] else { throw RelayError.invalid("admission request") }
        var current: [String:Any]?, after = anchor-1, result: [String:Any] = [:]
        let path = "/enroll/\(id)/auto", auth = "Claim \(token)"
        while true {
            result = try await call("GET",path+"?after=\(after)",authorization:auth)
            guard let entries = result["entries"] as? [[String:Any]], !entries.isEmpty, let latest = result["revision"] as? Int, latest >= anchor, latest <= 4096 else { throw RelayError.invalid("incomplete admission chain") }
            for e in entries {
                if let old = current { current = try advance(old,e) }
                else {
                    let g = try Self.unpack(e)
                    guard Self.digest(try Self.payload(e)) == grant["anchor_hash"] as? String, g["revision"] as? Int == anchor else { throw RelayError.invalid("admission anchor mismatch") }
                    try validate(g);current = e
                }
            }
            guard let tip = current, let revision = try Self.unpack(tip)["revision"] as? Int, revision > after, revision <= latest else { throw RelayError.invalid("admission revision") }
            after = revision;if after == latest { break }
        }
        guard let current else { throw RelayError.invalid("admission chain missing") }
        var e: [String:Any]
        if let approved = result["entry"] as? [String:Any] {
            guard NSDictionary(dictionary:current).isEqual(to:approved) else { throw RelayError.invalid("admission tip mismatch") };e = approved
        } else {
            var g = try Self.unpack(current)
            guard var members = g["members"] as? [[String:Any]], let revision = g["revision"] as? Int else { throw RelayError.invalid("membership") }
            members.append(requestedMember);g["members"] = members;g["revision"] = revision+1;g["previous"] = Self.digest(try Self.payload(current));g["invitation"] = id;g["request_hash"] = Self.digest(try Self.payload(request))
            e = try delegateSigner(delegate,device:issuer).sign(g);e["authorization"] = signedGrant;_ = try advance(current,e)
            var saved = pending;saved["auto_entry"] = e;config["pending_join"] = saved
            let reply = try await call("POST",path,value:e,authorization:auth)
            guard NSDictionary(dictionary:e).isEqual(to:reply) else { throw RelayError.invalid("admission response mismatch") }
        }
        let g = try Self.unpack(e), own = (try Self.unpack(e)["members"] as? [[String:Any]])?.first(where: {$0["device"] as? String == config["device"] as? String})
        guard let authorization = e["authorization"] as? [String:Any], NSDictionary(dictionary:authorization).isEqual(to:signedGrant), g["invitation"] as? String == id, g["request_hash"] as? String == Self.digest(try Self.payload(request)), let own, NSDictionary(dictionary:own).isEqual(to:requestedMember) else { throw RelayError.invalid("automatic approval mismatch") }
        try accept(e);config.removeValue(forKey:"pending_join");return true
    }
    public func approve(_ invitation: [String:Any], request: [String:Any], manager: Bool = false) async throws {
        _ = try await refresh();let j = try Self.unpack(request)
        guard var m = j["member"] as? [String:Any], j["invitation"] as? String == invitation["id"] as? String, j["app"] as? String == config["app"] as? String, j["group"] as? String == config["group"] as? String else { throw RelayError.invalid("join scope") };try Self.verify(request,key:m["signing_key"] as? String ?? "")
        var g = try Self.unpack(config["group_entry"] as? [String:Any] ?? [:]);m["manager"] = manager;var members = (g["members"] as? [[String:Any]] ?? []).filter { $0["device"] as? String != m["device"] as? String };members.append(m);g["members"] = members;g["invitation"] = invitation["id"];g["request_hash"] = Self.digest(try Self.payload(request));try await change(g)
    }
    public func remove(device: String) async throws {
        guard device != config["device"] as? String else { throw RelayError.invalid("use exit for yourself") }
        _ = try await refresh();var g = try Self.unpack(config["group_entry"] as? [String:Any] ?? [:]);g["members"] = (g["members"] as? [[String:Any]] ?? []).filter {$0["device"] as? String != device};g["invitation"] = "";g["request_hash"] = "";try await change(g)
    }
    public func rename(device: String, name: String) async throws {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...128).contains(name.utf8.count) else { throw RelayError.invalid("name required") }
        _ = try await refresh();var g = try Self.unpack(config["group_entry"] as? [String:Any] ?? [:]);var members = g["members"] as? [[String:Any]] ?? []
        guard let index = members.firstIndex(where: {$0["device"] as? String == device}) else { throw RelayError.invalid("member not found") }
        if members[index]["name"] as? String == name { return };members[index]["name"] = name;g["members"] = members;g["invitation"] = "";g["request_hash"] = "";try await change(g)
    }
    public func prepareExit(disband: Bool = false) async throws {
        if config["pending_exit"] != nil { return }
        _ = try await refresh();guard let old = config["group_entry"] as? [String:Any] else { throw RelayError.invalid("group") }
        var g = try Self.unpack(old);let members = g["members"] as? [[String:Any]] ?? []
        guard let own = members.first(where: {$0["device"] as? String == config["device"] as? String}), !disband || own["manager"] as? Bool == true else { throw RelayError.invalid("manager permission") }
        let after = disband ? [] : members.filter {$0["device"] as? String != config["device"] as? String}
        g["members"] = after;if after.isEmpty { g["closed"] = true }
        g["invitation"] = "";g["request_hash"] = "";g["revision"] = (g["revision"] as? Int ?? 0)+1;g["previous"] = Self.digest(try Self.payload(old))
        let e = try sign(g);_ = try advance(old,e);config["pending_exit"] = e
    }
    public func exit() async throws {
        guard let e = config["pending_exit"] as? [String:Any] else { throw RelayError.invalid("prepare exit first") }
        do { _ = try await call("POST","/group/exit",value:e) } catch { if String(describing:error).contains("409") { config.removeValue(forKey:"pending_exit") };throw error };try accept(e);config.removeValue(forKey:"pending_exit")
    }
    public func cancel(_ invitation: [String:Any]) async throws { _ = try await call("DELETE","/group/invitations/\(invitation["id"] as? String ?? "")") }
    private func change(_ state: [String:Any]) async throws {
        guard let old = config["group_entry"] as? [String:Any] else { throw RelayError.invalid("enrollment") };var g = state;g["revision"] = (g["revision"] as? Int ?? 0)+1;g["previous"] = Self.digest(try Self.payload(old));let e = try sign(g);_ = try advance(old,e);_ = try await call("PUT","/group",value:e);try accept(e)
    }
}
private final class GroupRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
