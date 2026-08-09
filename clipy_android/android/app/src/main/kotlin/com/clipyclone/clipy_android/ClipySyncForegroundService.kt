package com.clipyclone.clipy_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the process elevated while Dart [SyncManager] owns ServerSocket :5566.
 *
 * On [START_STICKY] rebuild (process death), calls [ClipyApplication.ensureEngine]
 * so main() re-runs and sync rebinds without opening the UI. Periodic
 * [syncTick] nudges Dart reconnect / pending flush while backgrounded.
 *
 * WakeLock is held with a timeout and renewed on activity so the CPU can sleep
 * if ticks stop; FGS sticky still keeps the process eligible for restart.
 */
class ClipySyncForegroundService : Service() {

    companion object {
        private const val TAG = "ClipyFGS"
        private const val CHANNEL_ID = "clipy_sync_foreground"
        private const val NOTIFICATION_ID = 0x7101
        /** Fallback / busy interval when Dart does not return a delay. */
        private const val SYNC_TICK_BUSY_MS = 30_000L
        private const val SYNC_TICK_IDLE_MS = 90_000L
        private const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val syncTickRunnable = object : Runnable {
        override fun run() {
            renewWakeLock()
            invokeSyncTick()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        renewWakeLock()
        Log.i(TAG, "onStartCommand: intent=${if (intent == null) "null(sticky rebuild)" else "explicit"}")
        (application as? ClipyApplication)?.drainHeadlessClipboard()
        (application as? ClipyApplication)?.ensureEngine()
        invokeSyncControlFireAndForget("ensureSyncStarted")
        startSyncTicks()
        return START_STICKY
    }

    override fun onDestroy() {
        stopSyncTicks()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startSyncTicks() {
        mainHandler.removeCallbacks(syncTickRunnable)
        mainHandler.postDelayed(syncTickRunnable, SYNC_TICK_BUSY_MS)
    }

    private fun stopSyncTicks() {
        mainHandler.removeCallbacks(syncTickRunnable)
    }

    private fun scheduleNextTick(delayMs: Long) {
        val clamped = delayMs.coerceIn(SYNC_TICK_BUSY_MS, SYNC_TICK_IDLE_MS)
        mainHandler.removeCallbacks(syncTickRunnable)
        mainHandler.postDelayed(syncTickRunnable, clamped)
    }

    private fun invokeSyncTick() {
        (application as? ClipyApplication)?.drainHeadlessClipboard()

        val engine = FlutterEngineCache.getInstance().get(ClipyApplication.ENGINE_ID)
        if (engine == null) {
            Log.w(TAG, "syncTick skipped: engine not ready")
            (application as? ClipyApplication)?.ensureEngine()
            scheduleNextTick(SYNC_TICK_BUSY_MS)
            return
        }
        try {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                ClipyApplication.SYNC_CONTROL_CHANNEL,
            ).invokeMethod(
                "syncTick",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val delay = when (result) {
                            is Number -> result.toLong()
                            else -> SYNC_TICK_BUSY_MS
                        }
                        scheduleNextTick(delay)
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        Log.w(TAG, "syncTick error: $errorCode $errorMessage")
                        scheduleNextTick(SYNC_TICK_BUSY_MS)
                    }

                    override fun notImplemented() {
                        scheduleNextTick(SYNC_TICK_BUSY_MS)
                    }
                },
            )
        } catch (e: Exception) {
            Log.w(TAG, "syncTick invoke failed", e)
            scheduleNextTick(SYNC_TICK_BUSY_MS)
        }
    }

    private fun invokeSyncControlFireAndForget(method: String) {
        (application as? ClipyApplication)?.drainHeadlessClipboard()

        val engine = FlutterEngineCache.getInstance().get(ClipyApplication.ENGINE_ID)
        if (engine == null) {
            Log.w(TAG, "$method skipped: engine not ready")
            (application as? ClipyApplication)?.ensureEngine()
            return
        }
        try {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                ClipyApplication.SYNC_CONTROL_CHANNEL,
            ).invokeMethod(method, null)
        } catch (e: Exception) {
            Log.w(TAG, "$method invoke failed", e)
        }
    }

    /** Acquire or refresh a timed partial wake lock. */
    private fun renewWakeLock() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        try {
            wakeLock?.let { held ->
                if (held.isHeld) held.release()
            }
        } catch (_: Exception) {
        }
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Clipy:SyncWakeLock").apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun startForegroundCompat() {
        ensureChannel()
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(getNotificationTitleRes()))
            .setContentText(getString(getNotificationTextRes()))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(getChannelNameRes()),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(getChannelDescRes())
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun getNotificationTitleRes(): Int = R.string.fgs_notification_title
    private fun getNotificationTextRes(): Int = R.string.fgs_notification_text
    private fun getChannelNameRes(): Int = R.string.fgs_channel_name
    private fun getChannelDescRes(): Int = R.string.fgs_channel_desc
}
