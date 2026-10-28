package com.clipyclone.clipy_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.clipyclone.nativeandroid.R
import kotlinx.coroutines.*

/** Native replacement for the existing FGS: same channels/types/watchdog, no Flutter engine. */
class ClipySyncForegroundService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var tickLoop: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        foreground()
        val app = application as ClipyApplication
        if (!app.isSyncEnabledPref()) { stopSelf(); return START_NOT_STICKY }
        renewWakeLock()
        app.clipboard.drainPendingClipboard()
        scope.launch {
            try { app.notifications.recoverIfEnabled() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { Log.w("ClipyFGS", "Notification recovery failed: ${error.javaClass.simpleName}") }
        }
        if (tickLoop?.isActive != true) tickLoop = scope.launch {
            try { app.sync.ensureStarted() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (e: Exception) { Log.w("ClipyFGS", "Native listener start failed", e) }
            var next = 30000L
            while (isActive && app.isSyncEnabledPref()) {
                delay(next)
                renewWakeLock()
                app.clipboard.drainPendingClipboard()
                // Await separately: a stuck IO call must not prevent the wake-lock watchdog from running.
                val tick = app.appScope.async(Dispatchers.Default) { app.sync.tick() }
                next = try { withTimeoutOrNull(60000) { tick.await() } ?: 30000 }
                catch (cancelled: CancellationException) { tick.cancel(); throw cancelled }
                catch (e: Exception) { Log.w("ClipyFGS", "Native sync tick failed", e); 30000 }
                finally { if (tick.isActive) tick.cancel() }
                next = next.coerceIn(30000, 90000)
            }
        }
        return START_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        (application as? ClipyApplication)?.let { if (it.isSyncEnabledPref()) it.startForegroundSyncService() }
        super.onTaskRemoved(rootIntent)
    }
    override fun onDestroy() {
        tickLoop?.cancel(); tickLoop = null; scope.cancel()
        wakeLock?.let { runCatching { if (it.isHeld) it.release() } }; wakeLock = null
        // The application still owns sockets while alive; an explicit disable already stops the manager.
        super.onDestroy()
    }
    private fun renewWakeLock() {
        wakeLock?.let { runCatching { if (it.isHeld) it.release() } }
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Clipy:SyncWakeLock").apply {
            setReferenceCounted(false); acquire(10 * 60 * 1000L)
        }
    }
    private fun foreground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel("clipy_sync_foreground") == null) {
            manager.createNotificationChannel(NotificationChannel("clipy_sync_foreground", getString(R.string.fgs_channel_name), NotificationManager.IMPORTANCE_LOW).apply {
                description = getString(R.string.fgs_channel_desc); setShowBadge(false)
            })
        }
        val notification = NotificationCompat.Builder(this, "clipy_sync_foreground")
            .setContentTitle(getString(R.string.fgs_notification_title)).setContentText(getString(R.string.fgs_notification_text))
            .setContentIntent(SyncNotificationIntent.openApp(this)).setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true).setPriority(NotificationCompat.PRIORITY_LOW).setShowWhen(false).build()
        val type = when {
            Build.VERSION.SDK_INT >= 34 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            Build.VERSION.SDK_INT >= 29 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            else -> 0
        }
        ServiceCompat.startForeground(this, 0x7101, notification, type)
    }
}
