package com.clipyclone.clipy_android

import android.app.ActivityManager
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

class ClipboardChangeListener(
    private val context: Context,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val clipboard =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val activityManager =
        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private var methodChannel: MethodChannel? = null
    private var attached = false

    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        handler.post { emitCurrentClipboard(isBaseline = false) }
    }

    fun attach(channel: MethodChannel) {
        if (attached) return
        methodChannel = channel
        clipboard.addPrimaryClipChangedListener(listener)
        attached = true
        emitCurrentClipboard(isBaseline = true)
    }

    fun detach() {
        if (!attached) return
        clipboard.removePrimaryClipChangedListener(listener)
        methodChannel = null
        attached = false
    }

    fun emitCurrentClipboard(isBaseline: Boolean) {
        val channel = methodChannel ?: return
        try {
            val clip = clipboard.primaryClip ?: return
            if (clip.itemCount == 0) return
            val text = clip.getItemAt(0).coerceToText(context)?.toString()?.trim().orEmpty()
            if (text.isEmpty()) return
            val sourcePackage = resolveSourcePackage()
            channel.invokeMethod(
                "onClipboardChanged",
                mapOf(
                    "text" to text,
                    "isBaseline" to isBaseline,
                    "sourcePackage" to sourcePackage,
                ),
            )
        } catch (_: Exception) {
        }
    }

    /**
     * Best-effort resolution of the package that produced the current clip.
     *
     * Android does not expose the clipboard source via a public API. Since
     * Android 5.0 `ActivityManager.getRunningAppProcesses` returns only the
     * caller's own process for privacy, so this heuristic is unreliable on
     * modern devices — it typically yields our own package. We still report it
     * so the Dart side can at least match excludedApps against the real package
     * id when the OEM/ROM does disclose it, and fall back gracefully otherwise.
     */
    private fun resolveSourcePackage(): String? {
        try {
            val processes = activityManager.runningAppProcesses ?: return null
            val foreground = processes
                .filter { it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND }
                .minByOrNull { it.lastTrimLevel }
                ?: processes.firstOrNull()
            return foreground?.processName?.let { name ->
                // Running app process entries are "<package>:<process>"; keep the package.
                name.substringBefore(':')
            }
        } catch (_: Exception) {
            return null
        }
    }
}
