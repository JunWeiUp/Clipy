package com.clipyclone.clipy_android

import android.app.Notification
import android.app.PendingIntent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue

class ClipyNotificationListenerService : NotificationListenerService() {

    companion object {
        var instance: ClipyNotificationListenerService? = null
        private var methodChannel: MethodChannel? = null
        private val pendingPostedNotifications = ConcurrentLinkedQueue<Map<String, Any?>>()

        fun setMethodChannel(channel: MethodChannel) {
            methodChannel = channel
            flushPendingPostedNotifications()
            instance?.emitActiveNotifications()
        }

        private fun emitNotificationPosted(data: Map<String, Any?>) {
            val channel = methodChannel
            if (channel == null) {
                pendingPostedNotifications.add(data)
                return
            }
            try {
                channel.invokeMethod("onNotificationPosted", data)
            } catch (e: Exception) {
                pendingPostedNotifications.add(data)
            }
        }

        private fun flushPendingPostedNotifications() {
            val channel = methodChannel ?: return
            while (true) {
                val data = pendingPostedNotifications.poll() ?: return
                try {
                    channel.invokeMethod("onNotificationPosted", data)
                } catch (e: Exception) {
                    pendingPostedNotifications.add(data)
                    return
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        emitStatusBarNotification(sbn)
    }

    fun emitActiveNotifications() {
        try {
            for (sbn in activeNotifications) {
                emitStatusBarNotification(sbn)
            }
        } catch (e: Exception) {
            // Permission can be revoked while the listener is running.
        }
    }

    private fun emitStatusBarNotification(sbn: StatusBarNotification?) {
        if (sbn == null) return

        try {
            val notification = sbn.notification ?: return
            val extras = notification.extras ?: Bundle.EMPTY
            val packageName = sbn.packageName ?: return
            val appName = getAppName(packageName)
            val allExtras = extrasToMap(extras)
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
                ?: allExtras[Notification.EXTRA_TITLE]
                ?: ""
            val subtitle = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()
                ?: allExtras[Notification.EXTRA_SUB_TEXT]
            val body = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
                ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
                ?: allExtras[Notification.EXTRA_BIG_TEXT]
                ?: allExtras[Notification.EXTRA_TEXT]
                ?: ""
            if (title.isBlank() && subtitle.isNullOrBlank() && body.isBlank() && allExtras.values.none { it.isNotBlank() }) return

            val data = mapOf(
                "key" to sbn.key,
                "packageName" to packageName,
                "appName" to appName,
                "title" to title,
                "subtitle" to subtitle,
                "body" to body,
                "postTime" to sbn.postTime,
                "groupKey" to sbn.groupKey,
                "isClearable" to ((notification.flags and Notification.FLAG_NO_CLEAR) == 0),
                "extras" to allExtras,
            )

            emitNotificationPosted(data)
        } catch (e: Exception) {
            // Never let a malformed notification break future collection.
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val data = mapOf(
            "key" to sbn.key,
            "packageName" to (sbn.packageName ?: ""),
        )
        try {
            methodChannel?.invokeMethod("onNotificationRemoved", data)
        } catch (e: Exception) {
            // Flutter engine may not be ready
        }
    }

    private fun getAppName(packageName: String): String {
        return try {
            val pm = applicationContext.packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    private fun extrasToMap(extras: Bundle): Map<String, String> {
        val result = mutableMapOf<String, String>()
        for (key in extras.keySet()) {
            val text = try {
                val value = extras.get(key) ?: continue
                when (value) {
                    is CharSequence -> value.toString()
                    is Number -> value.toString()
                    is Boolean -> value.toString()
                    is Array<*> -> value.mapNotNull { item -> safeExtraValue(item) }.joinToString("\n")
                    is Iterable<*> -> value.mapNotNull { item -> safeExtraValue(item) }.joinToString("\n")
                    else -> null
                }
            } catch (e: Exception) {
                null
            }?.trim()

            if (!text.isNullOrEmpty()) {
                result[key] = text
            }
        }
        return result
    }

    private fun safeExtraValue(value: Any?): String? {
        return when (value) {
            null -> null
            is CharSequence -> value.toString()
            is Number -> value.toString()
            is Boolean -> value.toString()
            else -> null
        }
    }

    fun openNotification(packageName: String, notificationKey: String?) {
        try {
            val sbn = activeNotifications.firstOrNull { item ->
                item.packageName == packageName && (notificationKey == null || item.key == notificationKey)
            }
            val pendingIntent: PendingIntent? = sbn?.notification?.contentIntent
            if (pendingIntent != null) {
                pendingIntent.send()
                return
            }

            val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return
            launchIntent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(launchIntent)
        } catch (e: Exception) {
            // Notification may be gone or the target app may reject the PendingIntent.
        }
    }

    fun dismissNotification(packageName: String, notificationKey: String?) {
        try {
            if (notificationKey != null) {
                cancelNotification(notificationKey)
            } else {
                val notifications = activeNotifications
                for (sbn in notifications) {
                    if (sbn.packageName == packageName) {
                        cancelNotification(sbn.key)
                    }
                }
            }
        } catch (e: Exception) {
            // May fail if permission revoked
        }
    }

    fun clearAllNotifications() {
        try {
            cancelAllNotifications()
        } catch (e: Exception) {
            // May fail if permission revoked
        }
    }
}
