package com.clipyclone.nativeandroid.notifications

import android.content.Context
import android.util.Log
import com.clipyclone.clipy_android.NativePendingPostStore
import org.json.JSONObject
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

interface NativeNotificationSink {
    fun posted()
    fun removed(data: Map<String, Any?>)
    fun connectionChanged(connected: Boolean)
}
/** Bounded native NLS delivery, independent of any Activity or language engine. */
object NativeNotificationBridge {
    @Volatile var sink: NativeNotificationSink? = null
    private val worker = ThreadPoolExecutor(0, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue<Runnable>(64), ThreadPoolExecutor.DiscardOldestPolicy())
    fun post(context: Context, data: Map<String, Any?>) {
        val app = context.applicationContext
        if (!app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean("flutter.notificationSyncEnabled", false)) return
        worker.execute {
            try { NativePendingPostStore.insert(app, JSONObject(data).toString()); sink?.posted() }
            catch (e: Exception) { Log.w("ClipyNLS", "Notification persistence failed: ${e.javaClass.simpleName}") }
        }
    }
}
