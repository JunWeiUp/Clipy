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

    // Persistence across quit / reinstall cycles:
    var persistedState = false
    var nextID: IOPMAssertionID = 100
    var lifecycleReleases: [IOPMAssertionID] = []
    let store = KeepAwakePreferenceStore(
        load: { persistedState },
        save: { persistedState = $0 })
    let lifecycleDriver = KeepAwakeAssertionDriver(
        acquire: { id in
            nextID += 1
            id = nextID
            return kIOReturnSuccess
        },
        release: { id in
            lifecycleReleases.append(id)
            return kIOReturnSuccess
        })

    // 1. User enables Keep Awake before reinstall; app terminates via stop().
    let beforeReinstall = KeepAwakeManager(driver: lifecycleDriver, preferenceStore: store)
    check(beforeReinstall.setEnabled(true) && beforeReinstall.isActive && persistedState,
          "enabling keep awake did not persist state")
    beforeReinstall.stop()
    check(!beforeReinstall.isActive && lifecycleReleases == [101] && persistedState,
          "stop() on termination cleared persisted keep-awake preference")

    // 2. Reinstalled app launches and restores saved Keep Awake state.
    let afterReinstall = KeepAwakeManager(driver: lifecycleDriver, preferenceStore: store)
    check(afterReinstall.restoreSavedState() && afterReinstall.isActive,
          "reinstalled launch did not restore saved keep-awake state")

    // 3. Failed restore keeps saved preference intact instead of wiping it.
    let transientFail = KeepAwakeManager(
        driver: .init(acquire: { _ in IOReturn(1) }, release: { _ in kIOReturnSuccess }),
        preferenceStore: store)
    check(!transientFail.restoreSavedState() && !transientFail.isActive && persistedState,
          "failed restore unexpectedly cleared saved preference")

    // 4. User explicitly turns Keep Awake off; subsequent launch stays off.
    check(afterReinstall.setEnabled(false) && !afterReinstall.isActive && !persistedState,
          "explicit disable did not persist off state")
    check(lifecycleReleases == [101, 102], "reinstalled assertion was not released on disable")
    let afterExplicitOff = KeepAwakeManager(driver: lifecycleDriver, preferenceStore: store)
    check(afterExplicitOff.restoreSavedState() && !afterExplicitOff.isActive && nextID == 102,
          "launch after explicit disable should not acquire assertion")

    print("Keep awake regressions passed (one assertion, toggle, persistence across reinstall, failure and release).")
}
