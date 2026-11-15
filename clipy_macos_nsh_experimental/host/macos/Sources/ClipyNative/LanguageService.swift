import Foundation
import Security

final class RejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
@MainActor final class LanguageService {
    let account:String
    let service = "dev.clipy.tsx.experimental.model"
    var config:[String:Any] = [:]
    var session:URLSession?
    init(account:String) { self.account = account;var item:CFTypeRef?;let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true];if SecItemCopyMatching(q as CFDictionary,&item) == errSecSuccess,let data = item as? Data,let c = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] { config = c } }
    func endpoint(_ raw:String) throws -> URL {
        guard let c = URLComponents(string:raw),let host = c.host,!host.isEmpty,c.user == nil,c.password == nil,c.fragment == nil,c.query == nil,c.scheme?.lowercased() == "https" || (c.scheme?.lowercased() == "http" && ["localhost","127.0.0.1","::1","[::1]"].contains(host.lowercased())) else { throw BridgeFailure(code:"INVALID_URL",message:"使用 HTTPS 接口，HTTP 仅限本机回环") }
        var c2 = c;c2.scheme = c.scheme?.lowercased();c2.host = host.lowercased();if c2.port == (c2.scheme == "https" ? 443:80) { c2.port = nil };var path = c.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"));if path.isEmpty { path = "v1" };if !path.hasSuffix("chat/completions") { path += "/chat/completions" };c2.path = "/"+path;return c2.url!
    }
    func storedKey(for target:URL) -> String? {
        guard let raw = config["endpoint"] as? String,let stored = try? endpoint(raw),stored.absoluteString == target.absoluteString else { return nil };return config["key"] as? String
    }
    func persist() throws {
        let data = try JSONSerialization.data(withJSONObject:config);let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let result = SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result == errSecItemNotFound { var add = q;add[kSecValueData as String] = data;add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw BridgeFailure(code:"KEYCHAIN",message:"无法安全保存 API 配置") } }
        else if result != errSecSuccess { throw BridgeFailure(code:"KEYCHAIN",message:"无法更新 API 配置") }
    }
    func fetch(_ request:URLRequest,limit:Int=1024*1024) async throws -> [String:Any] {
        session?.invalidateAndCancel();let active = URLSession(configuration:.ephemeral,delegate:RejectRedirect(),delegateQueue:nil);session = active;defer { active.invalidateAndCancel();if session === active { session = nil } }
        let (bytes,response) = try await active.bytes(for:request);guard let http = response as? HTTPURLResponse,(200...299).contains(http.statusCode) else { throw BridgeFailure(code:"HTTP_ERROR",message:"接口请求失败，HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        var data = Data();for try await byte in bytes { data.append(byte);if data.count > limit { throw BridgeFailure(code:"TOO_LARGE",message:"接口响应超过限制") } };guard let result = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw BridgeFailure(code:"INVALID_RESPONSE",message:"接口返回格式无效") };return result
    }
    func invoke(_ method:String,_ p:[String:Any]) async throws -> Any {
        switch method {
        case "model.testCleanup":
            guard CommandLine.arguments.contains("--allow-local-relay-test"),(account.contains("/T/clipy-") || account.hasPrefix("/tmp/clipy-")) else { throw BridgeFailure(code:"UNSUPPORTED",message:"仅允许隔离测试清理") }
            let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account];SecItemDelete(q as CFDictionary);config = [:];return true
        case "model.configure":
            guard let raw = p["endpoint"] as? String else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"请填写接口地址") };let target = try endpoint(raw)
            let previousKey = storedKey(for:target)
            config["endpoint"] = raw;config["model"] = p["model"] as? String ?? ""
            if let key = p["key"] as? String { config["key"] = key } else { config["key"] = previousKey }
            try persist();return ["saved":true,"hasKey":(config["key"] as? String)?.isEmpty == false]
        case "model.status":return ["endpoint":config["endpoint"] ?? "","model":config["model"] ?? "","hasKey":(config["key"] as? String)?.isEmpty == false]
        case "model.cancel":session?.invalidateAndCancel();session = nil;return true
        case "model.translate","model.models":
            guard let raw = p["endpoint"] as? String ?? config["endpoint"] as? String else { throw BridgeFailure(code:"NOT_CONFIGURED",message:"请先配置模型接口") };let base = try endpoint(raw);var url = base
            if method == "model.models" { url = base.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models") }
            var req = URLRequest(url:url);req.timeoutInterval = 60;if let key = p["key"] as? String ?? storedKey(for:base),!key.isEmpty { req.setValue("Bearer "+key,forHTTPHeaderField:"Authorization") }
            if method == "model.models" { let result = try await fetch(req);return (result["data"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }.sorted() }
            guard let text = p["text"] as? String,(1...10000).contains(text.count),let model = p["model"] as? String ?? config["model"] as? String,!model.isEmpty else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"请填写模型及 1–10,000 字文本") }
            req.httpMethod = "POST";req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody = try JSONSerialization.data(withJSONObject:["model":model,"messages":[["role":"system","content":"Translate the following text into \(p["target"] as? String ?? "简体中文"). Preserve paragraphs. Return only the translation."],["role":"user","content":text]],"stream":false])
            let result = try await fetch(req);guard let choices = result["choices"] as? [[String:Any]],let message = choices.first?["message"] as? [String:Any],let content = message["content"] as? String else { throw BridgeFailure(code:"INVALID_RESPONSE",message:"模型未返回译文") };return ["text":content]
        case "lookup.query":
            guard let text = p["text"] as? String,(1...500).contains(text.count) else { throw BridgeFailure(code:"INVALID_ARGUMENT",message:"请输入 1–500 字") }
            var c = URLComponents(string:"https://dict.youdao.com/jsonapi")!;c.queryItems = [URLQueryItem(name:"q",value:text),URLQueryItem(name:"dicts",value:"{\"count\":10,\"dicts\":[[\"ec\",\"web_trans\",\"fanyi\"]]}")]
            var req = URLRequest(url:c.url!);req.timeoutInterval = 20;let raw = try await fetch(req,limit:2*1024*1024)
            let ec = raw["ec"] as? [String:Any],words = ec?["word"] as? [[String:Any]],word = words?.first
            let meanings = (word?["trs"] as? [[String:Any]] ?? []).flatMap { ($0["tr"] as? [[String:Any]] ?? []).flatMap { ($0["l"] as? [String:Any])?["i"] as? [String] ?? [] } }
            let translation = (raw["fanyi"] as? [String:Any])?["tran"] as? String ?? ""
            return ["word":text,"phonetic":word?["usphone"] ?? "","meanings":meanings,"translation":translation,"raw":raw]
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"尚未实现语言能力")
        }
    }
}
