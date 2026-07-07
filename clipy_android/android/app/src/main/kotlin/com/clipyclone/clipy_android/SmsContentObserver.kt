package com.clipyclone.clipy_android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat

class SmsContentObserver(private val context: Context) : ContentObserver(Handler(Looper.getMainLooper())) {
    private var lastSmsId: Long = -1
    private var isRegistered = false

    fun start(): Boolean {
        if (!hasReadSmsPermission()) return false
        if (isRegistered) return true
        return try {
            context.contentResolver.registerContentObserver(
                Telephony.Sms.CONTENT_URI,
                true,
                this,
            )
            isRegistered = true
            emitLatest()
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "SmsContentObserver: permission denied", e)
            false
        } catch (e: Exception) {
            Log.w(TAG, "SmsContentObserver: failed to register", e)
            false
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
        if (!hasReadSmsPermission()) return
        try {
            val cursor = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(
                    Telephony.Sms._ID,
                    Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY,
                    Telephony.Sms.DATE,
                    Telephony.Sms.TYPE,
                    Telephony.Sms.READ,
                ),
                null,
                null,
                "${Telephony.Sms.DATE} DESC",
            ) ?: return

            cursor.use {
                if (!it.moveToFirst()) return
                val smsId = it.getLong(0)
                if (smsId == lastSmsId) return
                lastSmsId = smsId

                val address = it.getString(1) ?: ""
                val body = it.getString(2) ?: ""
                if (body.isBlank()) return

                val date = it.getLong(3)
                val typeCode = it.getInt(4)
                val read = it.getInt(5) != 0
                val direction = when (typeCode) {
                    Telephony.Sms.MESSAGE_TYPE_INBOX -> "in"
                    Telephony.Sms.MESSAGE_TYPE_SENT -> "out"
                    else -> "unknown"
                }

                CollectorEventBridge.emit(
                    context = context,
                    category = "sms",
                    timestamp = date,
                    id = "sms_$smsId",
                    payload = mapOf(
                        "smsId" to smsId.toString(),
                        "address" to address,
                        "body" to body,
                        "direction" to direction,
                        "read" to read,
                    ),
                )
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "SmsContentObserver: query denied", e)
        } catch (e: Exception) {
            Log.w(TAG, "SmsContentObserver: query failed", e)
        }
    }

    private fun hasReadSmsPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_SMS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        private const val TAG = "ClipySmsObserver"
    }
}
