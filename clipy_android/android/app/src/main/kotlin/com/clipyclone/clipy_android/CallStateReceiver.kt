package com.clipyclone.clipy_android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager

class CallStateReceiver : BroadcastReceiver() {
    companion object {
        private var lastState: String? = null
        private var lastNumber: String? = null
        private var offhookAt: Long = 0
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: lastNumber ?: ""

        val mappedState = when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
            TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"
            TelephonyManager.EXTRA_STATE_IDLE -> "idle"
            else -> state.lowercase()
        }

        val direction = when {
            mappedState == "ringing" -> "incoming"
            lastState == "ringing" && mappedState == "offhook" -> "incoming"
            lastState == null && mappedState == "offhook" -> "outgoing"
            else -> "unknown"
        }

        var duration = 0L
        if (mappedState == "offhook") {
            offhookAt = System.currentTimeMillis()
        } else if (mappedState == "idle" && offhookAt > 0) {
            duration = System.currentTimeMillis() - offhookAt
            offhookAt = 0
        }

        if (number.isNotBlank()) {
            lastNumber = number
        }

        CollectorEventBridge.emit(
            context = context,
            category = "call",
            payload = mapOf(
                "phoneNumber" to (lastNumber ?: ""),
                "state" to mappedState,
                "direction" to direction,
                "duration" to duration,
            ),
        )

        lastState = mappedState
        if (mappedState == "idle") {
            lastNumber = null
        }
    }
}
