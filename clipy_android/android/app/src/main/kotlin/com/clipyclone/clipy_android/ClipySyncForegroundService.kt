package com.clipyclone.clipy_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 纯保活服务：自身不做任何业务逻辑，只为提升进程优先级到「前台服务」，
 * 让运行在 Flutter 引擎里的 SyncManager ServerSocket 在 Activity 退到
 * 后台后仍能继续 accept 入站连接，避免 Doze / App Standby 冻结网络 IO。
 *
 * 生命周期由 Dart 端 SyncManager.start()/stop() 通过 MethodChannel 控制。
 */
class ClipySyncForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "clipy_sync_foreground"
        private const val NOTIFICATION_ID = 0x7101
    }

    /// Partial wake lock: the FGS keeps the *process* alive but the CPU can
    /// still suspend in Doze, causing the Dart event loop (and thus the
    /// ServerSocket accept loop) to stall — peers can no longer connect.
    /// Holding a PARTIAL_WAKE_LOCK ensures the CPU stays awake to process
    /// inbound TCP handshakes while the Activity is backgrounded.
    /// Released in onDestroy / stopForegroundSync to avoid battery drain
    /// when sync is off.
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        acquireWakeLock()
        // START_STICKY: 进程被回收后系统会尝试重建并重新投递空 Intent，
        // 让 SyncManager 在 Flutter 引擎重启时能再次拉起本服务。
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Clipy:SyncWakeLock").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
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

        // Android 10+ 需要显式声明 foregroundServiceType。
        // dataSync 覆盖局域网同步场景，且 targetSdk=34 强制要求声明类型。
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        // IMPORTANCE_LOW: 不响铃、不弹出，仅在通知栏静默展示，
        // 降低对用户的打扰，同时满足 FGS 必须有可见通知的硬性要求。
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
