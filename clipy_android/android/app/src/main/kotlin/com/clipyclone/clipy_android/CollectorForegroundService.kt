package com.clipyclone.clipy_android

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.Context
import android.content.IntentFilter
import android.provider.Telephony
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

class CollectorForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "clipy_collector"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.clipyclone.clipy_android.START_COLLECTOR"
        const val ACTION_STOP = "com.clipyclone.clipy_android.STOP_COLLECTOR"
    }

    private var smsReceiver: SmsReceiver? = null
    private var callStateReceiver: CallStateReceiver? = null
    private var systemStatusReceiver: SystemStatusReceiver? = null
    private var callLogObserver: CallLogObserver? = null
    private var locationCollector: LocationCollector? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        registerCollectors()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }

        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(),
            foregroundServiceType(),
        )
        ensureSmsReceiverRegistered()
        systemStatusReceiver?.emitCurrentStatus(this)
        locationCollector?.requestUpdate()
        return START_STICKY
    }

    private fun foregroundServiceType(): Int {
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        if (hasLocationPermission()) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        }
        return type
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    override fun onDestroy() {
        unregisterCollectors()
        super.onDestroy()
    }

    private fun registerCollectors() {
        ensureSmsReceiverRegistered()
        try {
            callStateReceiver = CallStateReceiver().also {
                val filter = IntentFilter().apply {
                    addAction("android.intent.action.PHONE_STATE")
                }
                registerReceiver(it, filter)
            }
        } catch (_: Exception) {
            callStateReceiver = null
        }

        try {
            systemStatusReceiver = SystemStatusReceiver().also {
                val filter = IntentFilter().apply {
                    addAction(Intent.ACTION_BATTERY_CHANGED)
                    addAction("android.net.conn.CONNECTIVITY_CHANGE")
                }
                registerReceiver(it, filter)
            }
        } catch (_: Exception) {
            systemStatusReceiver = null
        }

        callLogObserver = CallLogObserver(this).also { it.start() }
        locationCollector = LocationCollector(this).also { it.start() }
    }

    private fun ensureSmsReceiverRegistered() {
        if (smsReceiver != null || !hasSmsPermission()) return
        try {
            smsReceiver = SmsReceiver().also { receiver ->
                val filter = IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(
                        receiver,
                        filter,
                        Manifest.permission.RECEIVE_SMS,
                        null,
                        Context.RECEIVER_EXPORTED,
                    )
                } else {
                    registerReceiver(receiver, filter)
                }
            }
        } catch (_: Exception) {
            smsReceiver = null
        }
    }

    private fun hasSmsPermission(): Boolean {
        val receive = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECEIVE_SMS,
        ) == PackageManager.PERMISSION_GRANTED
        val read = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_SMS,
        ) == PackageManager.PERMISSION_GRANTED
        return receive && read
    }

    private fun unregisterCollectors() {
        smsReceiver?.let { unregisterReceiver(it) }
        callStateReceiver?.let { unregisterReceiver(it) }
        systemStatusReceiver?.let { unregisterReceiver(it) }
        callLogObserver?.stop()
        locationCollector?.stop()
        smsReceiver = null
        callStateReceiver = null
        systemStatusReceiver = null
        callLogObserver = null
        locationCollector = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Clipy Collector",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps Clipy collecting phone data for Mac sync"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Clipy 正在采集")
            .setContentText("实时同步通知、短信、通话等数据到 Mac")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
