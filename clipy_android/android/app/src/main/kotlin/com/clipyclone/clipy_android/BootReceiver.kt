package com.clipyclone.clipy_android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * After reboot, start [ClipySyncForegroundService] when Flutter prefs say
 * sync is enabled. FGS then [ClipyApplication.ensureEngine] so Dart binds :5566
 * without the user opening the UI.
 *
 * Also handles [Intent.ACTION_MY_PACKAGE_REPLACED] so the sync service comes
 * back after an app update without waiting for a reboot or a manual launch.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ClipyBootReceiver"
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val KEY_SYNC_ENABLED = "flutter.syncEnabled"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val enabled = try {
            context.applicationContext
                .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_SYNC_ENABLED, false)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read syncEnabled", e)
            false
        }
        if (!enabled) {
            Log.i(TAG, "Boot ($action): syncEnabled=false, skip FGS")
            return
        }
        try {
            val serviceIntent = Intent(context, ClipySyncForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.i(TAG, "Boot ($action): started ClipySyncForegroundService")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start sync service on boot", e)
        }
    }
}
