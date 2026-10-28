package com.clipyclone.clipy_android

import com.clipyclone.nativeandroid.R
import com.clipyclone.nativeandroid.MainActivity

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/** Opens the existing singleTask native host from either sync notification. */
internal object SyncNotificationIntent {
    fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context,
            0x7101,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
