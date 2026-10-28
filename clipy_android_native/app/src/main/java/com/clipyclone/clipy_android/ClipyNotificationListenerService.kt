package com.clipyclone.clipy_android

import android.app.Notification
import android.app.PendingIntent
import android.content.ComponentName
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import android.util.LruCache
import com.clipyclone.nativeandroid.notifications.NativeNotificationBridge

/** Original Android extraction/rebind adapter, with a native sink instead of MethodChannel. */
class ClipyNotificationListenerService : NotificationListenerService() {
    companion object {
        private const val TAG = "ClipyNLS"
        private const val REBIND_RETRY_MS = 5000L
        @Volatile var instance: ClipyNotificationListenerService? = null
        @Volatile var listenerConnected = false
            private set
        private val mainHandler = Handler(Looper.getMainLooper())
        private val appNameCache = LruCache<String, String>(128)
        @Volatile private var appContext: android.content.Context? = null
        private fun runOnMainThread(block: () -> Unit) { if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block) }
        private fun emitNotificationPosted(data: Map<String, Any?>) { appContext?.let { NativeNotificationBridge.post(it, data) } }
        private fun notifyListenerConnection(connected: Boolean) { NativeNotificationBridge.sink?.connectionChanged(connected) }
        /** Soft rebind — often ignored on Xiaomi/MIUI/HyperOS. */
        fun softRebind(context: android.content.Context, reason: String = "soft") {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
            try {
                val cn = ComponentName(context, ClipyNotificationListenerService::class.java)
                requestRebind(cn)
                Log.i(TAG, "softRebind($reason) issued")
            } catch (e: Exception) {
                Log.e(TAG, "softRebind($reason) failed", e)
            }
        }

        /**
         * Force reconnect by toggling the service component.
         * This is the reliable recovery path on Xiaomi when soft requestRebind is ignored.
         */
        fun forceReconnect(context: android.content.Context, reason: String = "force") {
            val cn = ComponentName(context, ClipyNotificationListenerService::class.java)
            val pm = context.packageManager
            try {
                pm.setComponentEnabledSetting(
                    cn,
                    android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    android.content.pm.PackageManager.DONT_KILL_APP,
                )
                pm.setComponentEnabledSetting(
                    cn,
                    android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    android.content.pm.PackageManager.DONT_KILL_APP,
                )
                Log.i(TAG, "forceReconnect($reason): component toggled")
            } catch (e: Exception) {
                Log.e(TAG, "forceReconnect($reason): component toggle failed", e)
            }
            softRebind(context, reason = "after-force-$reason")
        }
    }
    private val rebindRetryRunnable = Runnable {
        if (!listenerConnected) {
            Log.w(TAG, "Still disconnected after soft rebind; forcing component reconnect")
            forceReconnect(applicationContext, reason = "retry")
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        appContext = applicationContext
        Log.i(TAG, "Service created")
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(rebindRetryRunnable)
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
        listenerConnected = false
        Log.w(TAG, "Service destroyed")
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        mainHandler.removeCallbacks(rebindRetryRunnable)
        listenerConnected = true
        Log.i(TAG, "Listener connected")
        // Notify the native manager; it refreshes active notifications under
        // suppressBroadcast. Emitting here would race and re-broadcast to Mac.
        notifyListenerConnection(true)
    }

    override fun onListenerDisconnected() {
        listenerConnected = false
        Log.w(TAG, "Listener disconnected — soft rebind (MIUI often ignores this)")
        notifyListenerConnection(false)
        // OEM ROMs (esp. Xiaomi/MIUI/HyperOS) often unbind NLS while the process
        // stays alive. Soft requestRebind alone is unreliable — retry escalates
        // to component disable/enable force reconnect.
        softRebind(applicationContext, reason = "disconnect")
        mainHandler.removeCallbacks(rebindRetryRunnable)
        mainHandler.postDelayed(rebindRetryRunnable, REBIND_RETRY_MS)
        super.onListenerDisconnected()
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

    /** Snapshot of currently active notifications for a native snapshot refresh. */
    fun collectActiveNotifications(): List<Map<String, Any?>> {
        return try {
            activeNotifications.mapNotNull { statusBarNotificationToMap(it) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun emitStatusBarNotification(sbn: StatusBarNotification?) {
        val data = statusBarNotificationToMap(sbn) ?: return
        Log.d(TAG, "Forwarding notification metadata")
        emitNotificationPosted(data)
    }

    private fun statusBarNotificationToMap(sbn: StatusBarNotification?): Map<String, Any?>? {
        if (sbn == null) return null

        try {
            val notification = sbn.notification ?: return null
            val extras = notification.extras ?: Bundle.EMPTY
            val packageName = sbn.packageName ?: return null
            val appName = getAppName(packageName)
            val allExtras = extrasToMap(extras)
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
                ?: allExtras[Notification.EXTRA_TITLE]
                ?: ""
            val subtitle = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()
                ?: allExtras[Notification.EXTRA_SUB_TEXT]
            // Folded/stacked notifications (InboxStyle / MessagingStyle) often keep
            // EXTRA_TEXT as a summary ("2条新消息") while the real newest line lives
            // in EXTRA_TEXT_LINES or EXTRA_MESSAGES — prefer those for sync.
            val body = extractNotificationBody(extras, allExtras)
            if (title.isBlank() && subtitle.isNullOrBlank() && body.isBlank() && allExtras.values.none { it.isNotBlank() }) {
                Log.d(TAG, "Skipping blank notification from $packageName")
                return null
            }

            val isGroupSummary =
                (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0

            return mapOf(
                "key" to sbn.key,
                "packageName" to packageName,
                "appName" to appName,
                "title" to title,
                "subtitle" to subtitle,
                "body" to body,
                "postTime" to sbn.postTime,
                "groupKey" to sbn.groupKey,
                "isGroupSummary" to isGroupSummary,
                "isClearable" to ((notification.flags and Notification.FLAG_NO_CLEAR) == 0),
                "extras" to allExtras,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error processing notification from ${sbn.packageName}", e)
            return null
        }
    }

    /**
     * Prefer the newest line from InboxStyle / MessagingStyle folded stacks.
     * Falls back to BIG_TEXT / TEXT.
     */
    private fun extractNotificationBody(extras: Bundle, allExtras: Map<String, String>): String =
        com.clipyclone.nativeandroid.notifications.NotificationContentExtractor.body(extras, allExtras)

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val data = mapOf(
            "key" to sbn.key,
            "packageName" to (sbn.packageName ?: ""),
        )
        runOnMainThread { NativeNotificationBridge.sink?.removed(data) }
    }

    private fun getAppName(packageName: String): String {
        appNameCache.get(packageName)?.let { return it }
        val appName = try {
            val pm = applicationContext.packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }
        appNameCache.put(packageName, appName)
        return appName
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
