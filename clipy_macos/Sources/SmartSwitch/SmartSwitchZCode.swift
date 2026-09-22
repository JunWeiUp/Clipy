import AppKit
import ApplicationServices

@MainActor
protocol SmartSwitchZCodeOpening {
    func openNewChat(text: String, canContinue: @escaping () -> Bool,
                     willActivate: @escaping () -> Void) async throws
}

@MainActor
struct SmartSwitchZCodeLauncher: SmartSwitchZCodeOpening {
    func openNewChat(text: String, canContinue: @escaping () -> Bool,
                     willActivate: @escaping () -> Void) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zcode.app") else {
            throw SmartSwitchActionError.message(SmartActionL10n.t("未找到 ZCode，请先安装并打开一次。", "ZCode was not found. Install and open it first."))
        }
        let target = try SmartSwitchTarget.application(at: url)
        let activate = try await SmartSwitchApplicationLauncher().prepare(target)
        try Task.checkCancellation()
        guard canContinue() else { throw CancellationError() }
        willActivate()
        guard activate() else { throw SmartSwitchError.activationFailed }
        try await SmartSwitchZCode.newChat(text: text, canContinue: canContinue)
    }
}

/// ZCode's verified UI flow. No private database writes or guessed URL routes.
@MainActor
enum SmartSwitchZCode {
    private static let queue = DispatchQueue(label: "Clipy.smart-switch-zcode", qos: .userInitiated)

    static func newChat(text: String, canContinue: @escaping () -> Bool) async throws {
        guard AccessibilityManager.isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.zcode.app").first else {
            throw SmartSwitchActionError.message(SmartActionL10n.t("请允许辅助功能，并确认 ZCode 已启动。", "Allow Accessibility and make sure ZCode is running."))
        }
        let pid = app.processIdentifier
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard canContinue() else { throw CancellationError() }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        func check() throws {
            try Task.checkCancellation()
            guard canContinue() else { throw CancellationError() }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw SmartSwitchActionError.message(SmartActionL10n.t("前台应用已变化，已停止新建对话。", "The foreground app changed; chat preparation stopped."))
            }
        }
        try check()
        let root = AXUIElementCreateApplication(pid)
        await ax {
            AXUIElementSetMessagingTimeout(root, 0.08)
            _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let newTask = try await waitFor(root, names: ["新建任务", "New task", "New Task"], role: kAXButtonRole, check: check)
        try check()
        guard await ax({ AXUIElementPerformAction(newTask, kAXPressAction as CFString) == .success }) else { throw unavailable() }

        let pickerNames = ["选择项目", "Select project", "Select Project", "Choose project", "Choose Project", "Choose workspace"]
        let picker = try await waitFor(root, names: pickerNames, role: kAXPopUpButtonRole, check: check)
        try check()
        guard await ax({ AXUIElementPerformAction(picker, kAXPressAction as CFString) == .success }) else { throw unavailable() }
        let noProject = try await waitFor(root, names: ["不在项目中工作", "Work without a project", "Work outside a project", "No project"], role: nil, check: check)
        try check()
        guard await ax({ AXUIElementPerformAction(noProject, kAXPressAction as CFString) == .success }) else { throw unavailable() }
        // The project selector returns to its empty label only in projectless mode.
        _ = try await waitFor(root, names: pickerNames, role: kAXPopUpButtonRole, check: check)
        let editor = try await waitFor(root, names: [], role: kAXTextAreaRole, check: check)
        guard let existing = await ax({ attribute(editor, kAXValueAttribute) as? String }) else { throw unavailable() }
        guard isEmptyEditorValue(existing) else {
            throw SmartSwitchActionError.message(SmartActionL10n.t("ZCode 新对话中已有草稿，已保留。请先处理该草稿后重试。", "ZCode already has a draft. It was preserved; handle it before retrying."))
        }
        try check()
        guard await ax({ AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success }) else { throw unavailable() }
        guard !text.isEmpty else {
            appLog("SmartSwitch ZCode projectless chat ready prefilled=false", level: .debug)
            return
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try check()
        let focused = await ax { attribute(editor, kAXFocusedAttribute) as? Bool == true }
        guard focused else { throw unavailable() }
        // ZCode's rich editor ignores AXValue writes. The normal paste path was
        // verified to update its draft. Never synthesize Return or press Send.
        ClipboardManager.shared.writeToPasteboard(.text(text))
        ClipboardManager.shared.simulatePasteIfTrusted()
        for _ in 0..<20 {
            try check()
            if await ax({ (attribute(editor, kAXValueAttribute) as? String)?.replacingOccurrences(of: "\r\n", with: "\n") == text.replacingOccurrences(of: "\r\n", with: "\n") }) {
                appLog("SmartSwitch ZCode projectless draft verified", level: .debug)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SmartSwitchActionError.message(SmartActionL10n.t("已打开无项目对话，但未确认文字填入；内容已复制，可手动粘贴。", "The projectless chat is open, but text insertion was not confirmed. The text is copied for manual paste."))
    }

    /// Electron's empty contenteditable paragraph exposes a placeholder newline.
    /// Preserve any actual text or spaces; only empty paragraphs count as blank.
    static func isEmptyEditorValue(_ value: String) -> Bool {
        value.trimmingCharacters(in: .newlines).isEmpty
    }

    private static func waitFor(_ root: AXUIElement, names: [String], role: String?, check: () throws -> Void) async throws -> AXUIElement {
        for _ in 0..<15 {
            try check()
            if let element = await ax({ find(root, names: names, role: role) }) { return element }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw unavailable()
    }

    private static func unavailable() -> SmartSwitchActionError {
        .message(SmartActionL10n.t("无法确认 ZCode 的无项目新对话入口。请打开 ZCode，选择“任务 → 新建任务 / 不在项目中工作”后重试。", "Could not confirm ZCode's projectless new-chat controls. Open ZCode and use Tasks → New task / Work without a project, then retry."))
    }

    private static func ax<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: operation()) } }
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private nonisolated static func find(_ root: AXUIElement, names: [String], role: String?) -> AXUIElement? {
        let focused = attribute(root, kAXFocusedWindowAttribute) ?? attribute(root, kAXMainWindowAttribute)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var pending: [AXUIElement]
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() { pending = [unsafeBitCast(focused, to: AXUIElement.self)] }
        else if windows.count == 1 { pending = windows }
        else { return nil }
        var matches: [AXUIElement] = []
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        while let element = pending.popLast(), visited < 1200, ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let currentRole = attribute(element, kAXRoleAttribute) as? String
            if role == nil || currentRole == role {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, "AXHelp"].compactMap { attribute(element, $0) as? String }
                if names.isEmpty || labels.contains(where: names.contains) {
                    var actions: CFArray?
                    AXUIElementCopyActionNames(element, &actions)
                    let clickable = (actions as? [String])?.contains(kAXPressAction) == true
                    if (names.isEmpty || clickable), (attribute(element, kAXEnabledAttribute) as? Bool) != false { matches.append(element) }
                }
            }
            // Existing conversation text is never needed to locate action controls.
            if currentRole == kAXStaticTextRole || currentRole == kAXTextAreaRole { continue }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.reversed())
        }
        // Refuse an ambiguous control rather than clicking another task's button.
        return matches.count == 1 ? matches[0] : nil
    }
}
