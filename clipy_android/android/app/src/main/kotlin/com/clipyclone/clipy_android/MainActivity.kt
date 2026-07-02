package com.clipyclone.clipy_android

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.clipyclone.clipy_android/open_folder"
    private val PERMISSIONS_CHANNEL = "com.clipyclone.clipy_android/permissions"
    private val STORAGE_CHANNEL = "com.clipyclone.clipy_android/storage"
    private val NOTIFICATIONS_CHANNEL = "com.clipyclone.clipy_android/notifications"
    private val COLLECTOR_CHANNEL = "com.clipyclone.clipy_android/collector"
    private val STORAGE_PERMISSION_REQUEST_CODE = 1001
    private val COLLECTOR_PERMISSION_REQUEST_CODE = 1002

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openFolder") {
                val path = call.argument<String>("path")
                if (path != null) {
                    openFolder(path)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Path is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestStoragePermission" -> {
                    requestStoragePermission()
                    result.success(true)
                }
                "checkStoragePermission" -> {
                    val hasPermission = checkStoragePermission()
                    result.success(hasPermission)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppStorageDirectory" -> {
                    result.success(filesDir.absolutePath)
                }
                "getDownloadsDirectory" -> {
                    val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    if (downloadsDir != null) {
                        result.success(downloadsDir.absolutePath)
                    } else {
                        result.error("NOT_FOUND", "Downloads directory not found", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        val notificationsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATIONS_CHANNEL)
        ClipyNotificationListenerService.setMethodChannel(notificationsChannel)
        notificationsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isListenerPermissionGranted" -> {
                    val enabled = isNotificationListenerEnabled()
                    if (enabled && ClipyNotificationListenerService.instance == null) {
                        requestNotificationListenerRebind()
                    }
                    result.success(enabled)
                }
                "openListenerSettings" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                "dismissNotification" -> {
                    val packageName = call.argument<String>("packageName")
                    val notificationKey = call.argument<String>("notificationKey")
                    val listener = ClipyNotificationListenerService.instance
                    if (listener != null && packageName != null) {
                        listener.dismissNotification(packageName, notificationKey)
                        result.success(null)
                    } else {
                        result.error("NO_LISTENER", "NotificationListenerService not running", null)
                    }
                }
                "openNotification" -> {
                    val packageName = call.argument<String>("packageName")
                    val notificationKey = call.argument<String>("notificationKey")
                    val listener = ClipyNotificationListenerService.instance
                    if (listener != null && packageName != null) {
                        listener.openNotification(packageName, notificationKey)
                        result.success(null)
                    } else {
                        result.error("NO_LISTENER", "NotificationListenerService not running", null)
                    }
                }
                "refreshActiveNotifications" -> {
                    val listener = ClipyNotificationListenerService.instance
                    if (listener != null) {
                        listener.emitActiveNotifications()
                        result.success(null)
                    } else if (isNotificationListenerEnabled()) {
                        requestNotificationListenerRebind()
                        result.success(null)
                    } else {
                        result.error("NO_LISTENER", "NotificationListenerService not running", null)
                    }
                }
                "clearAllNotifications" -> {
                    val listener = ClipyNotificationListenerService.instance
                    if (listener != null) {
                        listener.clearAllNotifications()
                        result.success(null)
                    } else {
                        result.error("NO_LISTENER", "NotificationListenerService not running", null)
                    }
                }
                "getInstalledApps" -> {
                    result.success(getInstalledAppsList())
                }
                "getListenerStatus" -> {
                    val permissionGranted = isNotificationListenerEnabled()
                    val listener = ClipyNotificationListenerService.instance
                    if (permissionGranted && listener == null) {
                        requestNotificationListenerRebind()
                    }
                    val activeCount = try {
                        listener?.activeNotifications?.size ?: 0
                    } catch (_: Exception) {
                        0
                    }
                    result.success(
                        mapOf(
                            "permissionGranted" to permissionGranted,
                            "serviceConnected" to (ClipyNotificationListenerService.instance != null),
                            "activeNotificationCount" to activeCount,
                        ),
                    )
                }
                "requestListenerRebind" -> {
                    if (isNotificationListenerEnabled()) {
                        requestNotificationListenerRebind()
                    }
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        val collectorChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COLLECTOR_CHANNEL)
        CollectorEventBridge.setMethodChannel(collectorChannel)
        collectorChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    val intent = Intent(this, CollectorForegroundService::class.java).apply {
                        action = CollectorForegroundService.ACTION_START
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stopForegroundService" -> {
                    val intent = Intent(this, CollectorForegroundService::class.java).apply {
                        action = CollectorForegroundService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(null)
                }
                "checkPermission" -> {
                    val permission = call.argument<String>("permission")
                    result.success(permission?.let { hasPermission(it) } ?: false)
                }
                "requestPermission" -> {
                    val permission = call.argument<String>("permission")
                    if (permission == null) {
                        result.error("INVALID_ARGUMENT", "permission is required", null)
                        return@setMethodCallHandler
                    }
                    requestCollectorPermissions(arrayOf(permission))
                    result.success(null)
                }
                "requestPermissions" -> {
                    val permissions = call.argument<List<String>>("permissions")
                    if (permissions.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "permissions is required", null)
                        return@setMethodCallHandler
                    }
                    requestCollectorPermissions(permissions.toTypedArray())
                    result.success(null)
                }
                "openPermissionSettings" -> {
                    val type = call.argument<String>("type") ?: ""
                    openPermissionSettings(type)
                    result.success(null)
                }
                "isBatteryOptimizationIgnored" -> {
                    result.success(isBatteryOptimizationIgnored())
                }
                "requestIgnoreBatteryOptimization" -> {
                    requestIgnoreBatteryOptimization()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return when (permission) {
            "notification_listener" -> isNotificationListenerEnabled()
            else -> ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestCollectorPermissions(permissions: Array<String>) {
        val missing = permissions.filter { !hasPermission(it) }.toTypedArray()
        if (missing.isEmpty()) return
        ActivityCompat.requestPermissions(this, missing, COLLECTOR_PERMISSION_REQUEST_CODE)
    }

    private fun openPermissionSettings(type: String) {
        val intent = when (type) {
            "notification_listener" -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            "app_details" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun isBatteryOptimizationIgnored(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimization() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        } catch (_: Exception) {
            openPermissionSettings("battery")
        }
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        if (flat.isNullOrEmpty()) return false
        val cn = ComponentName(this, ClipyNotificationListenerService::class.java)
        return flat.contains(cn.flattenToString())
    }

    private fun requestNotificationListenerRebind() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val cn = ComponentName(this, ClipyNotificationListenerService::class.java)
                NotificationListenerService.requestRebind(cn)
            } catch (e: Exception) {
                // Some OEM ROMs reject explicit rebind requests.
            }
        }
    }

    private fun getInstalledAppsList(): List<Map<String, Any>> {
        val pm = packageManager
        val apps = mutableListOf<Map<String, Any>>()
        @Suppress("DEPRECATION")
        val appInfos = pm.getInstalledApplications(0)

        for (appInfo in appInfos) {
            val packageName = appInfo.packageName ?: continue
            val appName = pm.getApplicationLabel(appInfo).toString().ifBlank { packageName }
            val isSystem = (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0 ||
                (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            apps.add(mapOf(
                "packageName" to packageName,
                "appName" to appName,
                "isSystem" to isSystem,
            ))
        }

        return apps
            .distinctBy { it["packageName"] as String }
            .sortedWith(compareBy<Map<String, Any>> { it["isSystem"] as Boolean }.thenBy { it["appName"] as String })
    }

    private fun checkStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ uses scoped storage, no need for explicit permission for Downloads
            true
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ doesn't need explicit permission for Downloads directory
            return
        }
        
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE, Manifest.permission.READ_EXTERNAL_STORAGE),
                STORAGE_PERMISSION_REQUEST_CODE
            )
        }
    }

    private fun openFolder(path: String) {
        val file = File(path)
        val parentDir = file.parentFile ?: return

        try {
            val intent = Intent(Intent.ACTION_VIEW)
            val uri = FileProvider.getUriForFile(
                this,
                "${packageName}.fileprovider",
                parentDir
            )

            // Try to use a generic MIME type that file managers might handle
            intent.setDataAndType(uri, "resource/folder")
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
            } else {
                // Fallback: Try with "*/*" MIME type
                intent.setDataAndType(uri, "*/*")
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
