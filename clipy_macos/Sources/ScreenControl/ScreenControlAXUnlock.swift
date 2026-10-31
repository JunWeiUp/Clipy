// Adapted from VibePier (MIT). See LICENSE.VIBEPIER.MIT.
import AppKit
import IOKit.pwr_mgt
import OpenDirectory

/// Fill only a unique writable system secure field; never synthesize credential events.
enum ScreenControlAXUnlock {
    static func submit(_ secret: String) throws {
        guard AXIsProcessTrusted() else { throw ScreenControlUnlockError(stage: "accessibility") }
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        do { try record.verifyPassword(secret) }
        catch { throw ScreenControlUnlockError(stage: "credential") }
        try type(secret)
    }
    private static func locked() -> Bool { ScreenControlManager.locked == true }
    private static func wait(_ seconds: Double, _ done: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return done()
    }
    private static func key(_ code: CGKeyCode) {
        // Non-secret wake/Shift only; credential and Return never use global events.
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
    private static func type(_ password: String) throws {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Clipy screen unlock" as CFString, kIOPMUserActiveLocal, &assertion)
        defer { if assertion != 0 { IOPMAssertionRelease(assertion) } }
        Thread.sleep(forTimeInterval: 1.0)
        guard locked() else { return }
        key(56)  // Dismiss a screen saver; no credential or Return key is posted.
        Thread.sleep(forTimeInterval: 0.5)
        selectCurrentAccountIfNeeded()
        var target: PasswordTarget?
        guard
            wait(
                3,
                {
                    if !locked() { return true }
                    target = passwordInputTarget()
                    return target != nil
                })
        else { throw ScreenControlUnlockError(stage: "secure-field-unavailable") }
        guard locked() else { return }
        guard let target else { throw ScreenControlUnlockError(stage: "secure-field-unavailable") }
        try ScreenControlUnlockSubmission.perform(
            isLocked: { locked() },
            targetStillReady: {
                guard let current = passwordInputTarget() else { return false }
                return CFEqual(current.field, target.field) && CFEqual(current.window, target.window)
            },
            writePassword: {
                let status = AXUIElementSetAttributeValue(
                    target.field, kAXValueAttribute as CFString, password as CFString)
                guard status == .success else {
                    throw ScreenControlUnlockError(stage: "write-secure-field", status: status.rawValue)
                }
            },
            submit: {
                // Writing a nonempty password may create/enable the login button. Re-resolve only
                // within the original secure field/window; never redirect to a new input target.
                guard let current = passwordInputTarget(), CFEqual(current.field, target.field),
                    CFEqual(current.window, target.window)
                else { throw ScreenControlUnlockError(stage: "target-changed-before-confirm") }
                let status = AXUIElementPerformAction(current.submitElement, current.action as CFString)
                guard status == .success else {
                    throw ScreenControlUnlockError(stage: "confirm-secure-field", status: status.rawValue)
                }
            })
    }
    private struct PasswordTarget {
        let field: AXUIElement
        let window: AXUIElement
        let submitElement: AXUIElement
        let action: String
    }
    private static func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, attribute as CFString, &raw) == .success,
            let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }
    private static func supportsAction(_ element: AXUIElement, _ action: String) -> Bool {
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success
            && (actions as? [String])?.contains(action) == true
    }
    /// AX failures stop the operation. Never fall back to Unicode events, paste, scripts or global Return.
    private static func passwordInputTarget() -> PasswordTarget? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard locked(), session?[kCGSessionOnConsoleKey as String] as? Bool == true,
            let login = NSWorkspace.shared.frontmostApplication,
            login.bundleIdentifier == "com.apple.loginwindow",
            login.bundleURL?.path == "/System/Library/CoreServices/loginwindow.app"
        else { return nil }
        let app = AXUIElementCreateApplication(login.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // loginwindow may report its window/application as focused. A complete traversal can still
        // prove a unique secure field without relying on the process-level focus attribute.
        guard let controls = ScreenControlAXTraversal.elements(app, limit: 128, timeout: 0.5) else { return nil }
        let fields = controls.filter { textAttribute($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole }
        guard fields.count == 1, let field = fields.first else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.2)
        var pid: pid_t = 0
        var subrole: CFTypeRef?
        var settable = DarwinBoolean(false)
        guard AXUIElementGetPid(field, &pid) == .success, pid == login.processIdentifier,
            AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success,
            subrole as? String == kAXSecureTextFieldSubrole,
            AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return nil }
        guard let window = element(field, kAXWindowAttribute) else { return nil }
        if let button = element(window, kAXDefaultButtonAttribute),
            AXUIElementGetPid(button, &pid) == .success, pid == login.processIdentifier,
            supportsAction(button, kAXPressAction)
        {
            return PasswordTarget(field: field, window: window, submitElement: button, action: kAXPressAction)
        }
        if let windowControls = ScreenControlAXTraversal.elements(window, limit: 128, timeout: 0.5) {
            let buttons = windowControls.filter {
                textAttribute($0, kAXRoleAttribute) == kAXButtonRole && matchesLoginButton($0)
                    && supportsAction($0, kAXPressAction)
            }
            if buttons.count == 1, let button = buttons.first,
                AXUIElementGetPid(button, &pid) == .success, pid == login.processIdentifier
            {
                return PasswordTarget(field: field, window: window, submitElement: button, action: kAXPressAction)
            }
        }
        if supportsAction(field, kAXConfirmAction) {
            return PasswordTarget(field: field, window: window, submitElement: field, action: kAXConfirmAction)
        }
        return nil
    }
    private static func textAttribute(_ node: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func matchesLoginButton(_ node: AXUIElement) -> Bool {
        let labels: Set<String> = ["log in", "login", "unlock", "登录", "登入", "解锁"]
        return [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
            textAttribute(node, attribute).map {
                labels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            } ?? false
        }
    }
    private static func matchesCurrentAccount(_ node: AXUIElement) -> Bool {
        let names = Set([NSUserName(), NSFullUserName()].filter { !$0.isEmpty })
        return [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
            textAttribute(node, attribute).map { names.contains($0) } ?? false
        }
    }
    /// Some lock screens first show an account chooser. Press only the unique button with this
    /// console account's exact name, and only when no password control is present. No text is entered.
    private static func selectCurrentAccountIfNeeded() {
        guard locked(), let login = NSWorkspace.shared.frontmostApplication,
            login.bundleIdentifier == "com.apple.loginwindow",
            login.bundleURL?.path == "/System/Library/CoreServices/loginwindow.app",
            (CGSessionCopyCurrentDictionary() as? [String: Any])?[kCGSessionOnConsoleKey as String] as? Bool == true
        else { return }
        let app = AXUIElementCreateApplication(login.processIdentifier)
        guard let controls = ScreenControlAXTraversal.elements(app, limit: 128, timeout: 0.5),
            !controls.contains(where: { textAttribute($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole })
        else { return }
        let candidates = controls.filter {
            textAttribute($0, kAXRoleAttribute) == kAXButtonRole && matchesCurrentAccount($0)
                && supportsAction($0, kAXPressAction)
        }
        guard candidates.count == 1, let button = candidates.first, locked(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == login.processIdentifier
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
}
