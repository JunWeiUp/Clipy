import AppKit
import Foundation

private func switchCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func switchResponse(_ content: String, finish: String = "stop") -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
}

private final class SwitchHTTPStub: URLProtocol {
    static var status = 200
    static var body = Data()
    static var error: Error?
    static var declaredSize: Int?
    static var capturedRequest: URLRequest?
    static var capturedBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                Self.capturedBody.append(contentsOf: buffer.prefix(count))
            }
        }
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let headers = Self.declaredSize.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ControlledSwitchResolver: SmartSwitchResolving {
    var pending: [String: CheckedContinuation<SmartSwitchResolution, Error>] = [:]
    func resolve(text: String, targets: [SmartSwitchTarget]) async throws -> SmartSwitchResolution {
        try await withCheckedThrowingContinuation { pending[text] = $0 }
    }
    func complete(_ query: String, _ result: SmartSwitchResolution) {
        pending.removeValue(forKey: query)!.resume(returning: result)
    }
}

private final class SwitchInputSourcesFixture: SmartSwitchInputSources {
    var currentID: String? = "ABC"
    var available = true
    func select(_ id: String) -> Bool {
        guard available else { return false }
        currentID = id
        return true
    }
}

@MainActor
private final class ControlledSwitchLauncher: SmartSwitchLaunching {
    var activations: [UUID] = []
    var delay = false
    var pending: CheckedContinuation<Void, Never>?
    func prepare(_ target: SmartSwitchTarget) async throws -> () -> Bool {
        if delay { await withCheckedContinuation { pending = $0 } }
        return { self.activations.append(target.id); return true }
    }
}

@MainActor
private func switchEventually(_ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
    switchCheck(predicate(), "Smart Switch operation timed out")
}

func runSmartSwitchRegressionTests() {
    runSmartSwitchVoicePolicyTests()
    var finished = false
    Task { @MainActor in
        defer { finished = true }
        runSmartSwitchInputPanelTests()
        runSmartSwitchWindowFocusTests()
        runSmartSwitchEscapePasteTests()
        await runSmartSwitchFocusWarmupTests()
        await runSmartSwitchActionRegressionTests()
        let suite = "clipy.smart-switch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SmartSwitchStore(defaults: defaults)
        switchCheck(!store.voiceConfiguration.enabled && store.voiceConfiguration.trigger == .rightCommand,
                    "Voice routing must be opt-in and default to the configured hold-to-talk key")
        store.voiceConfiguration.enabled = true
        store.voiceConfiguration.trigger = .fn
        let voiceReloaded = SmartSwitchStore(defaults: defaults)
        switchCheck(voiceReloaded.voiceConfiguration.enabled && voiceReloaded.voiceConfiguration.trigger == .fn,
                    "Voice routing preferences did not persist")
        let sources = SwitchInputSourcesFixture()
        let inputSession = SmartSwitchInputSourceSession(sources: sources)
        switchCheck(inputSession.selectDoubao() && sources.currentID == SmartSwitchInputSourceSession.doubaoID, "Doubao input source not selected")
        inputSession.restore()
        switchCheck(sources.currentID == "ABC", "Previous input source not restored")
        _ = inputSession.selectDoubao()
        sources.currentID = "ManualChoice"
        inputSession.restore()
        switchCheck(sources.currentID == "ManualChoice", "Manual input source change overwritten")
        sources.available = false
        switchCheck(!inputSession.selectDoubao(), "Missing Doubao reported success")
        inputSession.restore()
        switchCheck(sources.currentID == "ManualChoice", "Unavailable Doubao changed input source")
        let codex = SmartSwitchTarget(bundleIdentifier: "test.codex", applicationPath: "/private/test/Codex.app", name: "Codex", aliases: "助手", intentDescription: "Review code")
        let browser = SmartSwitchTarget(bundleIdentifier: "test.browser", applicationPath: "/private/test/Browser.app", name: "Browser", aliases: "浏览器、查资料")
        let zcode = SmartSwitchTarget(bundleIdentifier: "test.zcode", applicationPath: "/private/test/ZCode.app", name: "ZCode", aliases: "写代码", intentDescription: "日常开发工具")
        var disabled = SmartSwitchTarget(bundleIdentifier: "test.disabled", applicationPath: "/unused", name: "DISABLED_APP")
        disabled.isEnabled = false
        store.configuration.targets = [codex, browser, zcode, disabled]
        store.configuration.shortcut = nil
        store.configuration.shortcutEnabled = false
        let reloaded = SmartSwitchStore(defaults: defaults)
        switchCheck(reloaded.configuration.shortcut == nil && !reloaded.configuration.shortcutEnabled, "Cleared shortcut revived")
        switchCheck(reloaded.configuration.targets == store.configuration.targets, "App metadata or stable IDs lost")
        switchCheck((try? SmartSwitchAPIService.endpoint("https://api.example.com/custom/v1/"))?.path == "/custom/v1/chat/completions", "Base path lost")
        switchCheck((try? SmartSwitchAPIService.endpoint("http://127.0.0.1:1234/v1")) != nil, "Local service rejected")
        for value in ["", "http://api.example.com/v1", "https://secret@api.example.com/v1", "https://api.example.com/v1?token=secret", "https://api.example.com/v1/chat/completions"] {
            switchCheck((try? SmartSwitchAPIService.endpoint(value)) == nil, "Unsafe or malformed API base accepted")
        }

        var config = store.configuration
        config.baseURL = "https://api.example.com/v1"
        config.model = "fixture-model"
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [SwitchHTTPStub.self]
        let api = SmartSwitchAPIService(configuration: config, apiKey: "fixture-key", session: URLSession(configuration: options))
        func expectError(_ expected: SmartSwitchError) async {
            do {
                _ = try await api.resolve(text: "Codex", targets: config.targets)
                preconditionFailure("Invalid API response was accepted")
            } catch { switchCheck(error as? SmartSwitchError == expected, "Wrong API failure") }
        }
        for (query, target) in [("打开 Codex", codex), ("我想查资料", browser), ("继续写代码", zcode)] {
            SwitchHTTPStub.body = switchResponse("{\"appIds\":[\"\(target.id)\"]}")
            do {
                let result = try await api.resolve(text: query, targets: config.targets)
                switchCheck(result == .matched(target.id), "Valid app selection was lost")
            } catch { preconditionFailure("Fixture request failed: \(error)") }
        }
        let sent = String(decoding: SwitchHTTPStub.capturedBody, as: UTF8.self)
        switchCheck(!sent.contains("/private/test") && !sent.contains("DISABLED_APP") && !sent.contains("fixture-key"), "Request disclosed paths, disabled apps or credentials")
        switchCheck(sent.contains("继续写代码") && sent.contains("日常开发工具"), "Intent metadata not sent")
        switchCheck(SwitchHTTPStub.capturedRequest?.httpMethod == "POST" && SwitchHTTPStub.capturedRequest?.url?.path == "/v1/chat/completions", "Wrong API endpoint")
        switchCheck(SwitchHTTPStub.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Missing API authentication")
        switchCheck(SwitchHTTPStub.capturedRequest?.timeoutInterval == 15, "Missing request deadline")
        SwitchHTTPStub.body = switchResponse("{\"appIds\":[]}")
        let noMatch = try? await api.resolve(text: "天气", targets: config.targets)
        switchCheck(noMatch == .noMatch, "No-match handling")
        SwitchHTTPStub.body = switchResponse("```json\n{\"appIds\":[\"\(codex.id)\",\"\(zcode.id)\"]}\n```")
        let ambiguous = try? await api.resolve(text: "开发", targets: config.targets)
        switchCheck(ambiguous == .ambiguous([codex.id, zcode.id]), "Ambiguity or fenced JSON lost")
        for content in ["not JSON", "{\"appIds\":[\"\(UUID())\"]}", "{\"appIds\":[\"\(disabled.id)\"]}", "{\"command\":\"open whatever\"}"] {
            SwitchHTTPStub.body = switchResponse(content)
            await expectError(.invalidResponse)
        }
        SwitchHTTPStub.body = switchResponse("{\"appIds\":[]}", finish: "length")
        await expectError(.invalidResponse)
        SwitchHTTPStub.status = 401
        await expectError(.http(401))
        SwitchHTTPStub.status = 200
        SwitchHTTPStub.declaredSize = 300_000
        await expectError(.invalidResponse)
        SwitchHTTPStub.declaredSize = nil
        SwitchHTTPStub.error = URLError(.timedOut)
        do { _ = try await api.resolve(text: "Codex", targets: config.targets); preconditionFailure("Timeout ignored") }
        catch { switchCheck((error as? URLError)?.code == .timedOut, "Timeout was not preserved") }
        SwitchHTTPStub.error = nil

        let resolver = ControlledSwitchResolver()
        let launcher = ControlledSwitchLauncher()
        let vm = SmartSwitchViewModel(store: store, launcher: launcher) { _ in resolver }
        var successes = 0
        vm.onSuccess = { successes += 1; vm.close() }
        vm.present()
        vm.query = "old"
        vm.submit()
        await switchEventually { resolver.pending["old"] != nil }
        vm.query = "new"
        vm.submit()
        await switchEventually { resolver.pending["new"] != nil }
        resolver.complete("old", .matched(codex.id))
        resolver.complete("new", .matched(zcode.id))
        await switchEventually { successes == 1 }
        switchCheck(launcher.activations == [zcode.id] && vm.query.isEmpty, "Stale request activated an app or success did not clear input")
        vm.present()
        vm.query = "closed"
        vm.submit()
        await switchEventually { resolver.pending["closed"] != nil }
        vm.close()
        resolver.complete("closed", .matched(codex.id))
        await Task.yield()
        switchCheck(successes == 1, "Closed window still switched apps")
        vm.present()
        vm.query = "ambiguous"
        vm.submit()
        await switchEventually { resolver.pending["ambiguous"] != nil }
        resolver.complete("ambiguous", .ambiguous([codex.id, browser.id]))
        await switchEventually { vm.candidates.count == 2 }
        vm.moveSelection(1)
        switchCheck(vm.selectedID == browser.id, "Arrow selection failed")
        vm.submit()
        await switchEventually { successes == 2 }
        switchCheck(launcher.activations.last == browser.id, "Candidate Return selected wrong app")
        vm.present()
        vm.query = "no match"
        vm.submit()
        await switchEventually { resolver.pending["no match"] != nil }
        resolver.complete("no match", .noMatch)
        await switchEventually { !vm.isBusy }
        switchCheck(vm.query == "no match" && vm.message != nil, "No-match lost input")
        vm.query = "settings changed"
        vm.submit()
        await switchEventually { resolver.pending["settings changed"] != nil }
        store.configuration.targets[0].isEnabled = false
        resolver.complete("settings changed", .matched(codex.id))
        await Task.yield()
        switchCheck(successes == 2, "Changed configuration did not invalidate request")
        launcher.delay = true
        vm.query = "slow launch"
        vm.submit()
        await switchEventually { resolver.pending["slow launch"] != nil }
        resolver.complete("slow launch", .matched(zcode.id))
        await switchEventually { launcher.pending != nil }
        vm.close()
        launcher.pending?.resume()
        launcher.pending = nil
        await Task.yield()
        switchCheck(successes == 2, "Late background launch stole focus after close")

        // Native text handling: committing marked text must not submit the command.
        _ = NSApplication.shared
        let window = EscapeClosingWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = SmartSwitchCommandTextView(frame: window.contentView!.bounds)
        window.contentView = editor
        window.makeFirstResponder(editor)
        var submits = 0
        var escapeContents: [String] = []
        editor.onSubmit = { submits += 1 }
        window.onEscape = { escapeContents.append(editor.string) }
        @MainActor func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        switchCheck(!WindowEscapeKeyHandler.handle(key(53, "\u{1b}"), in: window), "Escape bypassed IME composition")
        switchCheck(escapeContents.isEmpty, "IME cancellation pasted unfinished composition")
        editor.keyDown(with: key(36, "\r"))
        switchCheck(submits == 0, "IME candidate Return submitted the command")
        editor.unmarkText()
        editor.keyDown(with: key(36, "\r"))
        switchCheck(submits == 1, "Committed-text Return did not submit")
        editor.string = "最新语音内容\n保留换行 "
        switchCheck(WindowEscapeKeyHandler.handle(key(53, "\u{1b}"), in: window), "Escape action was not handled")
        switchCheck(escapeContents == [editor.string], "Escape did not capture the native editor's latest text")
        let repeatEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: true, keyCode: 53)!
        _ = WindowEscapeKeyHandler.handle(repeatEscape, in: window)
        switchCheck(escapeContents.count == 1, "Holding Escape pasted repeatedly")
        window.close()
        switchCheck(escapeContents.count == 1, "Ordinary window close invoked Escape paste")

        // Bundle-ID lookup recovers a moved app and refuses a different app at the old path.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-app-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = root.appendingPathComponent("Moved.app")
        try! FileManager.default.createDirectory(at: moved.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": zcode.bundleIdentifier, "CFBundleName": "Moved", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: moved.appendingPathComponent("Contents/Info.plist"))
        try! Data("fixture".utf8).write(to: moved.appendingPathComponent("Contents/MacOS/Fixture"))
        switchCheck((try? SmartSwitchApplicationLauncher.applicationURL(for: zcode, lookup: { _ in moved })) == moved, "Moved application not recovered")
        switchCheck((try? SmartSwitchApplicationLauncher.applicationURL(for: codex, lookup: { _ in moved })) == nil, "Wrong bundle ID was accepted")
        print("Smart Switch regression tests passed")
    }
    let deadline = Date().addingTimeInterval(30)
    while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    switchCheck(finished, "Smart Switch regression suite timed out")
}
