import AppKit
import Foundation

/// Bridge for the capture sound that macshot's overlay/editor code triggers via
/// `AppDelegate.captureSound`. clipy1 has no AppDelegate capture-sound property,
/// so this lightweight singleton plays the system "Glass" sound (or a no-op when
/// the user disables it). Keeping the call sites identical to macshot means the
/// copied source files compile unchanged.
enum ScreenshotSounds {
    /// Cached NSSound so rapid captures don't re-decode the resource each time.
    private static let sound: NSSound? = NSSound(named: NSSound.Name("Glass"))

    /// UserDefaults key (mirrors macshot). Defaults to ON.
    private static let enabledKey = "playCopySound"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Stop any in-flight playback, then play the capture sound (if enabled).
    static func playCapture() {
        guard isEnabled, let sound = sound else { return }
        sound.stop()
        sound.play()
    }
}
