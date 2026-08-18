import AppKit
import Foundation
import CoreGraphics
import ApplicationServices
import CryptoKit

class ClipboardManager {
    static let shared = ClipboardManager()

    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?
    private var pollingObserverTokens: [NSObjectProtocol] = []
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private(set) var recentSummaries: [HistorySummary] = []
    private(set) var isMenuMemoryRetained = false
    /// Lazily refreshed: every insert used to run a synchronous `COUNT(*)` on
    /// the main thread even though only Settings and the search window read it.
    private var cachedHistoryCount = 0
    private var isHistoryCountStale = true
    var totalHistoryCount: Int {
        if isHistoryCountStale {
            cachedHistoryCount = repository.count()
            isHistoryCountStale = false
        }
        return cachedHistoryCount
    }
    /// The menu bar only ever renders `MenuController.menuDisplayLimit` (50)
    /// items, so loading more into `recentSummaries` is pure waste. Cap the
    /// in-memory load at 50 regardless of the (search-window) page size
    /// `historyLoadCount`, which the search window still uses for paging.
    private var menuHistoryLimit: Int { min(PreferencesManager.shared.historyLoadCount, 50) }
    private var maxHistoryItems: Int { PreferencesManager.shared.historyLimit }
    private let repository = HistoryRepository.shared
    /// Path of the legacy standalone file-history JSON. Kept only so
    /// `migrateFileHistoryToMainIfNeeded()` can read+archive it; no longer read
    /// or written at runtime after migration.
    private let fileHistoryURL: URL
    /// Recent remote-origin hashes, used as a loopback guard in addition to the
    /// changeCount check. Single-field `lastSyncHash` is fragile under burst
    /// pushes and lost on restart; a bounded TTL set covers both.
    /// Keep aligned with the Android side's _recentRemoteHashes.
    private var recentRemoteHashes: [(hash: String, at: Date)] = []
    private static let recentRemoteHashMax = 20
    private static let recentRemoteHashTTL: TimeInterval = 60
    private var lastSyncHash: String?
    
    // Performance optimization: debounce and content tracking
    private var lastCheckTime: Date = Date()
    private var pendingContentCheck: Bool = false
    private let minCheckInterval: TimeInterval = 0.3 // Reduced from 0.5s to 0.3s with better logic
    /// Slower poll interval used while the app is idle (no windows, not active).
    private let idleCheckInterval: TimeInterval = 2.0
    private var currentPollInterval: TimeInterval = 0.3
    private var pruneWorkItem: DispatchWorkItem?
    /// Heavy ingest work (media store writes, hashing, index building, DB insert).
    private let ingestQueue = DispatchQueue(label: "com.clipy.ingest", qos: .userInitiated)
    private var recentContentHashes: Set<String> = []
    private let recentContentHashesMaxSize = 50
    private var pendingIndexHashes: Set<String> = []
    private var pasteEventTap: CFMachPort?
    private var pasteEventTapRunLoopSource: CFRunLoopSource?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }

            isoFormatter.formatOptions = [.withInternetDateTime]
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }

            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                "yyyy-MM-dd'T'HH:mm:ss.SSS",
                "yyyy-MM-dd'T'HH:mm:ss"
            ]
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .iso8601)
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for format in formats {
                df.dateFormat = format
                if let date = df.date(from: dateStr) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateStr)")
        }
        return decoder
    }()

    var onHistoryChanged: (() -> Void)?

    private init() {
        self.changeCount = pasteboard.changeCount

        // Setup storage
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipyClone")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileHistoryURL = appSupport.appendingPathComponent("file_history.json")

        HistoryRepository.shared.migrateFromLegacyJSONIfNeeded()
        loadHistory()
        migrateFileHistoryToMainIfNeeded()
        startPolling()
        startPasteUsageMonitoringIfNeeded()
        
        // Initialize recent content hashes from existing history
        updateRecentContentHashes()

        // Maintenance work (index cleanup/backfill, orphan pruning) is not needed
        // for first paint; run it shortly after launch off the critical path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            HistoryRepository.shared.clearTextSearchIndexes()
            self.backfillSearchIndexesIfNeeded()
            self.schedulePruneUnreferencedMediaFiles()
        }

        // 预热首屏数据：后台跑一次摘要查询，让 SQLite 缓存页提前暖起来，
        // 避免第一次打开菜单时 fetchSummaries 因启动期 DB 队列争用而阻塞卡顿。
        // 结果丢弃，不写入 recentSummaries（仍由菜单打开时正式加载），零行为风险。
        let warmupLimit = menuHistoryLimit
        DispatchQueue.global(qos: .utility).async {
            _ = HistoryRepository.shared.fetchSummaries(limit: warmupLimit)
        }
    }
    
    private func updateRecentContentHashes() {
        recentContentHashes.removeAll()
        for summary in recentSummaries.prefix(recentContentHashesMaxSize) {
            if let hash = summary.contentHash {
                recentContentHashes.insert(hash)
            }
        }
    }
    
    /// One-shot migration: imports the legacy `file_history.json` (the old
    /// standalone "File History" submenu store) into the main SQLite history as
    /// `.files` entries, preserving each item's original timestamp and sender.
    /// Runs at launch right after `loadHistory()`. After a successful import the
    /// JSON file is renamed to `.bak` so this never runs twice and the source of
    /// truth becomes the main history DB. Idempotent: missing/corrupt file
    /// or already-migrated (`.bak` present) → no-op.
    ///
    /// Uses `prepareHistoryInsert` directly (not `addToHistory`) so each row is
    /// written to the DB without per-row UI refresh / OCR scheduling — the UI is
    /// refreshed once after the whole batch, since this runs during init before
    /// the menu/window observers are wired up.
    private func migrateFileHistoryToMainIfNeeded() {
        guard FileManager.default.fileExists(atPath: fileHistoryURL.path) else { return }
        guard let data = try? Data(contentsOf: fileHistoryURL),
              let legacyItems = try? decoder.decode([FileHistoryItem].self, from: data),
              !legacyItems.isEmpty else {
            appLog("File history migration: failed to decode legacy file_history.json, archiving it anyway", level: .warning)
            archiveLegacyFileHistory()
            return
        }
        appLog("File history migration: importing \(legacyItems.count) legacy file record(s) into main history")
        let syncHash = lastSyncHash
        let remoteHashes = Set(recentRemoteHashes.map { $0.hash })
        // `prepareHistoryInsert` already inserts into the DB (and trims once per
        // call). We deliberately let trim run: per the agreed behavior, the main
        // history respects its max-history cap, so legacy file records older than
        // the current window will be naturally evicted — only those recent enough
        // to fit under the limit survive. This keeps a single source of truth and
        // avoids growing the DB beyond the user-configured cap.
        for item in legacyItems.reversed() {
            let url = URL(fileURLWithPath: item.filePath)
            _ = prepareHistoryInsert(
                .files([url]),
                sourceApp: item.senderName,
                sourceBundleId: nil,
                lastKnownSyncHash: syncHash,
                recentRemoteHashes: remoteHashes,
                pasteboardPlainText: nil,
                date: item.timestamp
            )
        }
        appLog("File history migration: imported \(legacyItems.count) legacy record(s) (subject to history cap)")
        reloadLoadedSummaries()
        notifyHistoryChanged()
        archiveLegacyFileHistory()
    }

    private func archiveLegacyFileHistory() {
        let backupURL = fileHistoryURL.deletingPathExtension().appendingPathExtension("json.bak")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: fileHistoryURL, to: backupURL)
            appLog("File history migration: archived legacy file_history.json → \(backupURL.lastPathComponent)")
        } catch {
            appLog("File history migration: failed to archive legacy json: \(error)", level: .warning)
        }
    }

    /// Inserts a file received from a remote peer into the main clipboard
    /// history, so it shows up in the history list, global search, and the
    /// "Files" type filter — matching the behavior of locally-copied files and
    /// remotely-synced text. `addToHistory` is private, hence this wrapper.
    /// Files history entries are stored as URL path references, so no extra
    /// copy is needed; `plainTextForLANSync` returns nil for `.files`, so this
    /// never loops back to other devices.
    func addReceivedFileToHistory(_ url: URL, senderName: String) {
        addToHistory(.files([url]), sourceApp: senderName, sourceBundleId: nil)
    }

    /// Inserts a file the user just sent to a remote peer into the main
    /// clipboard history. Mirrors `addReceivedFileToHistory` so both directions
    /// of a transfer are recorded in the same place. `sourceApp` carries the
    /// recipient so it appears in the history list / source filter.
    func addSentFileToHistory(_ url: URL, recipientName: String) {
        addToHistory(.files([url]), sourceApp: "Me (Sent to \(recipientName))", sourceBundleId: nil)
    }

    
    private func loadHistory() {
        if HistoryMediaStore.shared.consumeLegacyMigrationNeeded() {
            reimportHistoryForLegacyMediaMigration()
        }
        isHistoryCountStale = true
    }

    func ensureMenuSummariesLoaded() {
        isMenuMemoryRetained = true
        recentSummaries = repository.fetchSummaries(limit: menuHistoryLimit)
    }

    func releaseMenuMemory() {
        isMenuMemoryRetained = false
        recentSummaries.removeAll(keepingCapacity: false)
    }

    /// 打开菜单前同步检查剪贴板，避免轮询防抖导致记录滞后。
    func refreshFromPasteboardIfNeeded() {
        guard pasteboard.changeCount != changeCount else { return }
        lastCheckTime = Date()
        pendingContentCheck = false
        // 临时保留内存，让 addToHistory 写入后立即填充 recentSummaries。
        let wasRetained = isMenuMemoryRetained
        isMenuMemoryRetained = true
        // Menu is about to open: ingest synchronously so the new entry is visible now.
        processClipboardContent(synchronous: true)
        if !wasRetained {
            // 调用方通常会立刻 ensureMenuSummariesLoaded；这里也重拉一次确保完整。
            recentSummaries = repository.fetchSummaries(limit: menuHistoryLimit)
        }
    }

    private func reloadLoadedSummaries() {
        isHistoryCountStale = true
        guard isMenuMemoryRetained else { return }
        recentSummaries = repository.fetchSummaries(limit: menuHistoryLimit)
    }

    func resolveEntry(_ summary: HistorySummary) -> HistoryEntry {
        repository.fetchByRowid(summary.rowid) ?? summary.asEntry()
    }

    private func reimportHistoryForLegacyMediaMigration() {
        let all = repository.fetchAll(includeSearchIndex: true)
        for entry in all {
            _ = repository.insertOrReplace(entry)
        }
    }

    /// True while a re-encryption pass is running; the settings toggle stays
    /// disabled until it finishes so the two passes can't interleave.
    private(set) var isReencryptingHistory = false

    /// Flips at-rest encryption and rewrites every referenced media file.
    ///
    /// The rewrite runs off the main thread — with a large history it is
    /// thousands of file reads, AES passes and atomic writes, which used to
    /// freeze the Settings window for the duration.
    @discardableResult
    func setHistoryEncryptionEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) -> Bool {
        let previous = PreferencesManager.shared.isHistoryEncryptionEnabled
        guard previous != enabled else {
            completion?(true)
            return true
        }
        guard !isReencryptingHistory else {
            completion?(false)
            return false
        }

        PreferencesManager.shared.isHistoryEncryptionEnabled = enabled
        isReencryptingHistory = true
        let paths = repository.referencedStoragePaths()
        ingestQueue.async { [weak self] in
            HistoryMediaStore.shared.reencryptReferencedFiles(keeping: paths, wasEncrypted: previous)
            DispatchQueue.main.async {
                self?.isReencryptingHistory = false
                NotificationCenter.default.post(name: .historyEncryptionDidFinish, object: nil)
                completion?(true)
            }
        }
        return true
    }

    private func startPolling() {
        startPollingTimer(interval: minCheckInterval)

        // Idempotent: a second call would otherwise stack duplicate observers,
        // each re-running adjustPollingInterval on every activation.
        guard pollingObserverTokens.isEmpty else { return }

        // Poll fast while the user is interacting with this Mac session; ease off when
        // the app is idle so the RunLoop is not woken 3x per second around the clock.
        let center = NotificationCenter.default
        pollingObserverTokens.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.adjustPollingInterval()
            })
        pollingObserverTokens.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.adjustPollingInterval()
            })
        // Wake events arrive on NSWorkspace's own notification center.
        workspaceObserverTokens.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.adjustPollingInterval()
            })
    }


    private func startPollingTimer(interval: TimeInterval) {
        timer?.invalidate()
        currentPollInterval = interval
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboardWithDebounce()
        }
        newTimer.tolerance = interval * 0.2
        timer = newTimer
    }

    private func adjustPollingInterval() {
        let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
        let desired = (NSApp.isActive || hasVisibleWindows) ? minCheckInterval : idleCheckInterval
        if desired != currentPollInterval {
            startPollingTimer(interval: desired)
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        for token in pollingObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        pollingObserverTokens.removeAll()
        for token in workspaceObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()
    }

    private func checkPasteboardWithDebounce() {
        let now = Date()
        let timeSinceLastCheck = now.timeIntervalSince(lastCheckTime)
        
        // If clipboard hasn't changed, skip processing
        guard pasteboard.changeCount != changeCount else { return }
        
        // Implement debounce: if we've checked recently, delay this check
        if timeSinceLastCheck < minCheckInterval {
            if !pendingContentCheck {
                pendingContentCheck = true
                // Schedule a check after the debounce period
                DispatchQueue.main.asyncAfter(deadline: .now() + (minCheckInterval - timeSinceLastCheck)) { [weak self] in
                    self?.processPendingContentCheck()
                }
            }
            return
        }
        
        // Process immediately if enough time has passed
        lastCheckTime = now
        pendingContentCheck = false
        processClipboardContent()
    }
    
    private func processPendingContentCheck() {
        if pendingContentCheck {
            pendingContentCheck = false
            lastCheckTime = Date()
            processClipboardContent()
        }
    }
    
    private func processClipboardContent(synchronous: Bool = false) {
        changeCount = pasteboard.changeCount

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmostApp?.localizedName
        let bundleIdentifier = frontmostApp?.bundleIdentifier

        // Clipy feature: Exclude sensitive apps (e.g., Password managers)
        if let bundleID = bundleIdentifier, PreferencesManager.shared.excludedApps.contains(bundleID) {
            return
        }

        // Pasteboard reads stay on the main thread; the payload is then plain
        // value data that heavy processing can consume from any thread.
        guard let payload = readPasteboardPayload() else { return }

        // A synchronous ingest is only worth it when it is cheap. Text and file
        // lists need no media-store write, so the entry can be in the menu the
        // moment it opens; images/PDF/RTF mean encoding, hashing and possibly
        // encrypting tens of megabytes, which would stall the menu instead.
        if synchronous && payload.isCheapToIngestSynchronously {
            let item = historyItem(from: payload)
            addToHistory(item, sourceApp: sourceApp, sourceBundleId: bundleIdentifier)
            return
        }

        // Media store writes, SHA256, RTF/HTML/PDF index parsing and the DB insert can
        // take hundreds of ms for large payloads; keep them off the main thread.
        let capturedSyncHash = lastSyncHash
        // Snapshot the loopback set on the main thread (it is mutated here only);
        // the heavy ingest runs off-thread and must not race the live list.
        let capturedRemoteHashes = Set(recentRemoteHashes.map { $0.hash })
        let capturedPlainText = pasteboard.string(forType: .string)
        ingestQueue.async { [weak self] in
            guard let self else { return }
            let item = self.historyItem(from: payload)
            let prepared = self.prepareHistoryInsert(
                item,
                sourceApp: sourceApp,
                sourceBundleId: bundleIdentifier,
                lastKnownSyncHash: capturedSyncHash,
                recentRemoteHashes: capturedRemoteHashes,
                pasteboardPlainText: capturedPlainText
            )
            DispatchQueue.main.async {
                self.finalizeHistoryInsert(prepared)
            }
        }
    }

    private enum PasteboardPayload {
        case files([URL])
        case text(String)
        case rtf(Data)
        case html(Data)
        case pdf(Data)
        case image(Data)

        var isCheapToIngestSynchronously: Bool {
            switch self {
            case .files, .text: return true
            case .rtf, .html, .pdf, .image: return false
            }
        }
    }

    private func readPasteboardPayload() -> PasteboardPayload? {
        if let fileURLs = readFileURLsFromPasteboard(), !fileURLs.isEmpty {
            return .files(fileURLs)
        }
        // Prefer plain text when the pasteboard also carries HTML/RTF (common for browsers and editors).
        if let newString = pasteboard.string(forType: .string), !newString.isEmpty {
            return .text(newString)
        }
        if let rtfData = pasteboard.data(forType: .rtf) {
            return .rtf(rtfData)
        }
        if let htmlData = pasteboard.data(forType: .html) {
            return .html(htmlData)
        }
        if let pdfData = pasteboard.data(forType: .pdf) {
            return .pdf(pdfData)
        }
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            return .image(imageData)
        }
        return nil
    }

    private func historyItem(from payload: PasteboardPayload) -> HistoryItem {
        let store = HistoryMediaStore.shared
        switch payload {
        case .files(let urls):
            return .files(urls)
        case .text(let text):
            return .text(text)
        case .rtf(let data):
            return .rtf(store.store(data: data, kind: .rtf))
        case .html(let data):
            return .html(store.store(data: data, kind: .html))
        case .pdf(let data):
            return .pdf(store.store(data: data, kind: .pdf))
        case .image(let data):
            return .image(store.store(data: data, kind: .image))
        }
    }

    func startPasteUsageMonitoringIfNeeded() {
        guard AccessibilityManager.isTrusted, pasteEventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            // The event is borrowed from the tap machinery, which keeps owning it
            // after the callback returns. passRetained added a +1 nobody balanced,
            // leaking one CGEvent per keystroke.
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let flags = event.flags
                guard flags.contains(.maskCommand),
                      !flags.contains(.maskAlternate),
                      event.getIntegerValueField(.keyboardEventKeycode) == 0x09 else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<ClipboardManager>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.recordUsageIfPasteboardMatchesHistory()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return
        }

        pasteEventTap = tap
        pasteEventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let pasteEventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), pasteEventTapRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func recordUsageIfPasteboardMatchesHistory() {
        guard let payload = readPasteboardPayload() else { return }
        let item = historyItem(from: payload)
        guard let entry = historyEntry(matching: item) else { return }
        recordHistoryUsage(entry)
        moveHistoryEntryToFront(entry)
    }

    private func historyEntry(matching item: HistoryItem) -> HistoryEntry? {
        let hash = contentHash(for: item)
        if let entry = repository.findMatching(item: item, contentHash: hash) {
            return entry
        }
        if case .text(let text) = item {
            return repository.findFileEntryMatchingPlainText(text)
        }
        return nil
    }

    private func moveLoadedSummaryToFront(rowid: Int64, date: Date, isPinned: Bool) {
        guard let index = recentSummaries.firstIndex(where: { $0.rowid == rowid }) else {
            reloadLoadedSummaries()
            return
        }
        var updated = recentSummaries.remove(at: index)
        updated.date = date
        updated.isPinned = isPinned
        recentSummaries.insert(updated, at: 0)
    }

    func ingestCapturedImage(_ pngData: Data, copyToPasteboard: Bool = true) {
        let store = HistoryMediaStore.shared
        let path = store.store(data: pngData, kind: .image)
        let item = HistoryItem.image(path)
        if let hash = contentHash(for: item) {
            lastSyncHash = hash
        }
        addToHistory(item, sourceApp: "Clipy Screenshot", sourceBundleId: Bundle.main.bundleIdentifier)
        if copyToPasteboard {
            writeToPasteboard(item)
        }
    }

    private struct PreparedHistoryInsert {
        let entry: HistoryEntry
        let hash: String?
    }

    private func addToHistory(_ item: HistoryItem, sourceApp: String?, sourceBundleId: String? = nil, date: Date? = nil) {
        let prepared = prepareHistoryInsert(
            item,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            lastKnownSyncHash: lastSyncHash,
            recentRemoteHashes: Set(recentRemoteHashes.map { $0.hash }),
            pasteboardPlainText: pasteboard.string(forType: .string),
            date: date
        )
        finalizeHistoryInsert(prepared)
    }

    /// Heavy half of the insert (hashing, index build, DB write). Safe on any thread:
    /// the repository is internally serialized and the media store only touches disk.
    ///
    /// `pasteboardPlainText` must be sampled by the caller on the main thread —
    /// NSPasteboard is not thread-safe and this runs on `ingestQueue`.
    private func prepareHistoryInsert(
        _ item: HistoryItem,
        sourceApp: String?,
        sourceBundleId: String?,
        lastKnownSyncHash: String?,
        recentRemoteHashes: Set<String>,
        pasteboardPlainText: String?,
        date: Date? = nil
    ) -> PreparedHistoryInsert {
        let hash = contentHash(for: item)
        appLog("Adding to history: \(item.title), Hash: \(hash?.prefix(8) ?? "N/A")")

        // Broadcast unless this content was just delivered by a remote peer
        // (loopback). Both the single-slot lastKnownSyncHash and the time-windowed
        // set are checked: either match means we keep it local.
        if let sync = plainTextForLANSync(from: item, pasteboardPlainText: pasteboardPlainText),
           sync.hash != lastKnownSyncHash,
           !recentRemoteHashes.contains(sync.hash) {
            SyncManager.shared.broadcastSync(content: sync.text, hash: sync.hash)
        }

        let searchIndex = HistorySearchIndexBuilder.buildIndex(for: item)
        let existing = repository.findMatching(item: item, contentHash: hash)
        let entry = HistoryEntry(
            item: item,
            date: date ?? Date(),
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            contentHash: hash,
            isPinned: existing?.isPinned ?? false,
            searchIndex: searchIndex,
            lastUsedAt: existing?.lastUsedAt,
            useCount: existing?.useCount ?? 0
        )

        _ = repository.insertOrReplace(entry)
        repository.trimToLimit(maxHistoryItems)
        return PreparedHistoryInsert(entry: entry, hash: hash)
    }

    /// Main-thread half: updates in-memory summaries and notifies the UI.
    private func finalizeHistoryInsert(_ prepared: PreparedHistoryInsert) {
        reloadLoadedSummaries()

        scheduleImageOCRIfNeeded(for: prepared.entry)

        if let hash = prepared.hash {
            recentContentHashes.insert(hash)
            if recentContentHashes.count > recentContentHashesMaxSize {
                updateRecentContentHashes()
            }
        }

        notifyHistoryChanged()
    }

    private func notifyHistoryChanged() {
        onHistoryChanged?()
        NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
    }
    
    func handleRemoteSync(content: String, hash: String) {
        let effectiveHash = hash.isEmpty
            ? (contentHash(for: .text(content)) ?? UUID().uuidString)
            : hash
        appLog("Handling remote sync: \(effectiveHash.prefix(8))")

        lastSyncHash = effectiveHash
        rememberRemoteHash(effectiveHash)

        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        changeCount = pasteboard.changeCount

        addToHistory(.text(content), sourceApp: "Remote Device")
    }

    /// A file received over LAN sync, already moved to its final destination.
    /// Unlike text sync the pasteboard is not touched — the entry appears in
    /// history / search with the usual "reveal in Finder" affordances.
    /// Main thread only (addToHistory touches main-thread state).
    func handleRemoteFileSync(url: URL, senderName: String) {
        rememberRemoteHash("file:\(url.path)")
        addToHistory(.files([url]), sourceApp: senderName.isEmpty ? "Remote Device" : senderName)
    }

    /// Records a remote-origin hash so a subsequent local copy of the same
    /// content is treated as a loopback rather than re-broadcast.
    private func rememberRemoteHash(_ hash: String) {
        recentRemoteHashes.append((hash: hash, at: Date()))
        pruneRemoteHashes()
    }

    private func wasRecentlyRemote(_ hash: String) -> Bool {
        pruneRemoteHashes()
        return recentRemoteHashes.contains { $0.hash == hash }
    }

    private func pruneRemoteHashes() {
        let cutoff = Date().addingTimeInterval(-Self.recentRemoteHashTTL)
        recentRemoteHashes.removeAll { $0.at < cutoff }
        while recentRemoteHashes.count > Self.recentRemoteHashMax {
            recentRemoteHashes.removeFirst()
        }
    }

    func contentHashForPlainText(_ text: String) -> String? {
        contentHash(for: .text(text))
    }

    func availableSourceApps() -> [String] {
        repository.distinctSourceApps()
    }

    func searchHistory(
        query: String,
        typeFilter: HistoryTypeFilter = .all,
        sourceApp: String? = nil
    ) -> [HistoryEntry] {
        searchHistory(options: SearchHistoryOptions(
            query: query,
            typeFilter: typeFilter,
            sourceApp: sourceApp
        )).map(\.entry)
    }

    func searchHistory(options: SearchHistoryOptions) -> [HistorySearchResult] {
        let parsed = HistorySearchQueryParser.parse(options.query)
        let effectiveType = parsed.typeFilter ?? options.typeFilter
        let effectiveSource = parsed.sourceApp ?? options.sourceApp
        let effectivePinnedOnly = parsed.pinnedOnly || options.pinnedOnly
        let effectivePath = parsed.pathContains ?? options.pathContains
        let effectiveURLOnly = parsed.urlOnly || options.urlOnly
        let textQuery = parsed.textTerms.joined(separator: " ")

        let trimmed = textQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let browseLoadedOnly = trimmed.isEmpty && !hasActiveSearchFilters(
            options: options,
            effectiveType: effectiveType,
            effectiveSource: effectiveSource,
            effectivePinnedOnly: effectivePinnedOnly,
            effectivePath: effectivePath,
            effectiveURLOnly: effectiveURLOnly
        )
        let filters = SearchHistoryFilters(
            typeFilter: effectiveType,
            sourceApp: effectiveSource,
            dateFilter: options.dateFilter,
            pinnedOnly: effectivePinnedOnly,
            pathContains: effectivePath,
            urlOnly: effectiveURLOnly
        )
        let ordered = browseLoadedOnly
            ? repository.fetch(limit: options.browseLimit ?? menuHistoryLimit)
            : repository.fetchFiltered(
                filters: filters,
                textQuery: trimmed.isEmpty ? nil : trimmed,
                includeSearchIndex: false,
                limit: maxHistoryItems
            )
        let filtered = ordered.filter { entry in
            if let category = options.contentCategory, !category.matches(entry) {
                return false
            }
            if effectiveURLOnly {
                let text = entry.resolvedText ?? entry.item.title
                guard text.contains("://") else { return false }
            }
            return true
        }

        guard !trimmed.isEmpty else {
            return filtered.map {
                HistorySearchResult(entry: $0, highlightRanges: [])
            }
        }

        return HistorySearchRanker.rank(
            entries: filtered,
            query: trimmed,
            useRegex: options.useRegex,
            loadFullTextIfNeeded: true
        )
    }

    private func hasActiveSearchFilters(
        options: SearchHistoryOptions,
        effectiveType: HistoryTypeFilter,
        effectiveSource: String?,
        effectivePinnedOnly: Bool,
        effectivePath: String?,
        effectiveURLOnly: Bool
    ) -> Bool {
        effectiveType != .all
            || effectiveSource != nil
            || effectivePinnedOnly
            || effectivePath != nil
            || effectiveURLOnly
            || options.contentCategory != nil
            || options.dateFilter != .all
    }

    func removeHistoryEntry(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.delete(contentHash: hash, item: entry.item) else { return }
        reloadLoadedSummaries()
        updateRecentContentHashes()
        schedulePruneUnreferencedMediaFiles()
        notifyHistoryChanged()
    }

    func removeHistoryEntries(_ entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        var removed = false
        for entry in entries {
            let hash = entry.contentHash ?? contentHash(for: entry.item)
            if repository.delete(contentHash: hash, item: entry.item) {
                removed = true
            }
        }
        guard removed else { return }
        reloadLoadedSummaries()
        updateRecentContentHashes()
        schedulePruneUnreferencedMediaFiles()
        notifyHistoryChanged()
    }

    func recordHistoryUsage(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.update(contentHash: hash, item: entry.item, transform: { stored in
            stored.useCount += 1
            stored.lastUsedAt = Date()
        }) != nil else { return }
    }

    func togglePin(for entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.update(contentHash: hash, item: entry.item, transform: { stored in
            stored.isPinned.toggle()
            stored.date = Date()
        }) != nil else { return }
        reloadLoadedSummaries()
        notifyHistoryChanged()
    }

    func clearHistory() {
        _ = repository.deleteAll()
        HistoryMediaStore.shared.removeAllManagedFiles()
        HistoryThumbnailCache.removeAllThumbnailFiles()
        reloadLoadedSummaries()
        updateRecentContentHashes()
        notifyHistoryChanged()
    }

    func applyHistoryLimit() {
        let previousTotal = totalHistoryCount
        repository.trimToLimit(maxHistoryItems)
        reloadLoadedSummaries()
        guard totalHistoryCount != previousTotal else { return }
        updateRecentContentHashes()
        schedulePruneUnreferencedMediaFiles()
        notifyHistoryChanged()
    }

    func moveHistoryEntryToFront(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard let updated = repository.update(contentHash: hash, item: entry.item, transform: { stored in
            stored.date = Date()
        }) else { return }
        if let rowid = repository.fetchRowid(contentHash: hash, item: entry.item) {
            moveLoadedSummaryToFront(rowid: rowid, date: updated.date, isPinned: updated.isPinned)
        } else {
            reloadLoadedSummaries()
        }
        updateRecentContentHashes()
        notifyHistoryChanged()
    }

    /// Full-table path scan + directory walk; debounced and run off the main thread.
    private func schedulePruneUnreferencedMediaFiles() {
        pruneWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let referenced = self.repository.referencedStoragePaths()
            HistoryMediaStore.shared.removeUnreferencedFiles(keeping: referenced)
            HistoryThumbnailCache.pruneUnreferenced(keepingSourcePaths: referenced)
        }
        pruneWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: work)
    }

    func writePlainTextToPasteboard(_ item: HistoryItem, textPath: String? = nil) {
        pasteboard.clearContents()
        if let text = plainText(for: item, textPath: textPath) {
            pasteboard.setString(text, forType: .string)
            changeCount = pasteboard.changeCount
        }
    }

    func plainText(for item: HistoryItem, textPath: String? = nil) -> String? {
        if let textPath, let text = HistoryMediaStore.shared.text(at: textPath) {
            return text
        }
        switch item {
        case .text(let str):
            return str
        case .rtf(let path):
            return HistorySearchIndexBuilder.buildIndex(for: .rtf(path))
        case .html(let path):
            return HistorySearchIndexBuilder.buildIndex(for: .html(path))
        case .pdf(let path):
            return HistorySearchIndexBuilder.buildIndex(for: .pdf(path))
        case .image:
            return nil
        case .files(let urls):
            return urls.map(\.lastPathComponent).joined(separator: "\n")
        }
    }

    func plainText(for entry: HistoryEntry) -> String? {
        plainText(for: entry.item, textPath: entry.textPath)
    }

    func applyHistoryEntry(_ entry: HistoryEntry, action: HistorySelectAction) {
        switch action {
        case .copyOnly:
            if case .files(let urls) = entry.item {
                writeFileNamesToPasteboard(urls)
            } else {
                writeToPasteboard(entry.item, textPath: entry.textPath)
            }
            moveHistoryEntryToFront(entry)
        case .pastePlainAndClose, .pastePlainKeepOpen:
            writePlainTextToPasteboard(entry.item, textPath: entry.textPath)
            moveHistoryEntryToFront(entry)
            let keepOpen = action == .pastePlainKeepOpen
            if !keepOpen { SearchWindow.shared.closeWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.simulatePasteIfTrusted() }
        case .pasteKeepOpen:
            performPaste(entry: entry, pasteFileAsName: true, closeWindow: false)
        case .pasteAndClose:
            performPaste(entry: entry, pasteFileAsName: true, closeWindow: true)
        }
    }

    private func performPaste(entry: HistoryEntry, pasteFileAsName: Bool, closeWindow: Bool) {
        moveHistoryEntryToFront(entry)

        let shouldAutoPaste: Bool
        if case .files(let urls) = entry.item, pasteFileAsName {
            writeFileNamesToPasteboard(urls)
            shouldAutoPaste = true
        } else if case .files = entry.item {
            writeToPasteboard(entry.item)
            shouldAutoPaste = false
        } else {
            writeToPasteboard(entry.item, textPath: entry.textPath)
            shouldAutoPaste = itemSupportsAutoPaste(entry.item)
        }

        if closeWindow {
            SearchWindow.shared.closeWindow()
        }

        guard shouldAutoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.simulatePasteIfTrusted() }
    }

    private func backfillSearchIndexesIfNeeded() {
        let pending = repository.entriesNeedingSearchIndex(limit: 100)
        guard !pending.isEmpty else { return }

        var changed = false
        for entry in pending {
            if let built = buildSearchIndex(for: entry) {
                if let hash = entry.contentHash {
                    if repository.updateSearchIndex(contentHash: hash, text: built) {
                        changed = true
                    }
                }
            }
            scheduleImageOCRIfNeeded(for: entry)
        }
        if changed {
            notifyHistoryChanged()
        }
    }

    private func buildSearchIndex(for entry: HistoryEntry) -> String? {
        if case .text = entry.item { return nil }
        return HistorySearchIndexBuilder.buildIndex(for: entry.item)
    }

    private func scheduleImageOCRIfNeeded(for entry: HistoryEntry) {
        guard case .image = entry.item, let hash = entry.contentHash else { return }
        // Ingesting any image (paste, screenshot, sync) decodes the full
        // bitmap and briefly holds several large buffers; schedule the
        // debounced reclaim that presses the pages back to the system.
        MemoryFootprintReclaimer.scheduleDelayedReclaim()
        // Each recognition keeps Vision's models resident (~100MB, first use,
        // not releasable); the preference lets users trade searchable image
        // history for the standing footprint.
        guard PreferencesManager.shared.isHistoryImageOCRIndexingEnabled else { return }
        guard !pendingIndexHashes.contains(hash) else { return }
        pendingIndexHashes.insert(hash)
        HistorySearchIndexBuilder.scheduleOCR(for: entry, contentHash: hash) { [weak self] contentHash, text in
            guard let self else { return }
            self.pendingIndexHashes.remove(contentHash)
            if self.pendingIndexHashes.isEmpty {
                // OCR is the last big allocator in a capture flow: Vision loads
                // its models and staging buffers on first use and regularly
                // outlives the 10s delayed reclaim (serial utility queue).
                // Re-arm once the queue drains so those pages are returned too.
                MemoryFootprintReclaimer.scheduleDelayedReclaim()
            }
            // Empty text = unreadable image or no OCR result; the hash is
            // still cleared above so future edits can retry indexing.
            guard !text.isEmpty else { return }
            if self.repository.updateSearchIndex(contentHash: contentHash, text: text) {
                self.notifyHistoryChanged()
            }
        }
    }

    func writeToPasteboard(_ item: HistoryItem, textPath: String? = nil) {
        let store = HistoryMediaStore.shared
        pasteboard.clearContents()
        switch item {
        case .text:
            if let text = plainText(for: item, textPath: textPath) {
                pasteboard.setString(text, forType: .string)
            }
        case .image(let path):
            if let data = store.data(at: path) {
                // HistoryMediaStore persists images as PNG; declaring them
                // .tiff made receivers try (and fail) to decode PNG bytes as TIFF.
                pasteboard.setData(data, forType: .png)
            }
        case .rtf(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .rtf)
            }
        case .pdf(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .pdf)
            }
        case .html(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .html)
                if let str = HistoryPreviewSupport.htmlString(from: data) {
                    pasteboard.setString(str, forType: .string)
                }
                let fileURLs = fileURLsFromHTMLData(data)
                if !fileURLs.isEmpty {
                    pasteboard.writeObjects(fileURLs as [NSURL])
                }
            }
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
        changeCount = pasteboard.changeCount
    }

    func writeFileNamesToPasteboard(_ urls: [URL]) {
        let text = urls.map(\.lastPathComponent).joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCount = pasteboard.changeCount
    }

    func copyFileNamesToPasteboard(_ urls: [URL], simulatePaste: Bool = true) {
        writeFileNamesToPasteboard(urls)
        guard simulatePaste, AccessibilityManager.ensureTrustedForPaste() else { return }
        paste()
    }

    func copyToPasteboard(_ item: HistoryItem, simulatePaste: Bool = true) {
        writeToPasteboard(item)
        if case .files = item { return }
        guard simulatePaste, itemSupportsAutoPaste(item) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.simulatePasteIfTrusted()
        }
    }

    private func itemSupportsAutoPaste(_ item: HistoryItem) -> Bool {
        switch item {
        case .text, .html, .rtf:
            return true
        default:
            return false
        }
    }

    func simulatePasteIfTrusted() {
        startPasteUsageMonitoringIfNeeded()
        guard AccessibilityManager.ensureTrustedForPaste() else { return }
        paste()
    }
    
    private func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // Command + V Key Down
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        
        // Command + V Key Up
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyUp?.flags = .maskCommand
        
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }
    
    private func isSameHistoryItem(_ entry: HistoryEntry, as item: HistoryItem, contentHash hash: String?) -> Bool {
        if let existingHash = entry.contentHash, let hash = hash {
            return existingHash == hash
        }
        
        switch (entry.item, item) {
        case (.text(let s1), .text(let s2)):
            return s1 == s2
        case (.files(let u1), .files(let u2)):
            return u1 == u2
        case (.image(let p1), .image(let p2)),
             (.rtf(let p1), .rtf(let p2)),
             (.pdf(let p1), .pdf(let p2)),
             (.html(let p1), .html(let p2)):
            return p1 == p2
        default:
            return false
        }
    }

    /// Resolves LAN-syncable plain text even when history stores HTML/RTF rich content.
    private func plainTextForLANSync(
        from item: HistoryItem,
        pasteboardPlainText: String?
    ) -> (text: String, hash: String)? {
        if let pasted = pasteboardPlainText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pasted.isEmpty,
           let hash = contentHash(for: .text(pasted)) {
            return (pasted, hash)
        }

        if case .text(let str) = item, let hash = contentHash(for: item) {
            return (str, hash)
        }

        let store = HistoryMediaStore.shared
        switch item {
        case .html(let path):
            guard let data = store.data(at: path),
                  let html = HistoryPreviewSupport.htmlString(from: data) else { return nil }
            let plain = stripHTMLTags(html).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty, let hash = contentHash(for: .text(plain)) else { return nil }
            return (plain, hash)
        case .rtf(let path):
            guard let data = store.data(at: path),
                  let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
            let plain = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty, let hash = contentHash(for: .text(plain)) else { return nil }
            return (plain, hash)
        default:
            return nil
        }
    }

    private func stripHTMLTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    
    private func contentHash(for item: HistoryItem) -> String? {
        switch item {
        case .text(let str):
            let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard let data = normalized.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        case .image(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .rtf(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .pdf(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .html(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .files(let urls):
            let s = urls.map(\.absoluteString).joined(separator: "\n")
            guard let data = s.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        }
    }

    private func readFileURLsFromPasteboard() -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty {
            return urls
        }

        let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacyType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }

        if let fileURLString = pasteboard.string(forType: .fileURL) {
            if let url = URL(string: fileURLString), url.isFileURL {
                return [url]
            }
            if fileURLString.hasPrefix("/") {
                return [URL(fileURLWithPath: fileURLString)]
            }
        }

        return nil
    }

    private func fileURLsFromHTMLData(_ data: Data) -> [URL] {
        guard let html = HistoryPreviewSupport.htmlString(from: data) else { return [] }
        return fileURLsFromHTML(html)
    }

    private func fileURLsFromHTML(_ html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href=\"(file://[^\"]+)\""#,
            options: .caseInsensitive
        ) else { return [] }

        var urls: [URL] = []
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let urlRange = Range(match.range(at: 1), in: html) else { return }
            let urlString = String(html[urlRange])
            if let url = URL(string: urlString), url.isFileURL {
                urls.append(url)
            }
        }
        return urls
    }

    func revealInFinder(for entry: HistoryEntry) {
        guard let urls = entry.item.fileURLs else { return }
        FilePathDisplay.revealInFinder(urls: urls)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
