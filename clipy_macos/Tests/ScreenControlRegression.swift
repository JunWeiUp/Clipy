import Foundation
@main struct ScreenControlRegression {
    static func main() {
        let now = Date()
        var challenge = ScreenControlChallenge(token: "nonce", issued: now)
        precondition(!challenge.consume(token: "wrong-session", action: "unlock", now: now))
        precondition(!challenge.consume(token: "nonce", action: "other", now: now))
        precondition(!challenge.consumed)
        precondition(challenge.consume(token: "nonce", action: "unlock", now: now))
        precondition(!challenge.consume(token: "nonce", action: "unlock", now: now))
        var expired = ScreenControlChallenge(token: "nonce", issued: now.addingTimeInterval(-120))
        precondition(!expired.consume(token: "nonce", action: "unlock", now: now))
        var future = ScreenControlChallenge(token: "nonce", issued: now.addingTimeInterval(1))
        precondition(!future.consume(token: "nonce", action: "lock", now: now))
        var gate = ScreenControlAttemptGate()
        precondition(gate.admit(action: "lock", configured: true, busy: false, locked: false, helper: true, now: now) == nil)
        precondition(gate.admit(action: "unlock", configured: true, busy: false, locked: true, helper: true, now: now.addingTimeInterval(0.1)) == nil)
        precondition(gate.admit(action: "unlock", configured: true, busy: false, locked: true, helper: true, now: now.addingTimeInterval(1)) == "cooldown")
        precondition(gate.admit(action: "lock", configured: true, busy: false, locked: false, helper: true, now: now.addingTimeInterval(1)) == nil)
        precondition(gate.admit(action: "unlock", configured: true, busy: false, locked: false, helper: true, now: now.addingTimeInterval(1)) == "ok")
        precondition(gate.admit(action: "unlock", configured: true, busy: false, locked: true, helper: true, now: now.addingTimeInterval(5.2)) == nil)
        precondition(gate.admit(action: "unlock", configured: true, busy: true, locked: true, helper: true, now: now) == "busy")
        precondition(gate.admit(action: "unlock", configured: false, busy: false, locked: true, helper: true, now: now) == "notConfigured")
        precondition(gate.admit(action: "unlock", configured: true, busy: false, locked: nil, helper: true, now: now) == "sessionUnavailable")
        precondition(gate.admit(action: "unlock", configured: true, busy: false, locked: true, helper: false, now: now) == "accessibilityRequired")
        var events: [String] = []
        try! ScreenControlUnlockSubmission.perform(isLocked: { false }, targetStillReady: { preconditionFailure("no lookup after unlock") }, writePassword: { preconditionFailure("no write after unlock") }, submit: { preconditionFailure("no submit after unlock") })
        do {
            try ScreenControlUnlockSubmission.perform(isLocked: { true }, targetStillReady: { false }, writePassword: { preconditionFailure("no unverified write") }, submit: { preconditionFailure("no unverified submit") })
            preconditionFailure("missing secure control must fail")
        } catch {}
        var ready = true
        do {
            try ScreenControlUnlockSubmission.perform(isLocked: { true }, targetStillReady: { ready }, writePassword: { ready = false }, submit: { preconditionFailure("never confirm changed target") })
            preconditionFailure("changed target must fail")
        } catch {}
        var locked = true
        try! ScreenControlUnlockSubmission.perform(isLocked: { locked }, targetStillReady: { true }, writePassword: { locked = false }, submit: { preconditionFailure("no confirmation into unlocked desktop") })
        try! ScreenControlUnlockSubmission.perform(isLocked: { true }, targetStillReady: { events.append("verify"); return true }, writePassword: { events.append("write") }, submit: { events.append("confirm") })
        precondition(events == ["verify", "write", "verify", "confirm"])
        let graph = [0: [1, 2], 1: [0], 2: []]
        let complete = ScreenControlAXTraversal.collect(0, limit: 4, withinDeadline: { true }, identity: { $0 }, children: { n, _ in graph[n] })
        precondition(complete == [0, 1, 2])
        let truncated = ScreenControlAXTraversal.collect(0, limit: 2, withinDeadline: { true }, identity: { $0 }, children: { n, _ in graph[n] })
        precondition(truncated == nil)
        print("Screen control direct / cooldown / verified AX submission / bounded traversal regressions passed")
    }
}
