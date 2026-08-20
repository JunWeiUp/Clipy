package com.clipyclone.clipy_android

import android.content.ComponentName
import android.content.Intent
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Single registry for sync-critical MethodChannels.
 *
 * Hard rules (headless / force-kill):
 * - Register [storage], [clipboard], [notifications], [sync_service] on the
 *   Application-cached engine — never only in [MainActivity].
 * - Do **not** clear the NLS MethodChannel in Activity.onDestroy while the
 *   engine stays alive (posts would only hit NativePendingPostStore).
 * - [MainActivity] may attach UI-only handlers (settings, installed apps) via
 *   [attachActivityHandlers]; it must not steal storage/NLS ownership away
 *   from this registry without re-binding NLS to the same live channel.
 *
 * See docs/PROTOCOL.md § Headless Android.
 */
object PlatformChannels {
    private const val TAG = "PlatformChannels"

    const val STORAGE = ClipyApplication.STORAGE_CHANNEL
    const val CLIPBOARD = ClipyApplication.CLIPBOARD_CHANNEL
    const val NOTIFICATIONS = ClipyApplication.NOTIFICATIONS_CHANNEL
    const val SYNC_SERVICE = ClipyApplication.SYNC_SERVICE_CHANNEL
    const val SYNC_CRYPTO = ClipyApplication.SYNC_CRYPTO_CHANNEL

    @Volatile
    private var notificationsChannel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun registerAll(app: ClipyApplication, engine: FlutterEngine) {
        registerStorage(app, engine)
        registerClipboard(app, engine)
        registerNotifications(app, engine)
        registerSyncService(app, engine)
        registerSyncCrypto(engine)
        Log.i(TAG, "registerAll: storage/clipboard/notifications/sync_service/sync_crypto")
    }

    /**
     * Merge Activity-only notification methods into the existing channel handler
     * without clearing NLS ownership. Also wires clipboard monitoring (needs
     * Activity context for clipboard listener).
     */
    fun attachActivityHandlers(activity: MainActivity, engine: FlutterEngine) {
        val notif = notificationsChannel
            ?: MethodChannel(engine.dartExecutor.binaryMessenger, NOTIFICATIONS).also {
                notificationsChannel = it
                ClipyNotificationListenerService.setMethodChannel(it)
            }
        notif.setMethodCallHandler { call, result ->
            if (handleNotificationCore(activity.application as ClipyApplication, call, result)) {
                return@setMethodCallHandler
            }
            when (call.method) {
                "openListenerSettings" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(null)
                }
                "openNotification" -> {
                    val packageName = call.argument<String>("packageName")
                    val notificationKey = call.argument<String>("notificationKey")
                    val listener = ClipyNotificationListenerService.instance
                    if (listener != null && packageName != null) {
                        try {
                            listener.openNotification(packageName, notificationKey)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    } else {
                        result.error("NO_LISTENER", "NotificationListenerService not running", null)
                    }
                }
                "getInstalledApps" -> {
                    Thread {
                        try {
                            val apps = activity.getInstalledAppsListPublic()
                            activity.runOnUiThread { result.success(apps) }
                        } catch (e: Exception) {
                            activity.runOnUiThread {
                                result.error("GET_APPS_FAILED", e.message, null)
                            }
                        }
                    }.start()
                }
                "requestListenerRebind" -> {
                    val force = call.argument<Boolean>("force") ?: false
                    if (activity.isNotificationListenerEnabledPublic()) {
                        if (force) {
                            ClipyNotificationListenerService.forceReconnect(activity, reason = "flutter")
                        } else {
                            activity.requestNotificationListenerRebindPublic()
                        }
                    }
                    result.success(null)
                }
                "openOemAutostartSettings" -> {
                    result.success(activity.openOemAutostartSettingsPublic())
                }
                "refreshActiveNotifications" -> {
                    val listener = ClipyNotificationListenerService.instance
                    if (listener != null) {
                        try {
                            result.success(listener.collectActiveNotifications())
                        } catch (e: Exception) {
                            result.error("REFRESH_FAILED", e.message, null)
                        }
                    } else if (activity.isNotificationListenerEnabledPublic()) {
                        activity.requestNotificationListenerRebindPublic()
                        result.success(emptyList<Map<String, Any?>>())
                    } else {
                        result.error("NO_LISTENER", "NotificationListenerService not running", null)
                    }
                }
                "getListenerStatus" -> {
                    val permissionGranted = activity.isNotificationListenerEnabledPublic()
                    val listener = ClipyNotificationListenerService.instance
                    val actuallyConnected = ClipyNotificationListenerService.listenerConnected
                    val activeCount = try {
                        listener?.activeNotifications?.size ?: 0
                    } catch (_: Exception) {
                        0
                    }
                    result.success(
                        mapOf(
                            "permissionGranted" to permissionGranted,
                            "serviceConnected" to (listener != null && actuallyConnected),
                            "serviceBound" to (listener != null),
                            "listenerConnected" to actuallyConnected,
                            "activeNotificationCount" to activeCount,
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }

        // Keep NLS pointed at this channel (same instance as Application when possible).
        ClipyNotificationListenerService.setMethodChannel(notif)
    }

    private fun registerStorage(app: ClipyApplication, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, STORAGE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppStorageDirectory" -> result.success(app.filesDir.absolutePath)
                    "getDownloadsDirectory" -> {
                        val downloads = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOWNLOADS,
                        )
                        if (downloads != null) {
                            result.success(downloads.absolutePath)
                        } else {
                            result.error("NOT_FOUND", "Downloads directory not found", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun registerClipboard(app: ClipyApplication, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CLIPBOARD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setText" -> {
                        val text = call.argument<String>("text") ?: ""
                        mainHandler.post {
                            result.success(app.setClipboardText(text))
                        }
                    }
                    "startMonitoring", "stopMonitoring" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
    }

    private fun registerNotifications(app: ClipyApplication, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, NOTIFICATIONS)
        notificationsChannel = channel
        ClipyNotificationListenerService.setMethodChannel(channel)
        channel.setMethodCallHandler { call, result ->
            if (!handleNotificationCore(app, call, result)) {
                result.notImplemented()
            }
        }
    }

    /** @return true if handled */
    private fun handleNotificationCore(
        app: ClipyApplication,
        call: MethodCall,
        result: MethodChannel.Result,
    ): Boolean {
        when (call.method) {
            "drainNativePendingPosts" -> {
                try {
                    result.success(NativePendingPostStore.drainAll(app))
                } catch (e: Exception) {
                    result.error("DRAIN_FAILED", e.message, null)
                }
                return true
            }
            "dismissNotification" -> {
                val packageName = call.argument<String>("packageName")
                val notificationKey = call.argument<String>("notificationKey")
                val listener = ClipyNotificationListenerService.instance
                if (listener != null && packageName != null) {
                    try {
                        listener.dismissNotification(packageName, notificationKey)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("DISMISS_FAILED", e.message, null)
                    }
                } else {
                    result.error("NO_LISTENER", "NotificationListenerService not running", null)
                }
                return true
            }
            "clearAllNotifications" -> {
                val listener = ClipyNotificationListenerService.instance
                if (listener != null) {
                    try {
                        listener.clearAllNotifications()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("CLEAR_FAILED", e.message, null)
                    }
                } else {
                    result.error("NO_LISTENER", "NotificationListenerService not running", null)
                }
                return true
            }
            "refreshActiveNotifications" -> {
                val listener = ClipyNotificationListenerService.instance
                if (listener != null) {
                    try {
                        result.success(listener.collectActiveNotifications())
                    } catch (e: Exception) {
                        result.error("REFRESH_FAILED", e.message, null)
                    }
                } else {
                    result.success(emptyList<Map<String, Any?>>())
                }
                return true
            }
            "getListenerStatus" -> {
                val listener = ClipyNotificationListenerService.instance
                result.success(
                    mapOf(
                        "permissionGranted" to isNotificationListenerEnabled(app),
                        "serviceBound" to (listener != null),
                        "listenerConnected" to ClipyNotificationListenerService.listenerConnected,
                        "serviceConnected" to
                            (listener != null && ClipyNotificationListenerService.listenerConnected),
                    ),
                )
                return true
            }
            "isListenerPermissionGranted" -> {
                result.success(isNotificationListenerEnabled(app))
                return true
            }
            else -> return false
        }
    }

    private fun registerSyncService(app: ClipyApplication, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, SYNC_SERVICE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundSync" -> result.success(app.startForegroundSyncService())
                    "stopForegroundSync" -> result.success(app.stopForegroundSyncService())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Hardware-accelerated AES-GCM for file chunks. Pure-Dart pointycastle
     * manages only tens of MB/s on a phone and is the transfer bottleneck;
     * javax.crypto uses ARMv8 crypto extensions. Wire format stays
     * nonce12 ‖ ciphertext ‖ tag16 — byte-identical to the Dart fallback and
     * to the macOS CryptoKit implementation.
     */
    private fun registerSyncCrypto(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, SYNC_CRYPTO)
            .setMethodCallHandler { call, result ->
                val key = call.argument<ByteArray>("key")
                val nonce = call.argument<ByteArray>("nonce")
                if (key == null || nonce == null || key.size != 32 || nonce.size != 12) {
                    result.error("BAD_ARGS", null, null)
                    return@setMethodCallHandler
                }
                try {
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    when (call.method) {
                        "seal" -> {
                            val plain = call.argument<ByteArray>("plain")
                                ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                            cipher.init(
                                Cipher.ENCRYPT_MODE,
                                SecretKeySpec(key, "AES"),
                                GCMParameterSpec(128, nonce),
                            )
                            val sealed = cipher.doFinal(plain)
                            result.success(nonce + sealed)
                        }
                        "open" -> {
                            val sealed = call.argument<ByteArray>("sealed")
                                ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                            cipher.init(
                                Cipher.DECRYPT_MODE,
                                SecretKeySpec(key, "AES"),
                                GCMParameterSpec(128, nonce),
                            )
                            result.success(cipher.doFinal(sealed))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    // AEADBadTagException lands here (tampered/wrong key).
                    result.error("CRYPTO_FAILED", e.message, null)
                }
            }
    }

    fun isNotificationListenerEnabled(app: ClipyApplication): Boolean {
        val flat = Settings.Secure.getString(
            app.contentResolver,
            "enabled_notification_listeners",
        )
        if (flat.isNullOrEmpty()) return false
        val cn = ComponentName(app, ClipyNotificationListenerService::class.java)
        return flat.contains(cn.flattenToString()) || flat.contains(cn.flattenToShortString())
    }
}
