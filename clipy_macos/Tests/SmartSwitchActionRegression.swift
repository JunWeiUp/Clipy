import AppKit
import Foundation

private func actionResponse(_ content: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
}

private final class ActionHTTPStub: URLProtocol {
    static var response = actionResponse("unused")
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                Self.body.append(contentsOf: buffer.prefix(count))
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ActionResolverFixture: SmartSwitchResolving {
    var intent = SmartSwitchIntent(action: .automatic)
    var delayed = false
    var pending: CheckedContinuation<String, Error>?
    func resolve(text: String, targets: [SmartSwitchTarget]) async throws -> SmartSwitchResolution { .noMatch }
    func resolveIntent(text: String, configuration: SmartSwitchConfiguration) async throws -> SmartSwitchIntent { intent }
    func rewrite(text: String, action: SmartSwitchAction, language: String) async throws -> String {
        if delayed { return try await withCheckedThrowingContinuation { pending = $0 } }
        return "processed: " + text
    }
}

@MainActor
private final class ActionLauncherFixture: SmartSwitchLaunching {
    var activations: [UUID] = []
    func prepare(_ target: SmartSwitchTarget) async throws -> () -> Bool {
        { self.activations.append(target.id); return true }
    }
}

@MainActor
private final class ActionExecutorFixture: SmartSwitchActionExecuting {
    var performed: [SmartSwitchIntent] = []
    var delayed = false
    var pending: CheckedContinuation<Void, Never>?
    func perform(_ intent: SmartSwitchIntent, configuration: SmartSwitchConfiguration,
                 canContinue: @escaping () -> Bool, willActivate: @escaping () -> Void) async throws {
        if delayed { await withCheckedContinuation { pending = $0 } }
        try Task.checkCancellation()
        guard canContinue() else { throw CancellationError() }
        willActivate()
        performed.append(intent)
    }
}

@MainActor
private final class ActionZCodeFixture: SmartSwitchZCodeOpening {
    var drafts: [String] = []
    var fail = false
    func openNewChat(text: String, canContinue: @escaping () -> Bool,
                     willActivate: @escaping () -> Void) async throws {
        guard canContinue() else { throw CancellationError() }
        if fail { throw SmartSwitchActionError.message("fixture could not insert the draft") }
        willActivate()
        drafts.append(text)
    }
}

@MainActor
func runSmartSwitchActionRegressionTests() async {
    func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Action operation timed out")
    }
    let zcode = SmartSwitchTarget(bundleIdentifier: "dev.zcode.app", applicationPath: "/private/apps/ZCode.app", name: "ZCode", aliases: "字扣")
    for placeholder in ["", "\n", "\r\n", "\n\n"] {
        check(SmartSwitchZCode.isEmptyEditorValue(placeholder), "ZCode's empty paragraph was mistaken for an existing draft")
    }
    for draft in [" ", "\t", "\n真实草稿", "code\n"] {
        check(!SmartSwitchZCode.isEmptyEditorValue(draft), "An existing ZCode draft could be overwritten")
    }
    let chrome = SmartSwitchTarget(bundleIdentifier: "test.chrome", applicationPath: "/private/apps/Chrome.app", name: "Chrome", aliases: "浏览器、查资料")
    let beta = SmartSwitchTarget(bundleIdentifier: "test.beta", applicationPath: "/private/apps/Beta.app", name: "Chrome Beta", aliases: "浏览器")
    let apps = [zcode, chrome, beta]
    for command in ["帮我打开 ZCode 软件", "现在请启动字扣", "open z code"] {
        check(SmartSwitchDirectIntent.resolve(command, targets: apps)?.appIDs == [zcode.id], "Explicit launch did not resolve locally")
    }
    check(SmartSwitchDirectIntent.resolve("打开 Chrome Beta", targets: apps)?.appIDs == [beta.id], "Longer exact name lost to a prefix")
    check(Set(SmartSwitchDirectIntent.resolve("打开浏览器", targets: apps)?.appIDs ?? []) == Set([chrome.id, beta.id]), "Ambiguous alias launched an arbitrary app")
    check(Set(SmartSwitchDirectIntent.resolve("打开Chrome和ZCode", targets: apps)?.appIDs ?? []) == Set([chrome.id, zcode.id]), "Multiple app names silently discarded one target")
    for command in ["不要打开ZCode", "别帮我打开Chrome", "do not open Chrome"] {
        check(SmartSwitchDirectIntent.resolve(command, targets: apps)?.action == .automatic, "Negated launch was not rejected before model inference")
    }
    check(SmartSwitchDirectIntent.resolve("翻译这句话：打开ZCode", targets: apps) == nil, "Quoted launch bypassed the requested text action")
    for command in ["打开 ZCode 新建无项目对话", "打开字扣新建一个对话", "open ZCode new chat"] {
        check(SmartSwitchDirectIntent.resolve(command, targets: apps)?.action == .zcodeNewChat, "Compound new-chat request was reduced to an app switch")
    }
    check(SmartSwitchDirectIntent.resolve("打开ZCode新建一个项目", targets: apps)?.action == .openApplication, "A new project was mistaken for a projectless chat")
    check(SmartSwitchDirectIntent.resolve("打开ZCode，但不要新建对话", targets: apps)?.action == .openApplication, "Negated new-chat operation was executed")
    check(SmartSwitchDirectIntent.resolve("打开ZCode新建对话，帮我写一封信", targets: apps) == nil, "Body-bearing request lost its content")

    var config = SmartSwitchConfiguration()
    config.baseURL = "https://api.example.com/v1"; config.model = "fixture"; config.targets = apps
    config.shortcut = nil
    var old = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    for key in ["actionOrder", "hiddenActions", "favorites", "searchEngine", "translationLanguage"] { old.removeValue(forKey: key) }
    let migrated = try! JSONDecoder().decode(SmartSwitchConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    check(migrated.baseURL == config.baseURL && migrated.targets == apps && migrated.shortcut == nil,
          "Action migration changed API/apps or revived a cleared hotkey")
    check(migrated.availableActions == SmartSwitchAction.allCases, "Legacy configuration did not receive default actions")
    check(migrated.searchEngine == .google && SmartSwitchConfiguration().searchEngine == .google,
          "New or legacy settings without a search engine did not default to Google")
    old["actionOrder"] = ["futureAction", "zcodeSendText", "zcodeNewChat", "polish", "automatic"]
    old["hiddenActions"] = ["translate", "openApplication"]
    old["favorites"] = [["name": "retired fixture", "destinations": [["url": "https://private.example.com/path"]]]]
    let future = try! JSONDecoder().decode(SmartSwitchConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    check(future.availableActions.first == .zcodeNewChat && Set(future.availableActions).count == future.availableActions.count,
          "Unknown/duplicate action IDs broke preference migration")

    var wheel = SmartSwitchWheelSelection()
    check(wheel.step(delta: -1, precise: false, momentum: false, time: 1) == 1, "Wheel notch did not select next action")
    check(wheel.step(delta: -1, precise: false, momentum: false, time: 1.01) == nil, "Wheel burst skipped several actions")
    check(wheel.step(delta: -100, precise: true, momentum: true, time: 2) == nil, "Momentum changed the selected action")
    check(wheel.step(delta: -10, precise: true, momentum: false, time: 3) == nil, "Small trackpad movement triggered an action")
    check(wheel.step(delta: -10, precise: true, momentum: false, time: 3.05) == 1, "Precise wheel deltas did not accumulate")
    check(SmartSwitchWheelSelection.next(.automatic, in: [.automatic, .translate], delta: -1) == .translate, "Reverse cycling did not wrap")
    check(SmartSwitchWheelSelection.next(.translate, in: [.automatic, .translate], delta: 1) == .automatic, "Forward cycling did not wrap")
    check(SmartSwitchWheelSelection.next(.openCodex, in: [], delta: 1) == .automatic, "Empty action list crashed")
    let encodedSearch = SmartSwitchSearchEngine.bing.url(query: "中文 & q=other # fragment")
    check(URLComponents(url: encodedSearch, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: "中文 & q=other # fragment")], "Search query changed URL structure")
    check(SmartSwitchSearchEngine.google.url(query: "C++").absoluteString.contains("C%2B%2B"), "Search engine interpreted plus signs as spaces")

    let valid = actionResponse("{\"action\":\"zcodeNewChat\",\"text\":\"完整正文\",\"appIds\":[],\"favoriteIds\":[]}")
    let intent = try! SmartSwitchAPIService.parseIntent(valid, configuration: config)
    check(intent.action == .zcodeNewChat && intent.text == "完整正文", "Action parser lost the body")
    let newChatIntent = try! SmartSwitchAPIService.parseIntent(
        actionResponse("{\"action\":\"zcodeNewChat\",\"text\":\"请解释 async/await\"}"), configuration: config)
    check(newChatIntent.text == "请解释 async/await", "New-chat model response lost its requested draft")
    for invalid in [
        "{\"action\":\"shell\",\"text\":\"run command\"}",
        "{\"action\":\"openApplication\",\"appIds\":[\"\(UUID())\"]}",
        "{\"action\":\"openFavorite\",\"favoriteIds\":[\"\(UUID())\"]}",
        "{\"action\":\"translate\",\"appIds\":[\"\(zcode.id)\"]}", "not JSON"
    ] {
        check((try? SmartSwitchAPIService.parseIntent(actionResponse(invalid), configuration: config)) == nil, "Unregistered action/ID or malformed response accepted")
    }
    for retired in ["historySearch", "snippetSearch", "screenshotOCR", "openFavorite", "polish", "zcodeSendText"] {
        check((try? SmartSwitchAPIService.parseIntent(actionResponse("{\"action\":\"\(retired)\"}"), configuration: config)) == nil,
              "A removed action could still execute through model output")
    }
    check(Set(future.availableActions) == Set(SmartSwitchAction.allCases) && future.availableActions.count == 6,
          "Legacy hidden/removed actions hid a current button or created duplicates")
    check(SmartSwitchDirectIntent.resolve("打开Codex软件", targets: [])?.action == .openCodex,
          "Built-in Codex launch required model configuration")
    let options = URLSessionConfiguration.ephemeral
    options.protocolClasses = [ActionHTTPStub.self]
    let api = SmartSwitchAPIService(configuration: config, apiKey: "fixture-key", session: URLSession(configuration: options))
    ActionHTTPStub.response = valid
    do {
        let resolved = try await api.resolveIntent(text: "新建无项目对话", configuration: config)
        check(resolved == intent, "Action HTTP request failed")
        let payload = String(decoding: ActionHTTPStub.body, as: UTF8.self)
        check(!payload.contains("/private/apps") && !payload.contains("private.example.com") && !payload.contains("fixture-key"), "Action request disclosed paths, favorite URLs or credentials")
        ActionHTTPStub.response = actionResponse("翻译结果")
        let translated = try await api.rewrite(text: "source", action: .translate, language: "Chinese")
        check(translated == "翻译结果", "Text transformation lost its output")
    } catch { preconditionFailure("Action HTTP fixture failed: \(error)") }

    let suite = "clipy.actions.tests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SmartSwitchStore(defaults: defaults)
    store.configuration = config
    let resolver = ActionResolverFixture(), launcher = ActionLauncherFixture(), executor = ActionExecutorFixture()
    var factoryCalls = 0, successes = 0, paste = ""
    let vm = SmartSwitchViewModel(store: store, launcher: launcher, executor: executor) { _ in factoryCalls += 1; return resolver }
    vm.onSuccess = { successes += 1; vm.close() }
    vm.onPaste = { paste = $0 }
    vm.present(); vm.query = "打开ZCode软件"; vm.submit()
    await eventually { successes == 1 }
    check(factoryCalls == 0 && launcher.activations == [zcode.id], "First-priority launch unnecessarily called the model")
    vm.present(); vm.query = "打开浏览器"; vm.submit()
    await eventually { vm.candidates.count == 2 }
    check(factoryCalls == 0 && launcher.activations.count == 1, "Ambiguous direct match called the model or opened the wrong app")
    vm.close()
    vm.present(); vm.query = "weather tomorrow"; vm.selectAction(.webSearch, execute: true)
    await eventually { successes == 2 }
    check(factoryCalls == 0 && executor.performed.last?.action == .webSearch, "Fixed button needed intent recognition")
    vm.present(); vm.query = "a draft"; vm.selectAction(.translate, execute: true)
    await eventually { vm.output != nil }
    check(vm.output == "processed: a draft", "Translation did not preview its result")
    vm.pasteBack()
    check(paste == vm.output, "Paste-back used the instruction instead of the result")
    vm.useOutputAsInput()
    check(vm.query == "processed: a draft" && vm.output == nil, "Chained text processing lost its input")
    resolver.delayed = true
    vm.query = "old text"; vm.selectAction(.translate, execute: true)
    await eventually { resolver.pending != nil }
    vm.cycleAction(1)
    resolver.pending?.resume(returning: "stale result"); resolver.pending = nil
    await Task.yield()
    check(vm.output == nil && vm.query == "old text", "Wheel selection applied a late text result or lost input")
    resolver.delayed = false

    let callsBeforeLocal = factoryCalls
    vm.present(); vm.selectAction(.openCodex, execute: true)
    await eventually { successes == 3 }
    check(factoryCalls == callsBeforeLocal && executor.performed.last?.action == .openCodex,
          "Open Codex required text or requested model intent")

    executor.delayed = true
    vm.present(); vm.selectAction(.zcodeNewChat, execute: true)
    await eventually { executor.pending != nil }
    vm.close()
    executor.pending?.resume(); executor.pending = nil
    await Task.yield()
    check(successes == 3 && executor.performed.last?.action == .openCodex, "Cancelled external action still activated an app")

    // Exercise the real action executor up to the ZCode UI boundary. Mocking the
    // whole executor missed the old New Chat branch that discarded the draft.
    let zcodeUI = ActionZCodeFixture()
    let realExecutor = SmartSwitchActionExecutor(zcode: zcodeUI)
    var draftSuccesses = 0, draftModelCalls = 0
    let draftVM = SmartSwitchViewModel(store: store, launcher: launcher, executor: realExecutor) { _ in
        draftModelCalls += 1; return resolver
    }
    draftVM.onSuccess = { draftSuccesses += 1; draftVM.close() }
    let cases: [(SmartSwitchAction, String)] = [
        (.zcodeNewChat, "帮我解释这段代码\n\n```swift\nprint(\"你好 👋\")\n```\n"),
        (.zcodeNewChat, ""),
        (.zcodeNewChat, "  keep leading/trailing spaces\n第二行  ")
    ]
    for (index, item) in cases.enumerated() {
        draftVM.present(); draftVM.query = item.1
        draftVM.selectAction(item.0, execute: true)
        await eventually { draftSuccesses == index + 1 }
        check(zcodeUI.drafts.last == item.1, "ZCode button discarded or changed the input before prefill")
    }
    check(draftModelCalls == 0, "ZCode button sent the draft to an intent model")
    resolver.intent = newChatIntent
    draftVM.present(); draftVM.query = "打开 ZCode 新建对话，帮我解释 async/await"; draftVM.submit()
    await eventually { draftSuccesses == cases.count + 1 }
    check(zcodeUI.drafts.last == newChatIntent.text, "Semantic new-chat action lost the extracted body")
    let beforeCancelled = zcodeUI.drafts.count
    do {
        try await realExecutor.perform(newChatIntent, configuration: config, canContinue: { false }, willActivate: {})
        preconditionFailure("Cancelled prefill still reached the UI")
    } catch is CancellationError {} catch { preconditionFailure("Wrong cancellation error") }
    check(zcodeUI.drafts.count == beforeCancelled, "Cancelled prefill opened a ZCode draft")
    zcodeUI.fail = true
    draftVM.present(); draftVM.query = "保留这份草稿"; draftVM.selectAction(.zcodeNewChat, execute: true)
    await eventually { draftVM.message != nil && !draftVM.isBusy }
    check(draftVM.query == "保留这份草稿" && draftSuccesses == cases.count + 1,
          "A failed prefill cleared the input or reported success")
    let appRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-codex-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: appRoot) }
    let codexApp = appRoot.appendingPathComponent("Codex.app")
    do {
        try FileManager.default.createDirectory(at: codexApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": SmartSwitchActionExecutor.codexBundleIdentifier,
            "CFBundleExecutable": "Codex", "CFBundleName": "Codex", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: codexApp.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: codexApp.appendingPathComponent("Contents/MacOS/Codex"))
        let codexLauncher = ActionLauncherFixture()
        let codexExecutor = SmartSwitchActionExecutor(applicationLauncher: codexLauncher, codexURL: { codexApp })
        var activations = 0
        try await codexExecutor.perform(.init(action: .openCodex), configuration: config,
                                       canContinue: { true }, willActivate: { activations += 1 })
        check(codexLauncher.activations.count == 1 && activations == 1, "Codex button did not activate its installed bundle")
        var checks = 0
        do {
            try await codexExecutor.perform(.init(action: .openCodex), configuration: config,
                canContinue: { checks += 1; return checks == 1 }, willActivate: { activations += 1 })
            preconditionFailure("Cancelled Codex launch activated after preparation")
        } catch is CancellationError {}
        check(codexLauncher.activations.count == 1 && activations == 1, "Late Codex preparation stole focus")
        do {
            try await SmartSwitchActionExecutor(codexURL: { nil }).perform(.init(action: .openCodex), configuration: config,
                canContinue: { true }, willActivate: { preconditionFailure("Missing Codex tried to activate") })
            preconditionFailure("Missing Codex reported success")
        } catch is SmartSwitchActionError {}
    } catch { preconditionFailure("Codex launcher fixture failed: \(error)") }
    print("Smart Switch action regressions passed (six visible actions, removed-action rejection, migration, launch priority, Codex launch, ZCode draft forwarding, translation and cancellation).")
}
