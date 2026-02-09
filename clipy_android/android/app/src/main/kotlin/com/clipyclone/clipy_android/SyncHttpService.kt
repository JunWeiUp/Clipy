package com.clipyclone.clipy_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.call
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.request.receiveText
import io.ktor.server.response.respond
import io.ktor.server.routing.post
import io.ktor.server.routing.routing

class SyncHttpService : Service() {
    private var server: ApplicationEngine? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification()
        startServer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (server == null) {
            startServer()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        server?.stop(1000, 2000)
        server = null
        if (engine != null && FlutterEngineCache.getInstance().get(MAIN_ENGINE_ID) != engine) {
            engine?.destroy()
        }
        engine = null
        channel = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startServer() {
        server = embeddedServer(Netty, host = "0.0.0.0", port = 8080) {
            configureRouting()
        }.start(wait = false)
    }

    private fun Application.configureRouting() {
        routing {
            post("/sync") {
                val body = call.receiveText()
                dispatchPayload(body)
                call.respond(HttpStatusCode.OK)
            }
        }
    }

    private fun dispatchPayload(payload: String) {
        val channel = getChannel()
        channel.invokeMethod("onSyncPayload", payload)
    }

    private fun getChannel(): MethodChannel {
        if (channel != null) return channel!!
        val cachedEngine = FlutterEngineCache.getInstance().get(MAIN_ENGINE_ID)
        if (cachedEngine != null) {
            engine = cachedEngine
            channel = MethodChannel(cachedEngine.dartExecutor.binaryMessenger, DATA_CHANNEL)
            return channel!!
        }
        ensureBackgroundEngine()
        return channel!!
    }

    private fun ensureBackgroundEngine() {
        if (engine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        engine = FlutterEngine(this)
        val entrypoint = DartExecutor.DartEntrypoint(loader.findAppBundlePath(), BACKGROUND_ENTRYPOINT)
        engine!!.dartExecutor.executeDartEntrypoint(entrypoint)
        channel = MethodChannel(engine!!.dartExecutor.binaryMessenger, DATA_CHANNEL)
    }

    private fun startForegroundNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    "Clipy Sync",
                    NotificationManager.IMPORTANCE_LOW
                )
                manager.createNotificationChannel(channel)
            }
        }
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Clipy Sync")
            .setContentText("Sync service running")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    companion object {
        private const val NOTIFICATION_CHANNEL_ID = "clipy_sync_service"
        private const val NOTIFICATION_ID = 1001
        private const val DATA_CHANNEL = "clipy_sync_service"
        private const val BACKGROUND_ENTRYPOINT = "syncBackgroundMain"
        private const val MAIN_ENGINE_ID = "main_engine"

        fun start(context: Context) {
            val intent = Intent(context, SyncHttpService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, SyncHttpService::class.java)
            context.stopService(intent)
        }
    }
}
