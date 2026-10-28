package com.clipyclone.clipy_android

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import androidx.core.content.ContextCompat
import com.clipyclone.nativeandroid.NativeClipboard
import com.clipyclone.nativeandroid.ClipboardCapturePolicy
import com.clipyclone.nativeandroid.notifications.NativeNotificationManager
import com.clipyclone.nativeandroid.relay.NativeRelayController
import com.clipyclone.nativeandroid.relay.RelayLocalIdentity
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Stable application identity, now entirely native. Work survives Activity destruction. */
class ClipyApplication : Application() {
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val initializationError = MutableStateFlow<String?>(null)
    val startupError = initializationError.asStateFlow()
    private var initializationJob: Job? = null
    val logs by lazy { NativeLogStore(this) }
    val relay by lazy {
        NativeRelayController(this, appScope,
            local = { sync.state.value.let { state -> RelayLocalIdentity(state.settings.peerId, state.settings.name, state.settings.port, state.localAddresses) } },
            hasSession = { sync.hasSession(it) },
            tryLan = { peer, host, port -> sync.tryLan(peer, host, port) },
            onSocket = { peer, host, socket, inbound -> sync.adoptRelaySocket(peer, host, socket, inbound) })
    }
    val notifications by lazy {
        NativeNotificationManager(this, appScope, sync.crypto,
            broadcast = { type, content, hash -> sync.broadcastNotification(type, content, hash) },
            acknowledge = { peer, id -> sync.sendNotificationAck(peer, id) })
    }
    private val historyVersion = MutableStateFlow(0L)
    val historyRevision = historyVersion.asStateFlow()
    private val historyWrites = Mutex()
    private val fileVersion = MutableStateFlow(0L)
    val fileRevision = fileVersion.asStateFlow()
    private val fileEvents = MutableSharedFlow<ReceivedFile>(extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val filesReceived = fileEvents.asSharedFlow()
    val receivedFiles by lazy { ReceivedFileStore(this) }
    val fileTransfers by lazy {
        NativeFileTransfer(appScope, identity = { sync.state.value.settings.let { it.peerId to it.name } },
            crypto = sync.crypto, storage = receivedFiles, channel = { sync.fileChannel(it) },
            reply = { peer, frame -> sync.sendOnConnection(peer, frame) }, received = { record ->
                fileVersion.update { it + 1 }; fileEvents.tryEmit(record)
                appScope.launch(Dispatchers.IO) { TransferNotifications.received(this@ClipyApplication, java.io.File(record.path), record.sender) }
            })
    }
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    val sync: NativeSyncManager by lazy {
        NativeSyncManager(this,
            handleOtherFrame = { peer, frame ->
                when (frame.type) {
                    SyncType.FILE_META, SyncType.FILE_CHUNK, SyncType.FILE_ACK -> fileTransfers.receive(peer, frame)
                    SyncType.NOTIF_POST, SyncType.NOTIF_DISMISS, SyncType.NOTIF_CLEAR, SyncType.NOTIF_ACK, SyncType.NOTIF_CONFIG -> notifications.receive(peer.peerId, frame)
                }
            },
            onPeerConnected = { if (notifications.hasPending()) notifications.flushPending() },
            flushNotificationPending = { if (notifications.hasPending()) notifications.flushPending() },
            hasActiveTransfers = { fileTransfers.active.value.isNotEmpty() },
            logger = { level, message -> runCatching { logs.append(level, message) }; Unit },
            onStarted = { relay.start() }, refreshRelay = { relay.refresh() }, requestRelayPeer = { relay.ensurePeer(it) },
            onPeerDisconnected = { fileTransfers.disconnected(it) }, onStopped = { fileTransfers.reset(); relay.stop() },
            publishHistory = { result ->
            clipboard.acceptRemote(result)
            if (result.changed) historyVersion.update { it + 1 }
        })
    }
    val clipboard: NativeClipboard by lazy {
        NativeClipboard(this, appScope) { text, source, broadcast ->
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val excluded = FlutterStringLists.decode(prefs.all["flutter.excludedApps"])
            if (ClipboardCapturePolicy.allows(source, excluded)) {
                withContext(Dispatchers.IO) {
                    historyWrites.withLock {
                        ClipyDatabase(this@ClipyApplication).use { db ->
                            val repo = HistoryRepository(db)
                            repo.saveText(text, source = source)
                            repo.trimToLimit((prefs.all["flutter.historyLimit"] as? Number)?.toInt() ?: 1000)
                        }
                    }
                }
                historyVersion.update { it + 1 }
                if (broadcast) appScope.launch {
                    try { sync.broadcastText(text) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (error: Exception) { Log.w("ClipyNative", "Clipboard send failed: ${error.javaClass.simpleName}") }
                }
            }
        }
    }
    override fun onCreate() {
        super.onCreate()
        retryInitialization()
    }
    fun retryInitialization() {
        if (initializationJob?.isActive == true) return
        initializationError.value = null
        initializationJob = appScope.launch {
            try {
                sync.initialize()
                notifications.initialize()
                runCatching { logs.append("info", "Native application initialized") }
                if (isSyncEnabledPref()) { startForegroundSyncService(); sync.ensureStarted(); clipboard.drainPendingClipboard() }
                else SyncGuardScheduler.cancel(this@ClipyApplication)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (e: Exception) {
                initializationError.value = "initializationFailed"
                Log.e("ClipyNative", "Native initialization failed: ${e.javaClass.simpleName}")
            }
        }
    }
    fun isSyncEnabledPref(): Boolean = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        .getBoolean("flutter.syncEnabled", false)

    suspend fun setSyncEnabled(enabled: Boolean) {
        sync.setEnabled(enabled)
        if (enabled) {
            if (!startForegroundSyncService()) { sync.setEnabled(false); error("Foreground service could not start") }
        } else stopForegroundSyncService()
    }
    fun startForegroundSyncService(): Boolean {
        if (!isSyncEnabledPref()) return false
        registerNetworkObserver()
        SyncGuardScheduler.schedule(this)
        return try {
            ContextCompat.startForegroundService(this, Intent(this, ClipySyncForegroundService::class.java)); true
        } catch (e: Exception) { Log.w("ClipyNative", "FGS start failed", e); false }
    }
    fun stopForegroundSyncService() {
        unregisterNetworkObserver()
        SyncGuardScheduler.cancel(this)
        stopService(Intent(this, ClipySyncForegroundService::class.java))
    }
    @Synchronized private fun registerNetworkObserver() {
        if (networkCallback != null) return
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun changed() {
                appScope.launch {
                    try { sync.networkChanged(); relay.networkChanged() }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (error: Exception) { Log.w("ClipyNative", "Network refresh failed: ${error.javaClass.simpleName}") }
                }
            }
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
        }
        try { getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(callback); networkCallback = callback }
        catch (e: Exception) { Log.w("ClipyNative", "Network observer unavailable", e) }
    }
    @Synchronized private fun unregisterNetworkObserver() {
        networkCallback?.let { runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } }
        networkCallback = null
    }
    override fun onTerminate() {
        unregisterNetworkObserver(); appScope.cancel(); super.onTerminate()
    }
}
