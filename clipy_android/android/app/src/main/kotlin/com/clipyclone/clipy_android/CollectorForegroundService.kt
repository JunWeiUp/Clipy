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
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

class CollectorForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "clipy_collector"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.clipyclone.clipy_android.START_COLLECTOR"
        const val ACTION_STOP = "com.clipyclone.clipy_android.STOP_COLLECTOR"
        const val ACTION_RELOAD = "com.clipyclone.clipy_android.RELOAD_COLLECTOR"
        private const val TAG = "ClipyCollectorService"
    }

    private var smsReceiver: SmsReceiver? = null
    private var smsContentObserver: SmsContentObserver? = null
    private var callStateReceiver: CallStateReceiver? = null
    private var callLogObserver: CallLogObserver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RELOAD -> {
                unregisterCollectors()
                registerCollectors()
                return START_STICKY
            }
        }

        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(),
            foregroundServiceType(),
        )
        registerCollectors()
        return START_STICKY
    }

    private fun foregroundServiceType(): Int {
        return ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    }

    override fun onDestroy() {
        unregisterCollectors()
        super.onDestroy()
    }

    private fun registerCollectors() {
        if (FlutterPrefs.isCategoryEnabled(this, "sms")) {
            registerSmsContentObserver()
            ensureSmsReceiverRegistered()
        }
        if (FlutterPrefs.isCategoryEnabled(this, "call")) {
            registerCallStateReceiver()
        }
        if (FlutterPrefs.isCategoryEnabled(this, "call_log")) {
            registerCallLogObserver()
        }
    }

    private fun registerCallStateReceiver() {
        if (callStateReceiver != null) return
        try {
            callStateReceiver = CallStateReceiver().also {
                val filter = IntentFilter().apply {
                    addAction("android.intent.action.PHONE_STATE")
                }
                registerReceiver(it, filter)
            }
        } catch (e: Exception) {
            Log.w(TAG, "CallStateReceiver registration failed", e)
            callStateReceiver = null
        }
    }

    private fun registerCallLogObserver() {
        if (callLogObserver != null) return
        callLogObserver = CallLogObserver(this).also { it.start() }
    }

    private fun registerSmsContentObserver() {
        if (smsContentObserver != null) return
        if (!hasReadSmsPermission()) {
            Log.w(TAG, "SmsContentObserver skipped: READ_SMS not granted")
            return
        }
        val observer = SmsContentObserver(this)
        if (observer.start()) {
            smsContentObserver = observer
            Log.i(TAG, "SmsContentObserver registered")
        } else {
            Log.w(TAG, "SmsContentObserver registration failed")
        }
    }

    private fun ensureSmsReceiverRegistered() {
        if (smsReceiver != null) return
        if (!hasReceiveSmsPermission()) {
            Log.d(TAG, "SmsReceiver skipped: RECEIVE_SMS not granted")
            return
        }
        if (!hasReadSmsPermission()) {
            Log.d(TAG, "SmsReceiver skipped: READ_SMS not granted")
            return
        }
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
            Log.i(TAG, "SmsReceiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "SmsReceiver registration failed", e)
            smsReceiver = null
        }
    }

    private fun hasReadSmsPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_SMS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasReceiveSmsPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECEIVE_SMS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun unregisterCollectors() {
        smsReceiver?.let { unregisterReceiver(it) }
        callStateReceiver?.let { unregisterReceiver(it) }
        smsContentObserver?.stop()
        callLogObserver?.stop()
        smsReceiver = null
        smsContentObserver = null
        callStateReceiver = null
        callLogObserver = null
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
