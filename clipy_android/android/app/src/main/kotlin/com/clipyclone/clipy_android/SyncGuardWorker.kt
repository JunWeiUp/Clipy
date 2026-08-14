package com.clipyclone.clipy_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters

/**
 * Periodic (15 min) self-healing watchdog.
 *
 * When the sync FGS is gone (system kill / Doze / Android 15 dataSync 6h quota
 * / user swipe), this worker restarts it via
 * [ClipyApplication.startForegroundSyncService]. [ClipySyncForegroundService]
 * .onStartCommand is idempotent, so calling it while the FGS already runs is
 * harmless (just refreshes notification/wakelock/ticks).
 *
 * Android 12+ forbids launching a FGS from the background, so this worker runs
 * as a "long-running foreground worker" ([setForeground] + [getForegroundInfo])
 * and the launch happens from a foreground context. It is only foreground for
 * the few seconds needed to start the FGS, consuming a negligible slice of any
 * FGS time budget.
 *
 * See `docs/PROTOCOL.md` § Headless Android and AGENTS.md "Android 进程保活".
 */
class SyncGuardWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        private const val TAG = "ClipySyncGuard"
        // Same channel as the sync FGS so they share one low-priority slot.
        private const val CHANNEL_ID = "clipy_sync_foreground"
        // Distinct from ClipySyncForegroundService.NOTIFICATION_ID (0x7101).
        private const val NOTIFICATION_ID = 0x7102
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val KEY_SYNC_ENABLED = "flutter.syncEnabled"
    }

    override suspend fun doWork(): Result {
        val enabled = try {
            applicationContext
                .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_SYNC_ENABLED, false)
        } catch (e: Exception) {
            Log.w(TAG, "read syncEnabled failed", e)
            false
        }
        if (!enabled) {
            Log.i(TAG, "syncEnabled=false, skip guard tick")
            return Result.success()
        }

        // Promote to foreground so startForegroundService() is legal on Android 12+.
        try {
            setForeground(buildForegroundInfo())
        } catch (e: Exception) {
            Log.w(TAG, "setForeground failed; will still try to start FGS", e)
        }

        val started = try {
            (applicationContext as? ClipyApplication)?.startForegroundSyncService() == true
        } catch (e: Exception) {
            Log.e(TAG, "startForegroundSyncService failed", e)
            false
        }
        Log.i(TAG, "guard tick: FGS start ${if (started) "ok" else "noop/failed"}")
        return Result.success()
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = buildForegroundInfo()

    private fun buildForegroundInfo(): ForegroundInfo {
        ensureChannel(applicationContext)
        val notification: Notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle(applicationContext.getString(R.string.fgs_notification_title))
            .setContentText(applicationContext.getString(R.string.fgs_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
        // The ForegroundInfo drives WorkManager's OWN SystemForegroundService
        // (NOT our ClipySyncForegroundService). It must carry a type that is a
        // subset of the foregroundServiceType declared on that service element
        // in the merged manifest — we override it there with
        // specialUse|dataSync. History, both crash directions:
        //   * passing specialUse while WorkManager declared no type at all →
        //     IllegalArgumentException: foregroundServiceType 0x40000000 is
        //     not a subset of foregroundServiceType attribute 0x00000000.
        //   * passing no type (the 2-arg form) worked until the device OTA'd
        //     to Android 16: targetSdk 36 prohibits startForeground with no
        //     type at all → InvalidForegroundServiceTypeException: Starting
        //     FGS with type none ... has been prohibited (FATAL, killed the
        //     process after every guard tick, so boot autostart never stuck).
        // The version-branched type + manifest override keeps both checks
        // green on every API level.
        val type = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            else -> 0
        }
        return ForegroundInfo(NOTIFICATION_ID, notification, type)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.fgs_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.fgs_channel_desc)
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }
}
