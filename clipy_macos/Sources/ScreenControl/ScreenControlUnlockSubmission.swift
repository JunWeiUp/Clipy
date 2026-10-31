// Adapted from VibePier (MIT). See LICENSE.VIBEPIER.MIT.
import Foundation

/// The callbacks must target the same verified secure control, never the global keyboard/clipboard.
/// Injectable ordering checks keep tests independent of the real login screen and stored credentials.
enum ScreenControlUnlockSubmission {
    static func perform(
        isLocked: () -> Bool, targetStillReady: () -> Bool,
        writePassword: () throws -> Void, submit: () throws -> Void
    ) throws {
        guard isLocked() else { return }
        guard targetStillReady() else { throw ScreenControlUnlockError(stage: "secure-field-unavailable") }
        try writePassword()
        guard isLocked() else { return }
        guard targetStillReady() else { throw ScreenControlUnlockError(stage: "target-changed") }
        try submit()
    }
}
