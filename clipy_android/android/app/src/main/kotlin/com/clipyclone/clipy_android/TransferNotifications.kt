package com.clipyclone.clipy_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/** App-owned path tokens survive cold-start taps; exported intents cannot supply paths. */
object TransferNotifications {
    const val ACTION = "com.clipyclone.clipy_android.OPEN_RECEIVED_FILE"
    const val TOKEN = "transferToken"
    private const val CHANNEL = "clipy_received_files"
    private const val STORE = "received_file_notifications"

    fun register(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger,
            "com.clipyclone.clipy_android/transfer_notifications").setMethodCallHandler { call, result ->
            if (call.method == "initialize") { result.success(null); return@setMethodCallHandler }
            if (call.method != "received") { result.notImplemented(); return@setMethodCallHandler }
            try {
                val path = call.argument<String>("path") ?: error("Missing path")
                val file = File(path)
                require(file.isFile)
                val chinese = context.resources.configuration.locales[0].language == "zh"
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= 26) {
                    manager.createNotificationChannel(NotificationChannel(CHANNEL,
                        if (chinese) "接收文件" else "Received files", NotificationManager.IMPORTANCE_HIGH))
                }
                val token = UUID.randomUUID().toString()
                val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
                val edit = prefs.edit()
                // Android retains at most 50 notifications per app. Bound tap metadata too.
                if (prefs.all.size >= 48) {
                    val stale = prefs.all.keys.first()
                    edit.remove(stale)
                    manager.cancel(stale, 0)
                }
                edit.putString(token, file.canonicalPath).apply()
                val intent = Intent(context, MainActivity::class.java).setAction(ACTION)
                    .setData(Uri.parse("clipy-received://$token"))
                    .putExtra(TOKEN, token)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                val tap = PendingIntent.getActivity(context, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val sender = call.argument<String>("sender") ?: ""
                val body = if (chinese) "来自 $sender · 点击打开文件位置" else "From $sender · Tap to open file location"
                manager.notify(token, 0, NotificationCompat.Builder(context, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle(if (chinese) "已接收：${file.name}" else "Received: ${file.name}")
                    .setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setContentIntent(tap).setAutoCancel(true).build())
                result.success(null)
            } catch (e: Exception) { result.error("NOTIFICATION", e.message, null) }
        }
    }

    fun takePath(context: Context, intent: Intent): String? {
        if (intent.action != ACTION) return null
        val token = intent.getStringExtra(TOKEN) ?: return null
        intent.removeExtra(TOKEN)
        val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        val path = prefs.getString(token, null)
        prefs.edit().remove(token).apply()
        return path
    }
}
