package com.clipyclone.clipy_android

import android.content.Context
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue

object CollectorEventBridge {
    private var methodChannel: MethodChannel? = null
    private val pendingEvents = ConcurrentLinkedQueue<Map<String, Any?>>()

    fun setMethodChannel(channel: MethodChannel?) {
        methodChannel = channel
        flushPending()
    }

    fun emit(
        context: Context,
        category: String,
        payload: Map<String, Any?>,
        timestamp: Long = System.currentTimeMillis(),
        id: String? = null,
    ) {
        val event = mapOf(
            "id" to (id ?: "${System.nanoTime()}_$category"),
            "category" to category,
            "timestamp" to timestamp,
            "payload" to payload.mapValues { entry ->
                when (val value = entry.value) {
                    null -> ""
                    is Boolean -> value
                    is Number -> value
                    else -> value.toString()
                }
            },
        )

        val channel = methodChannel
        if (channel == null) {
            pendingEvents.add(event)
            return
        }

        try {
            channel.invokeMethod("onCollectorEvent", event)
        } catch (_: Exception) {
            pendingEvents.add(event)
        }
    }

    private fun flushPending() {
        val channel = methodChannel ?: return
        while (true) {
            val event = pendingEvents.poll() ?: return
            try {
                channel.invokeMethod("onCollectorEvent", event)
            } catch (_: Exception) {
                pendingEvents.add(event)
                return
            }
        }
    }
}
