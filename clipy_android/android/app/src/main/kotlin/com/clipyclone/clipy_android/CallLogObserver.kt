package com.clipyclone.clipy_android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import androidx.core.content.ContextCompat

class CallLogObserver(private val context: Context) : ContentObserver(Handler(Looper.getMainLooper())) {
    private var lastLogId: Long = -1
    private var isRegistered = false

    fun start() {
        if (!hasCallLogPermission()) return
        try {
            context.contentResolver.registerContentObserver(
                CallLog.Calls.CONTENT_URI,
                true,
                this,
            )
            isRegistered = true
            emitLatest()
        } catch (_: SecurityException) {
        }
    }

    fun stop() {
        if (!isRegistered) return
        try {
            context.contentResolver.unregisterContentObserver(this)
        } catch (_: Exception) {
        }
        isRegistered = false
    }

    override fun onChange(selfChange: Boolean) {
        emitLatest()
    }

    private fun emitLatest() {
        try {
            val cursor = context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls._ID,
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                    CallLog.Calls.DURATION,
                ),
                null,
                null,
                "${CallLog.Calls.DATE} DESC",
            ) ?: return

            cursor.use {
                if (!it.moveToFirst()) return
                val logId = it.getLong(0)
                if (logId == lastLogId) return
                lastLogId = logId

                val number = it.getString(1) ?: ""
                val typeCode = it.getInt(2)
                val date = it.getLong(3)
                val duration = it.getLong(4)
                val type = when (typeCode) {
                    CallLog.Calls.INCOMING_TYPE -> "incoming"
                    CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    CallLog.Calls.MISSED_TYPE -> "missed"
                    else -> "unknown"
                }

                CollectorEventBridge.emit(
                    context = context,
                    category = "call_log",
                    timestamp = date,
                    payload = mapOf(
                        "logId" to logId.toString(),
                        "phoneNumber" to number,
                        "type" to type,
                        "date" to date.toString(),
                        "duration" to duration.toString(),
                    ),
                )
            }
        } catch (_: SecurityException) {
        }
    }

    private fun hasCallLogPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_CALL_LOG,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
