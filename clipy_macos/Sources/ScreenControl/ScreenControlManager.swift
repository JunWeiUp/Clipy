import AppKit
import OpenDirectory

/// Main-thread owner. Observers live only while sync runs. No permanent poller.
final class ScreenControlManager {
    static let shared = ScreenControlManager()
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var attemptGate = ScreenControlAttemptGate()
    private var generation = 0
    var onChange: (() -> Void)?
    static var unlockReady: Bool { AXIsProcessTrusted() }
    static var locked: Bool? {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              (dictionary["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == getuid(),
              dictionary["kCGSSessionOnConsoleKey"] as? Bool == true else { return nil }
        return dictionary["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    var configured: Bool {
        do { return (try ScreenControlSecurity.read("password"))?.isEmpty == false }
        catch {
            appLog("ScreenControl credential unavailable status=\((error as NSError).code)", level: .warning)
            return false
        }
    }
    func start() {
        guard observers.isEmpty else { return }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.onChange?() })
        }
    }
    func stop() {
        generation += 1
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
        onChange = nil
    }
    func configure(password: String) throws {
        guard !busy, Self.locked == false, !password.isEmpty, password.utf8.count <= 1024,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw failure("Invalid password or session") }
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        try record.verifyPassword(password)
        generation += 1
        defer { onChange?() }
        try ScreenControlSecurity.save(Data(password.utf8), account: "password")
        // Retire the old optional control secret; it no longer grants access.
        try? ScreenControlSecurity.save(nil, account: "control-key")
    }
    func disable() throws {
        generation += 1
        defer { onChange?() }
        try ScreenControlSecurity.save(nil, account: "password")
        try? ScreenControlSecurity.save(nil, account: "control-key")
    }
    func perform(_ action: String, completion: @escaping (String) -> Void) {
        let finish: (String) -> Void = { result in
            appLog("ScreenControl action=\(action) result=\(result)")
            completion(result)
        }
        if let result = attemptGate.admit(action: action, configured: configured, busy: busy,
                                           locked: Self.locked, helper: Self.unlockReady) {
            finish(result)
            return
        }
        busy = true
        let capturedGeneration = generation
        let password = action == "unlock" ? (try? ScreenControlSecurity.read("password")) : nil
        DispatchQueue.global(qos: .userInitiated).async {
            var result = "ok"
            if action == "lock" {
                // Native lock shortcut, never a password-bearing event.
                if AXIsProcessTrusted(), let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false) {
                    down.flags = [.maskControl, .maskCommand]; up.flags = down.flags
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                } else { result = "accessibilityRequired" }
            } else if let bytes = password, let secret = String(data: bytes, encoding: .utf8) {
                do { try ScreenControlAXUnlock.submit(secret) }
                catch let error as ScreenControlUnlockError {
                    appLog("ScreenControl AX stage=\(error.stage) status=\(error.status ?? 0)", level: .warning)
                    result = error.result
                } catch {
                    appLog("ScreenControl AX verification failed status=\((error as NSError).code)", level: .warning)
                    result = "credentialUnavailable"
                }
            } else { result = "credentialUnavailable" }
            DispatchQueue.main.async {
                guard result == "ok" else { self.busy = false; finish(result); return }
                self.awaitState(action == "lock", remaining: 20, generation: capturedGeneration, completion: finish)
            }
        }
    }
    private func awaitState(_ target: Bool, remaining: Int, generation: Int, completion: @escaping (String) -> Void) {
        guard self.generation == generation, configured else { busy = false; completion("cancelled"); return }
        if Self.locked == target { busy = false; onChange?(); completion("ok"); return }
        guard remaining > 0 else { busy = false; completion("notConfirmed"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.awaitState(target, remaining: remaining - 1, generation: generation, completion: completion) }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "ScreenControl", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
