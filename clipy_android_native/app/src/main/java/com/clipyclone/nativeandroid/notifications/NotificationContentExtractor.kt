package com.clipyclone.nativeandroid.notifications

import android.app.Notification
import android.os.Build
import android.os.Bundle

/** Preserves InboxStyle/MessagingStyle's newest text, including the pre-public-API Bundle format. */
object NotificationContentExtractor {
    fun body(extras: Bundle, flat: Map<String, String>, sdk: Int = Build.VERSION.SDK_INT): String {
        try {
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.reversed()?.forEach {
                it?.toString()?.trim()?.takeIf(String::isNotEmpty)?.let { line -> return line }
            }
        } catch (_: Exception) { }
        try {
            @Suppress("DEPRECATION")
            val parcels = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
            if (parcels != null) {
                if (Build.VERSION.SDK_INT >= 30 && sdk >= 30) {
                    Notification.MessagingStyle.Message.getMessagesFromBundleArray(parcels).asReversed().forEach {
                        it.text?.toString()?.trim()?.takeIf(String::isNotEmpty)?.let { text -> return text }
                    }
                } else {
                    // Notification.Message.toBundle() has used text/time/sender since API24.
                    // Its public decoder arrived in API30. The existing Clipy body is Message.text,
                    // while notification title/subtitle retain the sender/conversation separately.
                    parcels.reversed().forEach { parcel ->
                        val message = parcel as? Bundle ?: return@forEach
                        if (!message.containsKey("text") || !message.containsKey("time")) return@forEach
                        message.getCharSequence("text")?.toString()?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
                    }
                }
            }
        } catch (_: Exception) { }
        flat[Notification.EXTRA_TEXT_LINES]?.split('\n')?.map(String::trim)?.lastOrNull(String::isNotEmpty)?.let { return it }
        return extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: flat[Notification.EXTRA_BIG_TEXT] ?: flat[Notification.EXTRA_TEXT] ?: ""
    }
}
