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

/// A session-only power assertion. The system releases it when Clipy exits;
/// explicit disable and application termination release it immediately.
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    @Published private(set) var isActive = false
    private(set) var lastError: IOReturn?
    private var assertionID: IOPMAssertionID?
    private let driver: KeepAwakeAssertionDriver

    init(driver: KeepAwakeAssertionDriver = .system) {
        self.driver = driver
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        precondition(Thread.isMainThread)
        if enabled == isActive { return true }
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

    @discardableResult
    func toggle() -> Bool { setEnabled(!isActive) }

    func stop() { _ = setEnabled(false) }

    deinit {
        if let assertionID { _ = driver.release(assertionID) }
    }
}
