package com.clipyclone.nativeandroid.notifications

import android.content.Context
import android.util.Log
import com.clipyclone.clipy_android.NativePendingPostStore
import com.clipyclone.nativeandroid.data.ClipyDatabase
import com.clipyclone.nativeandroid.data.NotificationRepository
import com.clipyclone.nativeandroid.sync.FlutterStringLists
import com.clipyclone.nativeandroid.sync.SyncCrypto
import com.clipyclone.nativeandroid.sync.SyncEnvelope
import com.clipyclone.nativeandroid.sync.SyncType
import com.clipyclone.nativeandroid.sync.SYNC_VERSION
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/** App-owned collection, persistence, offline queue and peer messages; never owned by an Activity. */
class NativeNotificationManager(
    private val context: Context, ownerScope: CoroutineScope, private val crypto: SyncCrypto,
    private val broadcast: suspend (type: String, content: String, hash: String) -> Unit,
    private val acknowledge: suspend (peerId: String, notificationId: String) -> Unit,
    private val databaseFile: File = File(context.filesDir, "clipy.db"),
    private val attachListener: Boolean = true,
    preferences: android.content.SharedPreferences? = null,
) : NativeNotificationSink {
    val platform = NotificationPlatform(context)
    private val prefs = preferences ?: context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob(ownerScope.coroutineContext[Job]) + Dispatchers.Default + CoroutineExceptionHandler { _, e -> Log.w("ClipyNotifications", e.javaClass.simpleName) })
    private val initialization = Mutex(); private val storageLock = Mutex(); private val prefsLock = Mutex()
    private val recoveryLock = Mutex(); private val refreshLock = Mutex(); private val drainLock = Mutex(); private val flushLock = Mutex(); private val healthLock = Mutex()
    @Volatile private var initialized = false
    private val mutable = MutableStateFlow(NotificationState())
    val state = mutable.asStateFlow()
    private val version = MutableStateFlow(0L); val revision = version.asStateFlow()
    private val lastId = AtomicLong()
    private val postedSignal = Channel<Unit>(Channel.CONFLATED)
    private var healthJob: Job? = null
    @Volatile private var foreground = false
    @Volatile private var installed: Pair<Long, List<InstalledNotificationApp>>? = null
    private val appCacheGeneration = AtomicLong()
    init { scope.launch { for (signal in postedSignal) drainNativePendingPosts() } }
    private suspend fun <T> database(block: (NotificationRepository) -> T): T = withContext(Dispatchers.IO) {
        storageLock.withLock { ClipyDatabase(context, databaseFile).use { block(NotificationRepository(it)) } }
    }
    private fun changed() { version.update { it + 1 } }
    private fun self(pkg: String) = pkg == context.packageName || pkg == "com.clipyclone.clipy_android"
    fun isCollected(pkg: String) = !self(pkg) && (mutable.value.collected.isEmpty() || pkg in mutable.value.collected)
    fun isSynced(pkg: String) = !self(pkg) && (mutable.value.synced.isEmpty() || pkg in mutable.value.synced)
    suspend fun initialize() {
        if (initialized) return
        initialization.withLock {
            if (initialized) return@withLock
            val settings = withContext(Dispatchers.IO) {
                val legacy = FlutterStringLists.decode(prefs.all["flutter.notificationAllowedPackages"])
                val collected = legacy ?: FlutterStringLists.decode(prefs.all["flutter.notificationCollectedPackages"]) ?: emptyList()
                val synced = FlutterStringLists.decode(prefs.all["flutter.notificationSyncedPackages"]) ?: emptyList()
                if (legacy != null) check(prefs.edit().remove("flutter.notificationAllowedPackages")
                    .putString("flutter.notificationCollectedPackages", FlutterStringLists.encode(collected)).commit())
                Triple(prefs.getBoolean("flutter.notificationSyncEnabled", false), collected.toSet(), synced.toSet())
            }
            mutable.value = mutable.value.copy(initialized = true, enabled = settings.first, collected = settings.second, synced = settings.third,
                listener = platform.status(), batteryExempt = platform.batteryExempt(), notificationsAllowed = platform.notificationsAllowed(), monitoringStartedAt = System.currentTimeMillis())
            initialized = true
            if (attachListener) NativeNotificationBridge.sink = this
            if (settings.first && attachListener) scope.launch { recoverIfEnabled() }
        }
    }
    /** One-shot startup/sticky-service recovery; no background polling is introduced. */
    suspend fun recoverIfEnabled() {
        initialize()
        if (!mutable.value.enabled || !recoveryLock.tryLock()) return
        try {
            drainNativePendingPosts()
            refreshActiveNotifications() // already requests soft rebind when the service is absent
            checkHealth() // bounded soft→force fallback also runs when there is no Activity
            startHealthIfNeeded()
        } finally { recoveryLock.unlock() }
    }
    override fun posted() { postedSignal.trySend(Unit) }
    override fun removed(data: Map<String, Any?>) { scope.launch {
        initialize()
        val key = data["key"] as? String ?: return@launch
        val pkg = data["packageName"] as? String ?: ""
        database { it.removeKey(key) }; changed()
        broadcast(SyncType.NOTIF_DISMISS, dismissJson(pkg, key, null), "")
    } }
    override fun connectionChanged(connected: Boolean) { scope.launch {
        initialize()
        mutable.update { it.copy(listener = platform.status(), lastNotificationAt = if (connected) it.lastNotificationAt ?: System.currentTimeMillis() else it.lastNotificationAt) }
        if (mutable.value.enabled) { if (connected) refreshActiveNotifications() else platform.rebind() }
        changed()
    } }
    suspend fun drainNativePendingPosts() {
        initialize()
        if (!mutable.value.enabled) return
        drainLock.withLock {
            val rows = withContext(Dispatchers.IO) { NativePendingPostStore.peek(context) }
            for (row in rows) {
                val obj = try { JSONObject(row.payload) } catch (_: org.json.JSONException) {
                    withContext(Dispatchers.IO) { NativePendingPostStore.remove(context, row.rowId) }
                    continue
                }
                try {
                    post(obj, allowBroadcast = true)
                    withContext(Dispatchers.IO) { NativePendingPostStore.remove(context, row.rowId) }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { break /* Keep durable pending for retry. */ }
            }
        }
    }
    internal suspend fun ingestPosted(data: JSONObject) { initialize(); post(data, allowBroadcast = true) }
    private suspend fun post(data: JSONObject, allowBroadcast: Boolean) {
        if (!mutable.value.enabled) return
        val pkg = data.optString("packageName", "")
        if (!self(pkg) && mutable.value.collected.isNotEmpty() && pkg !in mutable.value.collected) return
        val key = data.opt("key") as? String
        val micros = lastId.updateAndGet { maxOf(it + 1, System.currentTimeMillis() * 1000) }
        val extras = data.optJSONObject("extras")?.let { e -> e.keys().asSequence().associateWith { e.opt(it)?.takeUnless { v -> v == JSONObject.NULL }?.toString() ?: "" } } ?: emptyMap()
        val entry = NotificationEntry("${micros}_${key ?: pkg}", key, pkg, data.optString("appName", pkg), data.optString("title", ""), data.opt("subtitle") as? String,
            data.optString("body", ""), data.optLong("postTime", System.currentTimeMillis()), data.opt("groupKey") as? String,
            data.optBoolean("isClearable", true), extras = extras)
        val result = database { it.upsert(entry) }
        if (!result.accepted) return
        mutable.update { it.copy(lastNotificationAt = System.currentTimeMillis()) }
        if (allowBroadcast && isSynced(pkg)) {
            flushLock.withLock {
                database { repository -> result.replaced.forEach { repository.removePending(it.id) }; repository.enqueue(entry) }
                for (old in result.replaced) sendSafely(SyncType.NOTIF_DISMISS, dismissJson(old.packageName, old.notificationKey, old.groupKey), "")
                sendSafely(SyncType.NOTIF_POST, entry.json().toString(), entry.id)
            }
        }
        changed()
    }
    private suspend fun queue(entry: NotificationEntry) = flushLock.withLock {
        database { it.enqueue(entry) }
        sendSafely(SyncType.NOTIF_POST, entry.json().toString(), entry.id)
    }
    private suspend fun sendSafely(type: String, content: String, hash: String) {
        try { broadcast(type, content, hash) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { Log.w("ClipyNotifications", "Notification dispatch failed: ${error.javaClass.simpleName}") }
    }
    suspend fun receive(peerId: String, frame: SyncEnvelope) {
        initialize()
        if (frame.v != SYNC_VERSION) return
        when (frame.type) {
            SyncType.NOTIF_POST -> {
                val plain = frame.payload?.let(crypto::decryptText) ?: return
                try {
                    val entry = NotificationEntry.fromJson(JSONObject(plain))
                    val result = database { it.upsert(entry) }
                    if (result.accepted) changed()
                    acknowledge(peerId, entry.id) // duplicates ACK too; a prior receipt may have been lost.
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { /* No ACK before successful persistence. */ }
            }
            SyncType.NOTIF_ACK -> frame.hash?.takeIf { it.isNotEmpty() }?.let { id -> database { it.removePending(id); it.markSynced(id) } }
            SyncType.NOTIF_DISMISS -> frame.payload?.let(crypto::decryptText)?.let { text ->
                val request = runCatching { JSONObject(text) }.getOrNull() ?: return
                platform.dismiss(request.optString("packageName"), request.opt("notificationKey") as? String)
            }
            SyncType.NOTIF_CLEAR -> { platform.clearStatusBar(); database { it.clear() }; changed() }
            SyncType.NOTIF_CONFIG -> Unit
        }
    }
    suspend fun refreshActiveNotifications() {
        initialize()
        if (!mutable.value.enabled) return
        refreshLock.withLock {
            platform.active().forEach { post(JSONObject(it), allowBroadcast = false) }
            val pending = database { it.pendingIds() }
            database { it.unsynced() }.filter { !it.isArchived && !self(it.packageName) && isSynced(it.packageName) && it.id !in pending }.forEach { queue(it) }
        }
        mutable.update { it.copy(listener = platform.status()) }
    }
    suspend fun hasPending(): Boolean { initialize(); return database { it.hasPending() } }
    suspend fun flushPending() {
        initialize()
        if (!flushLock.tryLock()) return
        try {
            database { it.cleanPending() }
            for (id in database { it.pendingIds() }) {
                val item = database { it.pendingItem(id) } ?: continue
                sendSafely(SyncType.NOTIF_POST, item.second, item.first)
            }
        } finally { flushLock.unlock() }
    }
    suspend fun snapshot(expanded: Set<String>): NotificationSnapshot {
        initialize()
        return database { repo ->
            val groups = repo.groups()
            NotificationSnapshot(repo.count(), repo.packageCount(), groups,
                groups.filter { it.packageName in expanded }.associate { it.packageName to repo.byPackage(it.packageName) })
        }
    }
    suspend fun forPackage(pkg: String, limit: Int = 500): List<NotificationEntry> = database { it.byPackage(pkg, limit = limit) }
    suspend fun remove(id: String) { database { it.remove(id) }; changed() }
    suspend fun clearLocal() { database { it.clear() }; changed() }
    suspend fun dismissRemote(entry: NotificationEntry) { broadcast(SyncType.NOTIF_DISMISS, dismissJson(entry.packageName, entry.notificationKey, entry.groupKey), ""); remove(entry.id) }
    suspend fun clearRemote() { broadcast(SyncType.NOTIF_CLEAR, "{}", "") }
    fun open(entry: NotificationEntry) = platform.open(entry)
    private suspend fun commitSettings(editor: android.content.SharedPreferences.Editor, publish: () -> Unit) = withContext(NonCancellable) {
        withContext(Dispatchers.IO) { check(editor.commit()) }
        publish()
    }
    suspend fun setEnabled(enabled: Boolean) {
        initialize()
        prefsLock.withLock {
            commitSettings(prefs.edit().putBoolean("flutter.notificationSyncEnabled", enabled)) {
                mutable.update { it.copy(enabled = enabled) }
                if (enabled) scope.launch { recoverIfEnabled() }
                else { healthJob?.cancel(); healthJob = null }
            }
        }
    }
    suspend fun installedApps(force: Boolean = false): List<InstalledNotificationApp> {
        val cached = installed
        if (!force && cached != null && System.currentTimeMillis() - cached.first < 600000) return cached.second
        val generation = appCacheGeneration.get()
        return withContext(Dispatchers.IO) { platform.installedApps().also { if (appCacheGeneration.get() == generation) installed = System.currentTimeMillis() to it } }
    }
    fun evictInstalledApps() { appCacheGeneration.incrementAndGet(); installed = null }
    private suspend fun knownPackages(): Set<String> = (database { it.packages() } + installedApps().map { it.packageName }).filterNot(::self).toSet()
    suspend fun setCollected(pkg: String, enabled: Boolean) {
        initialize(); if (self(pkg)) return
        prefsLock.withLock {
            val old = mutable.value
            val next = if (old.collected.isEmpty()) { if (enabled) emptySet() else knownPackages() - pkg } else if (enabled) old.collected + pkg else old.collected - pkg
            val synced = if (old.collected.isNotEmpty() && !enabled && pkg in old.synced) old.synced - pkg else old.synced
            commitSettings(prefs.edit().putString("flutter.notificationCollectedPackages", FlutterStringLists.encode(next.sorted()))
                .putString("flutter.notificationSyncedPackages", FlutterStringLists.encode(synced.sorted()))) {
                mutable.update { it.copy(collected = next, synced = synced) }; changed()
            }
        }
    }
    suspend fun setSynced(pkg: String, enabled: Boolean) {
        initialize(); if (self(pkg)) return
        prefsLock.withLock {
            val old = mutable.value.synced
            val next = if (old.isEmpty()) { if (enabled) emptySet() else knownPackages() - pkg } else if (enabled) old + pkg else old - pkg
            commitSettings(prefs.edit().putString("flutter.notificationSyncedPackages", FlutterStringLists.encode(next.sorted()))) {
                mutable.update { it.copy(synced = next) }; changed()
            }
        }
    }
    suspend fun collectAll() { initialize(); prefsLock.withLock { commitSettings(prefs.edit().remove("flutter.notificationCollectedPackages")) { mutable.update { it.copy(collected = emptySet()) }; changed() } } }
    suspend fun syncAll() { initialize(); prefsLock.withLock { commitSettings(prefs.edit().remove("flutter.notificationSyncedPackages")) { mutable.update { it.copy(synced = emptySet()) }; changed() } } }
    fun setForeground(value: Boolean) { foreground = value; if (value) scope.launch { initialize(); checkHealth(); startHealthIfNeeded() } else { healthJob?.cancel(); healthJob = null } }
    private fun startHealthIfNeeded() {
        if (!foreground || !mutable.value.enabled || !platform.status().permission || healthJob?.isActive == true) return
        healthJob = scope.launch { while (isActive && foreground && mutable.value.enabled) { delay(45000); checkHealth() } }
    }
    internal suspend fun awaitCollectionIdle() {
        refreshLock.withLock { }
        drainLock.withLock { }
        storageLock.withLock { }
    }
    /** Re-read settings after a controlled restore/migration without replacing unrelated keys. */
    internal suspend fun reloadPreferences() {
        initialize()
        prefsLock.withLock {
            val values = withContext(Dispatchers.IO) {
                Triple(prefs.getBoolean("flutter.notificationSyncEnabled", false),
                    FlutterStringLists.decode(prefs.all["flutter.notificationCollectedPackages"])?.toSet() ?: emptySet(),
                    FlutterStringLists.decode(prefs.all["flutter.notificationSyncedPackages"])?.toSet() ?: emptySet())
            }
            mutable.update { it.copy(enabled = values.first, collected = values.second, synced = values.third) }
            if (!values.first) { healthJob?.cancel(); healthJob = null } else startHealthIfNeeded()
            changed()
        }
    }
    suspend fun refreshStatus() {
        initialize()
        val before = mutable.value.listener.permission
        val status = platform.status()
        mutable.update { it.copy(listener = status, batteryExempt = platform.batteryExempt(), notificationsAllowed = platform.notificationsAllowed()) }
        if (!before && status.permission && mutable.value.enabled) refreshActiveNotifications()
    }
    suspend fun checkHealth(): NotificationState {
        initialize()
        healthLock.withLock {
            var listener = platform.status()
            if (mutable.value.enabled && listener.permission && !listener.connected) {
                platform.rebind(); delay(2000); listener = platform.status()
                if (!listener.connected) { platform.rebind(force = true); delay(3000); listener = platform.status() }
            }
            val battery = platform.batteryExempt(); val now = System.currentTimeMillis(); val previous = mutable.value
            val issue = when {
                !previous.enabled -> NotificationHealthIssue.NONE
                !listener.permission -> NotificationHealthIssue.PERMISSION
                !listener.connected -> NotificationHealthIssue.DISCONNECTED
                !battery -> NotificationHealthIssue.BATTERY
                listener.activeCount > 0 && (previous.lastNotificationAt?.let { now - it >= 15 * 60000 } ?: (now - previous.monitoringStartedAt >= 3 * 60000)) -> NotificationHealthIssue.STALE
                else -> NotificationHealthIssue.NONE
            }
            mutable.update { it.copy(listener = listener, batteryExempt = battery, notificationsAllowed = platform.notificationsAllowed(), healthIssue = issue) }
        }
        return mutable.value
    }
    fun close() { if (NativeNotificationBridge.sink === this) NativeNotificationBridge.sink = null; scope.cancel(); postedSignal.close(); installed = null }
    private fun dismissJson(pkg: String, key: String?, group: String?) = JSONObject().put("packageName", pkg)
        .put("notificationKey", key ?: JSONObject.NULL).put("groupKey", group ?: JSONObject.NULL).toString()
}
