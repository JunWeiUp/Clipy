package com.clipyclone.nativeandroid

import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.clipyclone.nativeandroid.data.ContentHash
import com.clipyclone.nativeandroid.sync.HistoryWrite
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Foreground event listener + resume catch-up. No background polling or Flutter channel. */
class NativeClipboard(
    private val context: Context, private val scope: CoroutineScope,
    private val store: suspend (String, String, Boolean) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val clipboard: ClipboardManager by lazy(LazyThreadSafetyMode.NONE) {
        check(Looper.myLooper() == Looper.getMainLooper())
        context.getSystemService(ClipboardManager::class.java)
    }
    private var attached = false
    private var lastText: String? = null
    private var generation = 0L
    private val remoteHashes = ArrayDeque<Pair<String, Long>>()
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        handler.post { if (attached) capture(resolveSource(), nativeEvent = true) }
    }
    fun attach() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (!attached) { attached = true; clipboard.addPrimaryClipChangedListener(listener) }
        capture("Android")
    }
    fun detach() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (attached) clipboard.removePrimaryClipChangedListener(listener)
        attached = false
    }
    fun onFocus() { if (attached) capture("Android") }
    private fun capture(source: String, nativeEvent: Boolean = false) {
        val raw = try {
            val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return
            if (nativeEvent) item.coerceToText(context)?.toString()
            else item.text?.toString() ?: item.uri?.takeIf { it.scheme == "content" }?.let { uri ->
                // Match Flutter's plain-text poll: non-text/content-URI clipboard
                // items must not turn into spurious URL history entries on resume.
                context.contentResolver.openTypedAssetFileDescriptor(uri, "text/*", null).use {
                    item.coerceToText(context)?.toString()
                }
            }
        }
        catch (_: Exception) { null } ?: return
        if (raw == lastText) return
        // The existing Kotlin listener trims its events, while Dart's foreground/
        // resume poll reads the original text. Keep indentation/newlines on resume.
        val text = if (nativeEvent) raw.trim() else raw
        if (text.isEmpty() || text == lastText) return
        val previous = lastText
        val baseline = previous == null
        val token = ++generation
        lastText = text
        if (baseline) return
        val hash = ContentHash.text(text)
        prune()
        val broadcast = remoteHashes.none { it.first == hash }
        scope.launch {
            try { store(text, source, broadcast) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (error: Exception) {
                handler.post { if (generation == token) lastText = previous }
                android.util.Log.w("ClipyClipboard", "History persistence failed: ${error.javaClass.simpleName}")
            }
        }
    }
    /** Explicit history copy does not fabricate a new history row or re-broadcast it. */
    fun copy(text: String): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper())
        return try { clipboard.setPrimaryClip(ClipData.newPlainText("Clipy", text)); lastText = text; generation++; true }
        catch (_: Exception) { false }
    }
    fun acceptRemote(write: HistoryWrite) {
        handler.post {
            val now = android.os.SystemClock.elapsedRealtime()
            write.remoteHashes.forEach { remoteHashes.addLast(it to now) }
            prune()
            write.lastText?.let { lastText = it; generation++ }
            write.clipboardText?.let(::copy)
        }
    }
    fun drainPendingClipboard() {
        handler.post {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val key = "flutter.clipy.headlessClipboard"
            val text = prefs.getString(key, null)
            if (!text.isNullOrEmpty() && copy(text)) prefs.edit().remove(key).apply()
        }
    }
    private fun prune() {
        val cutoff = android.os.SystemClock.elapsedRealtime() - 60000
        while (remoteHashes.isNotEmpty() && (remoteHashes.first().second < cutoff || remoteHashes.size > 20)) remoteHashes.removeFirst()
    }
    private fun resolveSource(): String = try {
        context.getSystemService(ActivityManager::class.java).runningAppProcesses
            ?.filter { it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND }
            ?.minByOrNull { it.lastTrimLevel }?.processName?.substringBefore(':') ?: "Android"
    } catch (_: Exception) { "Android" }
}
