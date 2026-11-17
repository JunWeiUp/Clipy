import Foundation
import IOKit.pwr_mgt

func runKeepAwakeRegressionTests() {
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError("KeepAwake: " + message) }
    }

    final class Fake {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var power = KeepAwakePowerSnapshot.ac
        var running: Set<Int32> = [77]
        var nextID: IOPMAssertionID = 0
        var held: [IOPMAssertionID: KeepAwakeMode] = [:]
        var acquisitions: [KeepAwakeMode] = []
        var failAcquire = false
        var notifications: [String] = []

        lazy var driver = KeepAwakeAssertionDriver(
            acquire: { [unowned self] mode, id in
                if self.failAcquire { return IOReturn(1) }
                self.nextID += 1; id = self.nextID
                self.held[id] = mode; self.acquisitions.append(mode)
                return kIOReturnSuccess
            },
            release: { [unowned self] id in
                guard self.held.removeValue(forKey: id) != nil else { fatalError("double release \(id)") }
                return kIOReturnSuccess
            })
        lazy var env = KeepAwakeEnvironment.test(
            now: { [unowned self] in self.now },
            power: { [unowned self] in self.power },
            isProcessRunning: { [unowned self] in self.running.contains($0) },
            notify: { [unowned self] _, body in self.notifications.append(body) })
    }

    // 1. Default mode is "system" (display may sleep/lock); one assertion, toggle releases it.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        check(m.settings.mode == .system, "default mode should allow display sleep")
        check(m.toggle() && m.isEnabled && m.isActive, "toggle on failed")
        check(f.held.values.first == .system && f.held.count == 1, "wrong assertion type")
        check(m.remaining == nil, "indefinite session should have no remaining time")
        m.reevaluate()
        check(f.acquisitions.count == 1, "reevaluate re-acquired an already held assertion")
        check(m.toggle() && !m.isEnabled && f.held.isEmpty, "toggle off leaked assertion")
        check(f.notifications.isEmpty, "manual stop must not notify")
    }

    // 2. Mode switch while active swaps assertion with no gap; switching while off only saves.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        m.setMode(.display)
        check(f.acquisitions.isEmpty && m.settings.mode == .display, "mode change while off acquired")
        check(m.start(minutes: 0), "start failed")
        check(f.held.values.first == .display, "display mode not applied")
        m.setMode(.system)
        check(f.held.count == 1 && f.held.values.first == .system, "mode swap left wrong/extra assertions")
        m.stop()
        check(f.held.isEmpty, "stop leaked")
    }

    // 3. Timed session: remaining, extend, expiry notifies and releases; quick toggle reuses duration.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        check(m.start(minutes: 30), "timed start failed")
        check(m.remaining == 1800 && m.remainingFraction == 1, "remaining wrong")
        f.now += 600
        m.extend(by: 900)
        check(abs((m.remaining ?? 0) - 2100) < 0.5, "extend wrong")
        f.now += 2100
        m.reevaluate()
        check(!m.isEnabled && f.held.isEmpty && m.lastStopReason == .expired, "expiry did not stop")
        check(f.notifications.count == 1, "expiry did not notify")
        check(m.toggle() && m.remaining == 1800, "quick toggle did not reuse last duration")
        m.stop()
        m.update { $0.notifyOnEnd = false }
        _ = m.start(minutes: 1); f.now += 61; m.reevaluate()
        check(f.notifications.count == 1, "notifyOnEnd=false still notified")
    }

    // 4. Until a time: past time rolls to tomorrow.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        check(m.start(until: f.now.addingTimeInterval(-3600)), "until start failed")
        check(abs((m.remaining ?? 0) - (86_400 - 3600)) < 0.5, "past time did not roll to next day")
        m.stop()
    }

    // 5. AC-only pauses on battery and resumes on AC; low battery stops.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        m.update { $0.acPowerOnly = true }
        f.power = KeepAwakePowerSnapshot(onBattery: true, batteryPercent: 80)
        check(m.start(minutes: 0), "start on battery should succeed (paused)")
        check(m.isEnabled && m.isPausedOnBattery && !m.isActive && f.held.isEmpty, "not paused on battery")
        f.power = .ac
        m.reevaluate()
        check(m.isActive && !m.isPausedOnBattery && f.held.count == 1, "did not resume on AC")
        m.update { $0.acPowerOnly = false; $0.batteryStopThreshold = 20 }
        f.power = KeepAwakePowerSnapshot(onBattery: true, batteryPercent: 50)
        m.reevaluate()
        check(m.isActive, "stopped above threshold")
        f.power = KeepAwakePowerSnapshot(onBattery: true, batteryPercent: 20)
        m.reevaluate()
        check(!m.isEnabled && f.held.isEmpty && m.lastStopReason == .lowBattery, "low battery did not stop")
    }

    // 6. Until app exits.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        check(!m.start(untilExitOf: 5, bundleID: nil, name: "Gone"), "started for a non-running app")
        check(m.start(untilExitOf: 77, bundleID: "com.example", name: "Xcode") && m.targetAppName == "Xcode", "app start failed")
        f.running.remove(77)
        m.reevaluate()
        check(!m.isEnabled && f.held.isEmpty && m.lastStopReason == .appExited, "app exit did not stop")
    }

    // 7. Persistence: termination keeps the session; restore honours expiry / restoreOnLaunch.
    do {
        let f = Fake()
        let store = KeepAwakePreferenceStore.memory()
        let a = KeepAwakeManager(driver: f.driver, preferenceStore: store, environment: f.env)
        check(a.start(minutes: 60), "start failed")
        a.releaseForTermination()
        check(f.held.isEmpty && store.loadSession() != nil, "termination cleared the saved session")
        let b = KeepAwakeManager(driver: f.driver, preferenceStore: store, environment: f.env)
        check(b.restoreSavedState() && b.isActive && abs((b.remaining ?? 0) - 3600) < 0.5, "restore failed")
        b.releaseForTermination()
        f.now += 3601
        let c = KeepAwakeManager(driver: f.driver, preferenceStore: store, environment: f.env)
        check(c.restoreSavedState() && !c.isEnabled && store.loadSession() == nil, "expired session restored")
        check(c.start(minutes: 0), "start failed")
        c.update { $0.restoreOnLaunch = false }
        c.releaseForTermination()
        let d = KeepAwakeManager(driver: f.driver, preferenceStore: store, environment: f.env)
        check(d.restoreSavedState() && !d.isEnabled && f.held.isEmpty, "restoreOnLaunch=false still restored")
        check(d.settings.restoreOnLaunch == false, "settings not persisted")
    }

    // 8. Legacy migration: old keepAwakeEnabled=true becomes an indefinite session.
    do {
        let f = Fake()
        final class Box { var settings: KeepAwakeSettings?; var session: KeepAwakeSession? }
        let box = Box()
        let legacy = KeepAwakePreferenceStore(
            loadSettings: { box.settings }, saveSettings: { box.settings = $0 },
            loadSession: { box.session }, saveSession: { box.session = $0 },
            legacyEnabled: { true })
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: legacy, environment: f.env)
        check(m.restoreSavedState() && m.isActive && m.remaining == nil, "legacy switch not migrated")
        m.stop()
        let again = KeepAwakeManager(driver: f.driver, preferenceStore: legacy, environment: f.env)
        check(again.restoreSavedState() && !again.isEnabled, "legacy switch re-migrated after explicit off")
    }

    // 9. Failure: no phantom session; restore failure keeps saved session.
    do {
        let f = Fake()
        f.failAcquire = true
        let store = KeepAwakePreferenceStore.memory()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: store, environment: f.env)
        check(!m.start(minutes: 0) && !m.isEnabled && m.lastError != nil && store.loadSession() == nil,
              "failed assertion shown as enabled")
        store.saveSession(KeepAwakeSession(end: .indefinite, startedAt: f.now))
        let r = KeepAwakeManager(driver: f.driver, preferenceStore: store, environment: f.env)
        check(!r.restoreSavedState() && store.loadSession() != nil, "failed restore wiped saved session")
    }

    // 9b. Preset highlight follows the running session, not the last-used preset.
    do {
        let f = Fake()
        let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
        check(m.activePresetMinutes == nil, "idle manager reported a preset")
        check(m.start(minutes: 30) && m.activePresetMinutes == 30, "preset session not reported")
        m.extend(by: 600)
        check(m.activePresetMinutes == nil, "extended session still matched its preset")
        check(m.start(until: f.now.addingTimeInterval(3600)) && m.activePresetMinutes == nil,
              "at-time session highlighted the previous preset")
        check(m.start(minutes: 0) && m.activePresetMinutes == 0, "indefinite preset not reported")
        m.stop()
    }

    // 10. deinit releases.
    do {
        let f = Fake()
        do {
            let m = KeepAwakeManager(driver: f.driver, preferenceStore: .memory(), environment: f.env)
            _ = m.start(minutes: 0)
        }
        check(f.held.isEmpty, "deinit leaked a power assertion")
    }

    print("Keep awake regressions passed (modes, timers, extend, AC-only, low battery, app exit, persistence, migration, failure).")
}
