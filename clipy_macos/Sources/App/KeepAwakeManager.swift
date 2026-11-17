import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

// MARK: - Model

/// Which IOPM assertion Keep Awake holds.
enum KeepAwakeMode: String, Codable, CaseIterable {
    /// `PreventUserIdleSystemSleep`: the display still sleeps and the screen still locks;
    /// only idle *system* sleep is blocked, so background services keep running.
    case system
    /// `PreventUserIdleDisplaySleep`: the display stays on, so idle auto-lock never triggers.
    case display

    var assertionType: String {
        switch self {
        case .system: return kIOPMAssertionTypePreventUserIdleSystemSleep
        case .display: return kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
    }
}

/// When the current session ends.
enum KeepAwakeEnd: Codable, Equatable {
    case indefinite
    case until(Date)
    /// Ends when the given process exits. PID guards against bundle-ID reuse after relaunch.
    case appExit(bundleID: String?, pid: Int32, name: String)
}

struct KeepAwakeSession: Codable, Equatable {
    var end: KeepAwakeEnd
    var startedAt: Date
    /// Duration preset that started this session (0 = indefinite); nil for at-time,
    /// app-exit or extended sessions so the UI does not highlight a stale preset.
    var presetMinutes: Int? = nil
}

struct KeepAwakeSettings: Codable, Equatable {
    var mode: KeepAwakeMode = .system
    /// Duration used by the quick toggle (menu bar / master switch). 0 = indefinite.
    var lastDurationMinutes: Int = 0
    /// Pause (release the assertion) while running on battery; resume on AC.
    var acPowerOnly = false
    /// Stop the session when on battery and charge ≤ this percentage. 0 = off.
    var batteryStopThreshold = 0
    var notifyOnEnd = true
    var restoreOnLaunch = true

    static let durationPresets = [0, 15, 30, 60, 120, 240, 480]
    static let batteryThresholds = [0, 10, 20, 30, 50]
}

struct KeepAwakePowerSnapshot: Equatable {
    var onBattery: Bool
    /// 0–100, nil on Macs without a battery.
    var batteryPercent: Int?
    static let ac = KeepAwakePowerSnapshot(onBattery: false, batteryPercent: nil)
}

enum KeepAwakeStopReason: Equatable {
    case user, expired, appExited, lowBattery
}

// MARK: - Dependencies (injectable for tests)

struct KeepAwakeAssertionDriver {
    let acquire: (KeepAwakeMode, inout IOPMAssertionID) -> IOReturn
    let release: (IOPMAssertionID) -> IOReturn

    static let system = KeepAwakeAssertionDriver(
        acquire: { mode, id in
            IOPMAssertionCreateWithName(
                mode.assertionType as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ClipyClone Keep Awake" as CFString,
                &id)
        },
        release: { IOPMAssertionRelease($0) })
}

struct KeepAwakePreferenceStore {
    let loadSettings: () -> KeepAwakeSettings?
    let saveSettings: (KeepAwakeSettings) -> Void
    let loadSession: () -> KeepAwakeSession?
    let saveSession: (KeepAwakeSession?) -> Void
    /// Legacy ≤ v1.0.41 switch, consulted only when no settings were ever saved.
    let legacyEnabled: () -> Bool

    static let preferences: KeepAwakePreferenceStore = {
        let prefs = PreferencesManager.shared
        return KeepAwakePreferenceStore(
            loadSettings: { prefs.keepAwakeSettingsData.flatMap { try? JSONDecoder().decode(KeepAwakeSettings.self, from: $0) } },
            saveSettings: { prefs.keepAwakeSettingsData = try? JSONEncoder().encode($0) },
            loadSession: { prefs.keepAwakeSessionData.flatMap { try? JSONDecoder().decode(KeepAwakeSession.self, from: $0) } },
            saveSession: { prefs.keepAwakeSessionData = $0.flatMap { try? JSONEncoder().encode($0) } },
            legacyEnabled: { prefs.keepAwakeEnabled })
    }()

    static func memory() -> KeepAwakePreferenceStore {
        final class Box { var settings: KeepAwakeSettings?; var session: KeepAwakeSession? }
        let box = Box()
        return KeepAwakePreferenceStore(
            loadSettings: { box.settings }, saveSettings: { box.settings = $0 },
            loadSession: { box.session }, saveSession: { box.session = $0 },
            legacyEnabled: { false })
    }
}

struct KeepAwakeEnvironment {
    var now: () -> Date
    var power: () -> KeepAwakePowerSnapshot
    var isProcessRunning: (Int32) -> Bool
    var notify: (_ title: String, _ body: String) -> Void
    /// Whether to install real timers/observers (off in tests, which drive `reevaluate()`).
    var installsMonitors: Bool

    static let system = KeepAwakeEnvironment(
        now: Date.init,
        power: KeepAwakePower.snapshot,
        isProcessRunning: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated
        },
        notify: KeepAwakeNotifier.post,
        installsMonitors: true)

    static func test(now: @escaping () -> Date = Date.init,
                     power: @escaping () -> KeepAwakePowerSnapshot = { .ac },
                     isProcessRunning: @escaping (Int32) -> Bool = { _ in true },
                     notify: @escaping (String, String) -> Void = { _, _ in }) -> KeepAwakeEnvironment {
        KeepAwakeEnvironment(now: now, power: power, isProcessRunning: isProcessRunning, notify: notify, installsMonitors: false)
    }
}

// MARK: - Manager

/// Keeps the Mac from idle-sleeping, optionally letting the display sleep and lock.
///
/// Resident state (all main-thread): while a session exists it holds at most one IOPM
/// assertion, one one-shot end timer, one App Nap activity token, a wake observer, and —
/// only when needed — an IOPS power-source run-loop source and an app-termination observer.
/// Ending the session releases every one of them; when off nothing is installed.
/// `releaseForTermination()` drops the OS resources at quit but keeps the persisted
/// session so `restoreSavedState()` can resume it on the next launch.
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager(driver: .system, preferenceStore: .preferences, environment: .system)

    @Published private(set) var session: KeepAwakeSession?
    @Published private(set) var settings: KeepAwakeSettings
    /// The OS assertion is currently held.
    @Published private(set) var isActive = false
    /// Session exists but the assertion is released because the Mac is on battery.
    @Published private(set) var isPausedOnBattery = false
    @Published private(set) var lastError: IOReturn?
    @Published private(set) var lastStopReason: KeepAwakeStopReason?

    /// User intent: a session is running (possibly paused).
    var isEnabled: Bool { session != nil }

    private var assertionID: IOPMAssertionID?
    private var heldMode: KeepAwakeMode?
    private let driver: KeepAwakeAssertionDriver
    private let store: KeepAwakePreferenceStore
    private let env: KeepAwakeEnvironment

    private var endTimer: Timer?
    private var activity: NSObjectProtocol?
    private var powerSource: CFRunLoopSource?
    private var appObserver: NSObjectProtocol?
    /// PID the current `appObserver` filters on; a new target app replaces the observer.
    private var appObserverPID: pid_t?
    private var wakeObserver: NSObjectProtocol?

    init(driver: KeepAwakeAssertionDriver = .system,
         preferenceStore: KeepAwakePreferenceStore = .memory(),
         environment: KeepAwakeEnvironment = .test()) {
        self.driver = driver
        self.store = preferenceStore
        self.env = environment
        if let saved = preferenceStore.loadSettings() {
            settings = saved
        } else {
            // First launch of this version: migrate the legacy single switch.
            settings = KeepAwakeSettings()
            preferenceStore.saveSettings(settings)
            if preferenceStore.legacyEnabled() {
                preferenceStore.saveSession(KeepAwakeSession(end: .indefinite, startedAt: environment.now()))
            }
        }
    }

    // MARK: Derived state

    var endDate: Date? {
        if case .until(let date)? = session?.end { return date }
        return nil
    }

    var remaining: TimeInterval? { endDate.map { max(0, $0.timeIntervalSince(env.now())) } }

    /// Fraction of the timed session still left (1 → 0); nil when not timed.
    var remainingFraction: Double? {
        guard let session, let end = endDate else { return nil }
        let total = end.timeIntervalSince(session.startedAt)
        guard total > 0 else { return 0 }
        return max(0, min(1, end.timeIntervalSince(env.now()) / total))
    }

    /// Preset duration of the running session, or nil when it was not started from a preset.
    var activePresetMinutes: Int? {
        guard isEnabled, let session else { return nil }
        if let preset = session.presetMinutes { return preset }
        if case .indefinite = session.end { return 0 }
        return nil
    }

    var targetAppName: String? {
        if case .appExit(_, _, let name)? = session?.end { return name }
        return nil
    }

    // MARK: Starting / stopping

    /// Quick toggle: stops a running session, otherwise starts one with the last-used duration.
    @discardableResult
    func toggle() -> Bool {
        if isEnabled { stop(); return true }
        return start(minutes: settings.lastDurationMinutes)
    }

    /// Compatibility with the old on/off API.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled == isEnabled { return true }
        return enabled ? start(minutes: settings.lastDurationMinutes) : { stop(); return true }()
    }

    /// Starts (or restarts) a session. `minutes == 0` means indefinite. Remembered for the quick toggle.
    @discardableResult
    func start(minutes: Int) -> Bool {
        precondition(Thread.isMainThread)
        let minutes = max(0, minutes)
        mutateSettings { $0.lastDurationMinutes = minutes }
        let end: KeepAwakeEnd = minutes == 0 ? .indefinite : .until(env.now().addingTimeInterval(TimeInterval(minutes * 60)))
        return begin(end, presetMinutes: minutes)
    }

    /// Runs until the given wall-clock time; a time not in the future is moved to the next day.
    @discardableResult
    func start(until date: Date) -> Bool {
        precondition(Thread.isMainThread)
        var target = date
        let now = env.now()
        while target <= now { target = target.addingTimeInterval(86_400) }
        return begin(.until(target))
    }

    /// Runs until the given app quits.
    @discardableResult
    func start(untilExitOf pid: Int32, bundleID: String?, name: String) -> Bool {
        precondition(Thread.isMainThread)
        guard env.isProcessRunning(pid) else { return false }
        return begin(.appExit(bundleID: bundleID, pid: pid, name: name))
    }

    /// Adds time to a timed session (an indefinite one stays indefinite).
    func extend(by seconds: TimeInterval) {
        precondition(Thread.isMainThread)
        guard var current = session, case .until(let date) = current.end else { return }
        current.end = .until(max(date, env.now()).addingTimeInterval(seconds))
        current.presetMinutes = nil
        session = current
        store.saveSession(current)
        reevaluate()
    }

    /// Ends the session and returns the Mac to normal sleep.
    func stop() {
        precondition(Thread.isMainThread)
        finish(.user)
    }

    /// Called at app termination: drop OS resources, keep the saved session for relaunch.
    func releaseForTermination() {
        precondition(Thread.isMainThread)
        _ = releaseAssertion()
        tearDownMonitors()
    }

    /// Called at launch. Resumes a saved session unless disabled, expired, or its app is gone.
    @discardableResult
    func restoreSavedState() -> Bool {
        precondition(Thread.isMainThread)
        guard session == nil, let saved = store.loadSession() else { return true }
        guard settings.restoreOnLaunch else { store.saveSession(nil); return true }
        switch saved.end {
        case .until(let date) where date <= env.now():
            store.saveSession(nil); return true
        case .appExit(_, let pid, _) where !env.isProcessRunning(pid):
            store.saveSession(nil); return true
        default: break
        }
        session = saved
        installMonitors()
        reevaluate()
        if lastError != nil && !isActive && !isPausedOnBattery {
            // Keep the saved session so a later launch can retry, but don't show a phantom "on" state.
            session = nil
            tearDownMonitors()
            return false
        }
        return true
    }

    // MARK: Settings

    /// Switching while active acquires the new assertion before releasing the old one
    /// (see `acquireAssertion`), so idle sleep is never allowed in between.
    func setMode(_ mode: KeepAwakeMode) { update { $0.mode = mode } }

    func update(_ change: (inout KeepAwakeSettings) -> Void) {
        precondition(Thread.isMainThread)
        mutateSettings(change)
        guard isEnabled else { return }
        installMonitors()
        reevaluate()
    }

    private func mutateSettings(_ change: (inout KeepAwakeSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        store.saveSettings(copy)
    }

    // MARK: Core

    private func begin(_ end: KeepAwakeEnd, presetMinutes: Int? = nil) -> Bool {
        let new = KeepAwakeSession(end: end, startedAt: env.now(), presetMinutes: presetMinutes)
        session = new
        lastStopReason = nil
        store.saveSession(new)
        installMonitors()
        reevaluate()
        if lastError != nil && !isActive && !isPausedOnBattery {
            // Could not take the assertion at all: don't leave a phantom "on" session.
            session = nil
            store.saveSession(nil)
            tearDownMonitors()
            return false
        }
        return true
    }

    /// Re-checks end conditions and power state; acquires/releases the assertion accordingly.
    func reevaluate() {
        precondition(Thread.isMainThread)
        guard let current = session else { return }
        switch current.end {
        case .until(let date) where date <= env.now():
            finish(.expired); return
        case .appExit(_, let pid, _) where !env.isProcessRunning(pid):
            finish(.appExited); return
        default: break
        }
        let power = env.power()
        if settings.batteryStopThreshold > 0, power.onBattery,
           let percent = power.batteryPercent, percent <= settings.batteryStopThreshold {
            finish(.lowBattery); return
        }
        let shouldHold = !(settings.acPowerOnly && power.onBattery)
        isPausedOnBattery = !shouldHold
        if shouldHold {
            if !isActive || heldMode != settings.mode { _ = acquireAssertion() }
        } else {
            _ = releaseAssertion()
        }
        scheduleEndTimer()
    }

    private func finish(_ reason: KeepAwakeStopReason) {
        guard session != nil else { return }
        let target = targetAppName
        _ = releaseAssertion()
        session = nil
        isPausedOnBattery = false
        lastStopReason = reason
        store.saveSession(nil)
        tearDownMonitors()
        guard reason != .user, settings.notifyOnEnd else { return }
        let zh = PreferencesManager.shared.appLanguage == .zh
        let body: String
        switch reason {
        case .expired: body = zh ? "定时已到，Mac 恢复正常睡眠。" : "Time is up. Your Mac can sleep normally again."
        case .appExited:
            let name = target ?? (zh ? "目标应用" : "The app")
            body = zh ? "「\(name)」已退出，Mac 恢复正常睡眠。" : "\(name) quit. Your Mac can sleep normally again."
        case .lowBattery: body = zh ? "电量过低，已停止保持唤醒。" : "Battery is low, so Keep Awake stopped."
        case .user: return
        }
        env.notify(zh ? "保持唤醒已结束" : "Keep Awake ended", body)
    }

    private func acquireAssertion() -> Bool {
        var id: IOPMAssertionID = 0
        let result = driver.acquire(settings.mode, &id)
        guard result == kIOReturnSuccess else {
            lastError = result
            appLog("Keep Awake: assertion failed (\(result))", level: .warning)
            return false
        }
        if let old = assertionID { _ = driver.release(old) }
        assertionID = id
        heldMode = settings.mode
        isActive = true
        lastError = nil
        return true
    }

    private func releaseAssertion() -> Bool {
        guard let id = assertionID else { isActive = false; return true }
        let result = driver.release(id)
        guard result == kIOReturnSuccess else { lastError = result; return false }
        assertionID = nil
        heldMode = nil
        isActive = false
        return true
    }

    // MARK: Monitors (installed only while a session exists)

    private func installMonitors() {
        guard env.installsMonitors, let current = session else { return }
        if activity == nil {
            // Keep Clipy's own timers/sync from being App-Napped while it is keeping the Mac awake.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Keep Awake session")
        }
        if wakeObserver == nil {
            // Timers do not advance during sleep (manual sleep / lid close); re-check on wake.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.reevaluate()
                }
        }
        let needsPower = settings.acPowerOnly || settings.batteryStopThreshold > 0
        if needsPower, powerSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let manager = Unmanaged<KeepAwakeManager>.fromOpaque(context).takeUnretainedValue()
                manager.reevaluate()
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                powerSource = source
            }
        } else if !needsPower, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
        }
        if case .appExit(_, let pid, _) = current.end {
            if appObserver != nil, appObserverPID != pid, let stale = appObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(stale)
                appObserver = nil
            }
            if appObserver == nil {
                appObserverPID = pid
                appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                        if app?.processIdentifier == pid { self?.reevaluate() }
                    }
            }
        } else if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appObserver = nil
            appObserverPID = nil
        }
    }

    private func scheduleEndTimer() {
        endTimer?.invalidate()
        endTimer = nil
        guard env.installsMonitors, let end = endDate else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.reevaluate() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func tearDownMonitors() {
        endTimer?.invalidate()
        endTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if let source = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        powerSource = nil
        let center = NSWorkspace.shared.notificationCenter
        if let appObserver { center.removeObserver(appObserver) }
        appObserver = nil
        appObserverPID = nil
        if let wakeObserver { center.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    deinit {
        if let assertionID { _ = driver.release(assertionID) }
        tearDownMonitors()
    }
}

// MARK: - System helpers

enum KeepAwakePower {
    static func snapshot() -> KeepAwakePowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .ac }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = desc[kIOPSCurrentCapacityKey] as? Int,
                      let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                percent = Int((Double(current) / Double(max) * 100).rounded())
            }
        }
        return KeepAwakePowerSnapshot(onBattery: onBattery, batteryPercent: percent)
    }
}

/// One process holding a sleep-preventing assertion (diagnostics; read on demand, not cached).
struct KeepAwakeAssertionInfo: Identifiable, Equatable {
    let id: String
    let pid: Int32
    let process: String
    let name: String
    let preventsDisplaySleep: Bool
}

enum KeepAwakeDiagnostics {
    private static let systemTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypeNoIdleSleep
    ]
    private static let displayTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypeNoDisplaySleep
    ]

    static func sleepPreventingAssertions() -> [KeepAwakeAssertionInfo] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [KeepAwakeAssertionInfo] = []
        for (pidNumber, assertions) in dict {
            let pid = pidNumber.int32Value
            let process = processName(pid)
            // powerd's own "while display is on" bookkeeping is noise for users.
            if process == "powerd" { continue }
            for (index, assertion) in assertions.enumerated() {
                guard let type = assertion[kIOPMAssertionTypeKey] as? String,
                      systemTypes.contains(type) || displayTypes.contains(type) else { continue }
                let name = assertion[kIOPMAssertionNameKey] as? String ?? type
                result.append(KeepAwakeAssertionInfo(
                    id: "\(pid)-\(index)-\(name)", pid: pid, process: process, name: name,
                    preventsDisplaySleep: displayTypes.contains(type)))
            }
        }
        return result.sorted { ($0.pid == getpid() ? 0 : 1, $0.process) < ($1.pid == getpid() ? 0 : 1, $1.process) }
    }

    private static func processName(_ pid: Int32) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "PID \(pid)"
    }
}

enum KeepAwakeNotifier {
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "clipy.keepAwake.ended", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request) { error in
                if let error { appLog("Keep Awake notification failed: \(error)", level: .warning) }
            }
        }
    }
}

/// Short formatting shared by the page, sidebar and menu bar panel.
enum KeepAwakeFormat {
    static func zh() -> Bool { PreferencesManager.shared.appLanguage == .zh }
    static func t(_ zh: String, _ en: String) -> String { Self.zh() ? zh : en }

    /// "1:24:30"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// "1:24" (hours:minutes, rounded up so the last minute shows 0:01).
    static func short(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func duration(minutes: Int) -> String {
        if minutes == 0 { return t("一直保持", "Indefinitely") }
        if minutes % 60 == 0 { return t("\(minutes / 60) 小时", minutes == 60 ? "1 hour" : "\(minutes / 60) hours") }
        return t("\(minutes) 分钟", "\(minutes) min")
    }

    /// Compact status for sidebar rows / panel chips.
    static func status(_ manager: KeepAwakeManager) -> String {
        guard manager.isEnabled else { return t("已关闭", "Off") }
        if manager.isPausedOnBattery { return t("已暂停", "Paused") }
        if let remaining = manager.remaining { return short(remaining) }
        return t("已开启", "On")
    }
}
