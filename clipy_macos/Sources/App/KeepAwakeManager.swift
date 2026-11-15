import Combine
import Foundation
import IOKit.pwr_mgt

struct KeepAwakeAssertionDriver {
    let acquire: (inout IOPMAssertionID) -> IOReturn
    let release: (IOPMAssertionID) -> IOReturn

    static let system = KeepAwakeAssertionDriver(
        acquire: { id in
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ClipyClone Keep Awake" as CFString,
                &id)
        },
        release: { IOPMAssertionRelease($0) })
}

struct KeepAwakePreferenceStore {
    let load: () -> Bool
    let save: (Bool) -> Void

    static let preferences = KeepAwakePreferenceStore(
        load: { PreferencesManager.shared.keepAwakeEnabled },
        save: { PreferencesManager.shared.keepAwakeEnabled = $0 })

    static let ephemeral = KeepAwakePreferenceStore(
        load: { false },
        save: { _ in })
}

/// Manages the macOS idle display/sleep power assertion.
/// User changes persist across restarts and app reinstalls; `stop()` releases
/// the OS assertion on termination without clearing the saved preference.
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager(driver: .system, preferenceStore: .preferences)

    @Published private(set) var isActive = false
    private(set) var lastError: IOReturn?
    private var assertionID: IOPMAssertionID?
    private let driver: KeepAwakeAssertionDriver
    private let preferenceStore: KeepAwakePreferenceStore

    init(
        driver: KeepAwakeAssertionDriver = .system,
        preferenceStore: KeepAwakePreferenceStore = .ephemeral
    ) {
        self.driver = driver
        self.preferenceStore = preferenceStore
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        precondition(Thread.isMainThread)
        if enabled == isActive {
            preferenceStore.save(enabled)
            return true
        }
        guard applyAssertionState(enabled) else { return false }
        preferenceStore.save(enabled)
        return true
    }

    @discardableResult
    func restoreSavedState() -> Bool {
        precondition(Thread.isMainThread)
        guard preferenceStore.load() else { return true }
        if isActive { return true }
        return applyAssertionState(true)
    }

    @discardableResult
    func toggle() -> Bool { setEnabled(!isActive) }

    func stop() {
        precondition(Thread.isMainThread)
        _ = applyAssertionState(false)
    }

    private func applyAssertionState(_ enabled: Bool) -> Bool {
        if enabled {
            var id: IOPMAssertionID = 0
            let result = driver.acquire(&id)
            guard result == kIOReturnSuccess else {
                lastError = result
                return false
            }
            assertionID = id
            isActive = true
        } else if let assertionID {
            let result = driver.release(assertionID)
            guard result == kIOReturnSuccess else {
                lastError = result
                return false
            }
            self.assertionID = nil
            isActive = false
        }
        lastError = nil
        return true
    }

    deinit {
        if let assertionID { _ = driver.release(assertionID) }
    }
}
