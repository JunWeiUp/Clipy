import AppKit

enum SmartSwitchAction: String, Codable, CaseIterable, Identifiable {
    case automatic, openApplication, zcodeNewChat, openCodex, webSearch, translate
    var id: String { rawValue }
    var title: String { SmartActionL10n.title(self) }
    var icon: String {
        switch self {
        case .automatic: return "sparkles"
        case .openApplication: return "app.badge"
        case .zcodeNewChat: return "plus.bubble"
        case .openCodex: return "terminal"
        case .webSearch: return "globe"
        case .translate: return "character.bubble"
        }
    }
    var acceptsEmptyInput: Bool {
        [.zcodeNewChat, .openCodex].contains(self)
    }

    static func migrated(_ rawValue: String) -> SmartSwitchAction? {
        rawValue == "zcodeSendText" ? .zcodeNewChat : Self(rawValue: rawValue)
    }
}

enum SmartSwitchSearchEngine: String, Codable, CaseIterable {
    case bing, google, duckDuckGo
    var title: String { switch self { case .bing: return "Bing"; case .google: return "Google"; case .duckDuckGo: return "DuckDuckGo" } }
    func url(query: String) -> URL {
        let base: String
        switch self { case .bing: base = "https://www.bing.com/search"; case .google: base = "https://www.google.com/search"; case .duckDuckGo: base = "https://duckduckgo.com/" }
        var parts = URLComponents(string: base)!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}

struct SmartSwitchIntent: Equatable {
    var action: SmartSwitchAction
    var text = ""
    var language = ""
    var appIDs: [UUID] = []
}

/// Explicit launch commands are resolved locally before any model call.
enum SmartSwitchDirectIntent {
    static func resolve(_ text: String, targets: [SmartSwitchTarget]) -> SmartSwitchIntent? {
        let normalized = text.lowercased().replacingOccurrences(of: "z code", with: "zcode")
        guard let verb = normalized.range(of: #"打开|启动|切换到|切到|\bopen\s+|\blaunch\s+|\bswitch to\s+"#, options: .regularExpression) else { return nil }
        let prefix = String(normalized[..<verb.lowerBound])
        if prefix.range(of: #"不要|不用|不想|无需|不需要|(?<!特)别|\bdon't\b|\bdo not\b|\bnever\b"#, options: .regularExpression) != nil { return SmartSwitchIntent(action: .automatic) }
        if ["翻译", "润色", "解释", "这句话", "translate", "rewrite"].contains(where: prefix.contains) { return nil }
        let tail = String(normalized[verb.upperBound...])
        let hasNewChat = ["新对话", "新建对话", "新会话", "新聊天", "新建任务", "无项目", "不带项目", "不在项目", "projectless", "new chat", "new conversation"].contains(where: tail.contains)
            || tail.range(of: #"(?:新建|新开|开启|开始)(?:一个|个)?(?:对话|会话|聊天|任务)"#, options: .regularExpression) != nil
        let newChat = hasNewChat && tail.range(of: #"(?:不要|不用|别|无需|不需要|do not|don't).{0,8}(?:新建|新开|新对话|新会话|new chat)"#, options: .regularExpression) == nil
        if tail.contains("zcode"), newChat {
            // A body-bearing command needs the action resolver to preserve its text.
            if ["内容是", "帮我", "问它", "输入", "提问", "about", "ask"].contains(where: tail.contains) { return nil }
            return SmartSwitchIntent(action: .zcodeNewChat)
        }
        var matches: [(SmartSwitchTarget, Int)] = []
        for target in targets where target.isEnabled {
            let names = [target.name] + target.aliases.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n|"))
            let length = names.compactMap { value -> Int? in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "z code", with: "zcode")
                guard !name.isEmpty else { return nil }
                let pattern = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: name) + "(?![a-z0-9])"
                return tail.range(of: pattern, options: .regularExpression) == nil ? nil : name.count
            }.max()
            if let length { matches.append((target, length)) }
        }
        guard let longest = matches.map(\.1).max() else {
            return tail.range(of: "(?<![a-z0-9])codex(?![a-z0-9])", options: .regularExpression) != nil
                ? SmartSwitchIntent(action: .openCodex) : nil
        }
        let chosen = matches.filter { $0.1 == longest }.map(\.0)
        if newChat, chosen.count == 1, chosen[0].bundleIdentifier == "dev.zcode.app" {
            if ["内容是", "帮我", "问它", "输入", "提问", "about", "ask"].contains(where: tail.contains) { return nil }
            return SmartSwitchIntent(action: .zcodeNewChat)
        }
        let compound = tail.range(of: "和|以及|、|\\band\\b", options: .regularExpression) != nil
        return SmartSwitchIntent(action: .openApplication, appIDs: compound ? matches.map { $0.0.id } : chosen.map(\.id))
    }
}

/// Wheel input selects only; it never executes an action or sends text.
struct SmartSwitchWheelSelection {
    private var accumulated: Double = 0
    private var lastStep: TimeInterval = -.infinity
    private var lastEvent: TimeInterval = -.infinity
    mutating func step(delta: Double, precise: Bool, momentum: Bool, time: TimeInterval) -> Int? {
        guard !momentum, delta.isFinite, delta != 0 else { return nil }
        if time - lastEvent > 0.5 { accumulated = 0 }
        lastEvent = time
        guard time - lastStep >= 0.12 else { return nil }
        if precise {
            if accumulated * delta < 0 { accumulated = 0 }
            accumulated += delta
            guard abs(accumulated) >= 18 else { return nil }
        }
        let direction = delta > 0 ? -1 : 1
        accumulated = 0
        lastStep = time
        return direction
    }
    static func next(_ selected: SmartSwitchAction, in actions: [SmartSwitchAction], delta: Int) -> SmartSwitchAction {
        guard !actions.isEmpty else { return .automatic }
        let index = actions.firstIndex(of: selected) ?? 0
        return actions[((index + delta) % actions.count + actions.count) % actions.count]
    }
}

enum SmartActionL10n {
    static func t(_ chinese: String, _ english: String) -> String {
        // Use the same application-language decision as the existing UI.
        PreferencesManager.shared.appLanguage == .zh ? chinese : english
    }
    static func title(_ action: SmartSwitchAction) -> String {
        switch action {
        case .automatic: return t("智能识别", "Smart")
        case .openApplication: return t("打开应用", "Open app")
        case .zcodeNewChat: return t("ZCode 新对话", "New ZCode chat")
        case .openCodex: return t("打开 Codex", "Open Codex")
        case .webSearch: return t("搜索网页", "Search web")
        case .translate: return t("翻译", "Translate")
        }
    }
}
