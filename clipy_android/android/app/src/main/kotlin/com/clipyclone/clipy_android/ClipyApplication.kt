package com.clipyclone.clipy_android

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Caches a single FlutterEngine that runs [main] so LAN sync
 * (`SyncManager` ServerSocket) can recover after process death without the
 * user opening [MainActivity].
 *
 * [ClipySyncForegroundService] / [BootReceiver] call [ensureEngine]; the
 * Activity reuses the same engine via [ENGINE_ID].
 */
class ClipyApplication : Application() {

    companion object {
        private const val TAG = "ClipyApplication"
        const val ENGINE_ID = "clipy_engine"
        const val SYNC_SERVICE_CHANNEL = "com.clipyclone.clipy_android/sync_service"
        const val SYNC_CONTROL_CHANNEL = "com.clipyclone.clipy_android/sync_control"
        const val CLIPBOARD_CHANNEL = "com.clipyclone.clipy_android/clipboard"
        const val STORAGE_CHANNEL = "com.clipyclone.clipy_android/storage"
        const val NOTIFICATIONS_CHANNEL = "com.clipyclone.clipy_android/notifications"
        private const val MAX_CREATE_ATTEMPTS = 6
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val KEY_SYNC_ENABLED = "flutter.syncEnabled"
    }

    val engineReady: Boolean
        get() = FlutterEngineCache.getInstance().get(ENGINE_ID) != null

    @Volatile
    private var createAttempts = 0
    @Volatile
    private var creating = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        // Warm engine only when sync is on (matches BootReceiver). Opening the
        // UI without sync adopts the Activity-created engine into the cache.
        if (isSyncEnabledPref()) {
            ensureEngine()
        } else {
            Log.i(TAG, "syncEnabled=false, skip warm engine")
        }
    }

    fun isSyncEnabledPref(): Boolean {
        return try {
            getSharedPreferences(FLUTTER_PREFS, MODE_PRIVATE)
                .getBoolean(KEY_SYNC_ENABLED, false)
        } catch (e: Exception) {
            Log.w(TAG, "isSyncEnabledPref failed", e)
            false
        }
    }

    /**
     * Put a FlutterActivity-created engine into the sole cache and register
     * headless channels so a later FGS start does not spawn a second isolate.
     */
    fun adoptEngineIfNeeded(engine: FlutterEngine) {
        val cache = FlutterEngineCache.getInstance()
        val existing = cache.get(ENGINE_ID)
        if (existing === engine) return
        if (existing != null) {
            Log.w(TAG, "adoptEngineIfNeeded: cache already has a different engine, keep existing")
            return
        }
        PlatformChannels.registerAll(this, engine)
        cache.put(ENGINE_ID, engine)
        createAttempts = 0
        creating = false
        Log.i(TAG, "Adopted FlutterActivity engine into cache")
    }

    /**
     * Create and cache the sole FlutterEngine (default entrypoint). Safe to call
     * repeatedly from FGS sticky rebuilds. Must run on the main thread.
     */
    fun ensureEngine() {
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) return
        if (creating) return
        if (createAttempts >= MAX_CREATE_ATTEMPTS) {
            Log.e(TAG, "ensureEngine: exceeded $MAX_CREATE_ATTEMPTS attempts, giving up")
            return
        }
        creating = true
        createAttempts++
        createEngine()
    }

    private fun createEngine() {
        val attempt = createAttempts
        try {
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            if (!flutterLoader.initialized()) {
                flutterLoader.startInitialization(this)
            }
            flutterLoader.ensureInitializationComplete(this, null)

            val engine = FlutterEngine(this)
            engine.lifecycleChannel.appIsResumed()
            io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)
            // storage/clipboard/notifications/sync_service — see PlatformChannels.
            PlatformChannels.registerAll(this, engine)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )

            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            Log.i(TAG, "Created and cached FlutterEngine (attempt=$attempt)")
            // Nudge Dart after bootstrap has a chance to finish SyncManager.init.
            mainHandler.postDelayed({
                try {
                    MethodChannel(engine.dartExecutor.binaryMessenger, SYNC_CONTROL_CHANNEL)
                        .invokeMethod("ensureSyncStarted", null)
                } catch (e: Exception) {
                    Log.w(TAG, "ensureSyncStarted invoke failed", e)
                }
                // Second nudge: drain any NLS posts buffered before Dart handler was ready.
                try {
                    MethodChannel(engine.dartExecutor.binaryMessenger, SYNC_CONTROL_CHANNEL)
                        .invokeMethod("drainNotificationInbox", null)
                } catch (e: Exception) {
                    Log.w(TAG, "drainNotificationInbox invoke failed", e)
                }
            }, 1500L)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create FlutterEngine (attempt=$attempt)", e)
            mainHandler.postDelayed({
                creating = false
                ensureEngine()
            }, 2000L)
            return
        }
        creating = false
    }

    fun startForegroundSyncService(): Boolean {
        return try {
            val intent = Intent(this, ClipySyncForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "startForegroundSync failed", e)
            false
        }
    }

    fun stopForegroundSyncService(): Boolean {
        return try {
            stopService(Intent(this, ClipySyncForegroundService::class.java))
            true
        } catch (e: Exception) {
            Log.e(TAG, "stopForegroundSync failed", e)
            false
        }
    }

    fun setClipboardText(text: String): Boolean {
        return try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("Clipy", text))
            true
        } catch (e: Exception) {
            Log.w(TAG, "setClipboardText failed", e)
            false
        }
    }

    /**
     * Drain clipboard text queued by Dart via SharedPreferences when the
     * MethodChannel path is stuck (force-kill, no Activity). Called from FGS.
     */
    fun drainHeadlessClipboard(): Boolean {
        return try {
            val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val key = "flutter.clipy.headlessClipboard"
            val text = flutterPrefs.getString(key, null) ?: return false
            if (text.isEmpty()) return false
            val ok = setClipboardText(text)
            if (ok) {
                flutterPrefs.edit().remove(key).commit()
                Log.i(TAG, "drainHeadlessClipboard: applied ${text.length} chars")
            }
            ok
        } catch (e: Exception) {
            Log.w(TAG, "drainHeadlessClipboard failed", e)
            false
        }
    }
}
