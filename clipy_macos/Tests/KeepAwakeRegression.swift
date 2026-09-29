import Foundation
import IOKit.pwr_mgt

func runKeepAwakeRegressionTests() {
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    var acquisitions = 0
    var releases: [IOPMAssertionID] = []
    let driver = KeepAwakeAssertionDriver(
        acquire: { id in
            acquisitions += 1
            id = 42
            return kIOReturnSuccess
        },
        release: { id in
            releases.append(id)
            return kIOReturnSuccess
        })
    let manager = KeepAwakeManager(driver: driver)
    check(manager.setEnabled(true) && manager.isActive, "could not enable keep awake")
    check(manager.setEnabled(true) && acquisitions == 1, "duplicate assertion created")
    check(manager.toggle() && !manager.isActive, "toggle did not release assertion")
    check(releases == [42], "wrong assertion released")
    check(manager.setEnabled(false) && releases == [42], "duplicate release")

    let failed = KeepAwakeManager(driver: .init(
        acquire: { _ in IOReturn(1) },
        release: { _ in fatalError("failed acquisition cannot release") }))
    check(!failed.setEnabled(true) && !failed.isActive && failed.lastError != nil,
          "failed power assertion was shown as enabled")

    var deinitReleases = 0
    do {
        let disposable = KeepAwakeManager(driver: .init(
            acquire: { id in id = 7; return kIOReturnSuccess },
            release: { _ in deinitReleases += 1; return kIOReturnSuccess }))
        check(disposable.setEnabled(true), "disposable assertion failed")
    }
    check(deinitReleases == 1, "deinit leaked a power assertion")
    print("Keep awake regressions passed (one assertion, toggle, failure and release).")
}
