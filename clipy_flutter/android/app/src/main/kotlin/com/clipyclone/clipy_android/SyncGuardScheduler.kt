package com.clipyclone.clipy_android

import android.content.Context
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * Enqueues / cancels [SyncGuardWorker], a Doze-friendly periodic (15 min)
 * watchdog that re-asserts [ClipySyncForegroundService] after the system stops
 * or kills it (Doze / MIUI killer / Android 15 dataSync 6h quota).
 *
 * Unlike START_STICKY, WorkManager periodic work is always rescheduled by the
 * system and survives process death, so the FGS eventually comes back without
 * the user opening the UI.
 */
object SyncGuardScheduler {
    private const val TAG = "SyncGuardScheduler"
    const val UNIQUE_NAME = "clipy_sync_guard"

    /** Idempotent (KEEP); safe to call from Application/BootReceiver/FGS start. */
    fun schedule(context: Context) {
        try {
            val request = PeriodicWorkRequestBuilder<SyncGuardWorker>(
                15, TimeUnit.MINUTES,
            ).build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniquePeriodicWork(
                    UNIQUE_NAME,
                    ExistingPeriodicWorkPolicy.KEEP,
                    request,
                )
            Log.i(TAG, "scheduled periodic guard worker (15min, KEEP)")
        } catch (e: Exception) {
            Log.w(TAG, "schedule failed", e)
        }
    }

    fun cancel(context: Context) {
        try {
            WorkManager.getInstance(context.applicationContext)
                .cancelUniqueWork(UNIQUE_NAME)
            Log.i(TAG, "cancelled guard worker")
        } catch (e: Exception) {
            Log.w(TAG, "cancel failed", e)
        }
    }
}
