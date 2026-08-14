package com.clipyclone.clipy_android

import android.Manifest
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.clipyclone.clipy_android/open_folder"
    private val PERMISSIONS_CHANNEL = "com.clipyclone.clipy_android/permissions"
    private val NOTIFICATIONS_CHANNEL = ClipyApplication.NOTIFICATIONS_CHANNEL
    private val CLIPBOARD_CHANNEL = ClipyApplication.CLIPBOARD_CHANNEL
    private val STORAGE_PERMISSION_REQUEST_CODE = 1001
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 1002
    private val SYNC_CHANNEL_ID = "clipy_sync_foreground"
    private var clipboardChangeListener: ClipboardChangeListener? = null
    private var notificationsMethodChannel: MethodChannel? = null

    companion object {
        private const val REBIND_THROTTLE_MS = 30_000L
        @Volatile private var lastRebindTimeMs: Long = 0
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // When Application skipped warm-start (sync off), cache this engine so
        // a later FGS start shares one isolate / :5566 bind.
        (application as? ClipyApplication)?.adoptEngineIfNeeded(flutterEngine)

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
                "isBatteryOptimizationExempt" -> {
                    result.success(isBatteryOptimizationExempt())
                }
                "requestBatteryOptimizationExemption" -> {
                    requestBatteryOptimizationExemption()
                    result.success(null)
                }
                "areNotificationsEnabled" -> {
                    result.success(areNotificationsEnabled())
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // storage / NLS core / sync_service already registered by PlatformChannels
        // on the Application engine. Only attach UI-only notification methods.
        PlatformChannels.attachActivityHandlers(this, flutterEngine)
        notificationsMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATIONS_CHANNEL)

        val clipboardChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
        clipboardChangeListener = ClipboardChangeListener(this)
        clipboardChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMonitoring" -> {
                    clipboardChangeListener?.attach(clipboardChannel)
                    result.success(null)
                }
                "stopMonitoring" -> {
                    clipboardChangeListener?.detach()
                    result.success(null)
                }
                "setText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val ok = (application as? ClipyApplication)?.setClipboardText(text) == true
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Reuse the Application-cached engine when ready so UI and sync share one
     * isolate / one ServerSocket. If the cache is not ready yet, return null and
     * let FlutterActivity create a normal engine (user can still open the app).
     */
    override fun getCachedEngineId(): String? {
        val app = application as? ClipyApplication ?: return null
        return if (app.engineReady) ClipyApplication.ENGINE_ID else null
    }

    /** Keep the sole cached engine alive after Activity teardown (FGS / reuse). */
    override fun shouldDestroyEngineWithHost(): Boolean {
        return FlutterEngineCache.getInstance().get(ClipyApplication.ENGINE_ID) == null
    }

    override fun onDestroy() {
        // Keep NLS MethodChannel attached: after force-kill recovery the engine
        // stays alive without Activity, and clearing here would send posts only
        // into NativePendingPostStore until the UI opens again.
        notificationsMethodChannel = null
        clipboardChangeListener?.detach()
        clipboardChangeListener = null
        super.onDestroy()
        // Do not destroy the cached engine — FGS keeps sync alive.
    }

    fun isNotificationListenerEnabledPublic(): Boolean =
        PlatformChannels.isNotificationListenerEnabled(application as ClipyApplication)

    fun requestNotificationListenerRebindPublic() {
        val now = System.currentTimeMillis()
        val elapsed = now - lastRebindTimeMs
        if (elapsed < REBIND_THROTTLE_MS) {
            Log.d("ClipyMain", "Skipping soft rebind (throttled, ${elapsed}ms since last call)")
            return
        }
        lastRebindTimeMs = now
        ClipyNotificationListenerService.softRebind(this, reason = "activity")
    }

    /** Try Xiaomi/HyperOS autostart page; returns true if an activity was launched. */
    fun openOemAutostartSettingsPublic(): Boolean {
        val candidates = listOf(
            Intent("miui.intent.action.OP_AUTO_START").setPackage("com.miui.securitycenter"),
            Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
            ),
            Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.permissions.PermissionsEditorActivity",
                ),
            ).putExtra("extra_pkgname", packageName),
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    Log.i("ClipyMain", "Opened OEM autostart settings: $intent")
                    return true
                }
            } catch (e: Exception) {
                Log.w("ClipyMain", "OEM autostart intent failed: $intent", e)
            }
        }
        return false
    }

    private fun isBatteryOptimizationExempt(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as? PowerManager ?: return true
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * True only when the FGS notification can actually surface: the app-level
     * notification switch is on AND the sync channel (if already created) was
     * not disabled by the user. On Android 13+ POST_NOTIFICATIONS defaults to
     * denied, and a denied app hides even foreground-service notifications —
     * making a running sync look dead in the shade.
     */
    private fun areNotificationsEnabled(): Boolean {
        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            val channel = nm.getNotificationChannel(SYNC_CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }

    /**
     * POST_NOTIFICATIONS dialog on Android 13+; falls back to the app's
     * notification settings page when the OS toggle itself is off (pre-13 or
     * OEM app-level switch, e.g. MIUI).
     */
    private fun requestNotificationPermission() {
        if (areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE,
            )
        } else {
            try {
                val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e: Exception) {
                Log.e("ClipyMain", "Cannot open notification settings", e)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun requestBatteryOptimizationExemption() {
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            // Fallback: open general battery optimization settings
            try {
                val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e2: Exception) {
                Log.e("ClipyMain", "Cannot open battery optimization settings", e2)
            }
        }
    }

    fun getInstalledAppsListPublic(): List<Map<String, Any>> {
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
