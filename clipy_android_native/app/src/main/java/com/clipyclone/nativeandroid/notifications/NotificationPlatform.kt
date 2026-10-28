package com.clipyclone.nativeandroid.notifications

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import com.clipyclone.clipy_android.ClipyNotificationListenerService

class NotificationPlatform(private val context: Context) {
    fun status(): ListenerStatus = try {
        val permitted = NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
        val listener = ClipyNotificationListenerService.instance
        val active = try { listener?.activeNotifications?.size ?: 0 } catch (_: Exception) { 0 }
        ListenerStatus(permitted, ClipyNotificationListenerService.listenerConnected && listener != null, active)
    } catch (_: Exception) { ListenerStatus(false, false, 0) }
    fun batteryExempt(): Boolean = runCatching { context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName) }.getOrDefault(true)
    fun notificationsAllowed(): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel("clipy_sync_foreground")
            if (channel?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }
    fun openListenerSettings() = launch(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    fun requestBatteryExemption() = launch(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")))
    fun openNotificationSettings() {
        if (Build.VERSION.SDK_INT >= 26) launch(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
        else launch(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
    }
    fun rebind(force: Boolean = false) {
        if (!status().permission) return
        if (force) ClipyNotificationListenerService.forceReconnect(context, "native") else ClipyNotificationListenerService.softRebind(context, "native")
    }
    fun openAutostart(): Boolean {
        val candidates = listOf(Intent("miui.intent.action.OP_AUTO_START").setPackage("com.miui.securitycenter"),
            Intent().setComponent(ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
            Intent().setComponent(ComponentName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")).putExtra("extra_pkgname", context.packageName))
        return candidates.any { intent -> try { if (intent.resolveActivity(context.packageManager) != null) launch(intent) else false } catch (_: Exception) { false } }
    }
    fun active(): List<Map<String, Any?>> {
        val listener = ClipyNotificationListenerService.instance
        if (listener == null) { rebind(); return emptyList() }
        return listener.collectActiveNotifications()
    }
    fun open(entry: NotificationEntry) { ClipyNotificationListenerService.instance?.openNotification(entry.packageName, entry.notificationKey) }
    fun dismiss(packageName: String, key: String?) { ClipyNotificationListenerService.instance?.dismissNotification(packageName, key) }
    fun clearStatusBar() { ClipyNotificationListenerService.instance?.clearAllNotifications() }
    @Suppress("DEPRECATION")
    fun installedApps(): List<InstalledNotificationApp> = context.packageManager.getInstalledApplications(0).map { app ->
        InstalledNotificationApp(app.packageName, context.packageManager.getApplicationLabel(app).toString().ifBlank { app.packageName },
            app.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0)
    }.distinctBy { it.packageName }.sortedWith(compareBy<InstalledNotificationApp> { it.system }.thenBy { it.name })
    private fun launch(intent: Intent): Boolean = try { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true } catch (_: Exception) { false }
}
