package com.clipyclone.clipy_android

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
            channel.invokeMethod(
                "onClipboardChanged",
                mapOf(
                    "text" to text,
                    "isBaseline" to isBaseline,
                ),
            )
        } catch (_: Exception) {
        }
    }
}
