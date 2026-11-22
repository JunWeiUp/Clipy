import Foundation
import CommonRelay
import CryptoKit

/// 命令行设备组操作（在本机终端或 SSH 里运行，供无人值守入组使用）：
///
///     ClipyClone.app/Contents/MacOS/ClipyClone --relay-cli status
///     ClipyClone.app/Contents/MacOS/ClipyClone --relay-cli invite [--timeout 600]
///     ClipyClone.app/Contents/MacOS/ClipyClone --relay-cli join <邀请链接> [--name 名称] [--timeout 300] [--access-password-stdin]
///
/// 经 SSH 运行时进程拿不到登录钥匙串（errSecInteractionNotAllowed），请用
/// `open -n -W --stdin 文件 --stdout 文件 --stderr 文件 ClipyClone.app --args --relay-cli …` 在桌面会话里执行。
///
/// 只能从本机命令行触发（不注册链接协议，网页无法调用）。复用界面里同一套
/// SyncRelayGroups 流程与钥匙串条目；运行期间不启动本进程的中继连接，避免用同一设备身份
/// 把界面进程的会话顶掉。完成后需重启界面进程以载入新配置（join 之后必须重启）。
enum SyncRelayCLI {
    static let argument = "--relay-cli"
    nonisolated(unsafe) static var isActive = false

    static func run() -> Never {
        isActive = true
        let args = Array(CommandLine.arguments.drop(while: { $0 != argument }).dropFirst())
        Task { @MainActor in
            var code: Int32 = 1
            do { code = try await dispatch(args) } catch { fputs("错误：\(error)\n", stderr) }
            exit(code)
        }
        dispatchMain()
    }

    private static func option(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 有效访问密码 SHA-256 的前 8 位，只用于核对是否与服务器一致，不泄露密码本身。
    private static func accessFingerprint() -> String {
        guard let pw = try? SyncRelaySettings.effectiveAccessPassword(for: SyncRelaySettings.url), !pw.isEmpty else { return "" }
        return SHA256.hash(data: Data(pw.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func say(_ text: String) {
        print(text)
        fflush(stdout)
    }

    @MainActor
    private static func dispatch(_ args: [String]) async throws -> Int32 {
        let g = SyncRelayGroups()
        switch args.first {
        case "status":
            var refreshError = ""
            do { try await g.refresh() } catch { refreshError = "\(error)" }
            let local = (try? SyncRelayGroups.localSummary()) ?? [:]
            let members = g.members.map { m -> [String: Any] in
                let id = m["device"] as? String ?? ""
                return ["device": id, "name": m["name"] as? String ?? "", "manager": m["manager"] as? Bool ?? false,
                        "online": g.online.contains(id), "self": id == g.device]
            }
            let out: [String: Any] = ["enrolled": g.enrolled, "manager": g.manager, "device": g.device,
                                      "group": g.group, "group_name": g.groupName, "members": members,
                                      "pending_join": !g.pendingCode.isEmpty, "message": g.message,
                                      "relay_url": SyncRelaySettings.url,
                                      "access_password_fingerprint": accessFingerprint(),
                                      "refresh_error": refreshError, "local": local]
            say(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return 0

        case "invite":
            let timeout = Double(option(args, "--timeout") ?? "") ?? 600
            try await g.refresh()
            guard g.enrolled, g.manager else {
                fputs("本机不是设备组管理员，不能发出邀请。\n", stderr)
                return 1
            }
            let before = Set(g.members.compactMap { $0["device"] as? String })
            g.automaticJoin = true
            try await g.createInvitation()
            guard let inv = g.invitation else { throw RelayError.invalid("invitation") }
            say(try SyncRelayGroups.encode(inv))
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try await g.checkRequest()
                let now = Set(g.members.compactMap { $0["device"] as? String })
                if let joined = now.subtracting(before).first {
                    say("已加入：\(joined)")
                    return 0
                }
                // 自动邀请走不通（例如对方用了需批准的旧链接）时，按普通成员批准。
                if g.request != nil {
                    try await g.approve(manager: false)
                }
            }
            try? await g.cancelInvitation()
            fputs("等待超时，邀请已撤销。\n", stderr)
            return 2

        case "join":
            guard args.count >= 2 else {
                fputs("用法：--relay-cli join <邀请链接> [--name 名称]\n", stderr)
                return 64
            }
            let link = args[1]
            let name = option(args, "--name") ?? Host.current().localizedName ?? "Mac"
            let timeout = Double(option(args, "--timeout") ?? "") ?? 300
            if args.contains("--access-password-stdin") {
                // 从标准输入读服务器访问密码，按当前中继地址存入钥匙串（与设置页填写相同）。
                guard let pw = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !pw.isEmpty else {
                    fputs("标准输入里没有访问密码。\n", stderr)
                    return 64
                }
                try SyncRelaySettings.saveInvitationPassword(pw, url: SyncRelaySettings.url)
            }
            try await g.refresh()
            if g.enrolled {
                fputs("本机已在设备组「\(g.groupName)」中；如需换组请先在界面里退出。\n", stderr)
                return 1
            }
            if g.pendingCode.isEmpty {
                try await g.join(text: link, name: name)
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await g.finish()
                if g.enrolled {
                    say("已加入设备组「\(g.groupName)」，设备 \(g.device)")
                    return 0
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            fputs("等待超时：\(g.message)\n", stderr)
            return 2

        case "set-password":
            // 从标准输入读服务器访问密码，按当前中继地址存入钥匙串；输出指纹以便核对。
            guard let pw = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !pw.isEmpty else {
                fputs("标准输入里没有访问密码。\n", stderr)
                return 64
            }
            try SyncRelaySettings.saveInvitationPassword(pw, url: SyncRelaySettings.url)
            say("已保存访问密码，指纹 \(accessFingerprint())")
            return 0

        case "leave-local":
            // 只在本机丢弃已失效的设备组登记（与界面「退出当前组」处理失效组相同，不联系服务器）。
            try await g.clearUnavailableEnrollment()
            say("已清除本机的设备组登记")
            return 0

        case "discard":
            // 丢弃本机未完成的入组申请（与界面「放弃」相同），之后可重新 join。
            try g.discard()
            say("已丢弃未完成的入组申请")
            return 0

        default:
            fputs("用法：--relay-cli status | invite [--timeout 秒] | join <邀请链接> [--name 名称] [--timeout 秒] [--access-password-stdin] | discard | set-password | leave-local\n", stderr)
            return 64
        }
    }
}
