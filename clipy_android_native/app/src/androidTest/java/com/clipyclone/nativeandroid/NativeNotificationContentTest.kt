package com.clipyclone.nativeandroid

import android.app.Notification
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clipyclone.nativeandroid.notifications.NotificationContentExtractor
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeNotificationContentTest {
    @Test fun foldedInboxPrefersLastRealLineOverSummary() {
        val extras = Bundle().apply {
            putCharSequence(Notification.EXTRA_TEXT, "2 new messages")
            putCharSequenceArray(Notification.EXTRA_TEXT_LINES, arrayOf("First", " Latest message ", " "))
        }
        assertEquals("Latest message", NotificationContentExtractor.body(extras, emptyMap()))
    }
    @Test fun pre30MessagingBundlesRetainNewestTextAndSkipMalformedEntries() {
        val first = Bundle().apply { putCharSequence("text", "First"); putLong("time", 1); putCharSequence("sender", "Sender A") }
        val second = Bundle().apply { putCharSequence("text", "Newest 世界"); putLong("time", 2); putCharSequence("sender", "Sender B") }
        val malformed = Bundle().apply { putCharSequence("text", "Missing timestamp") }
        val extras = Bundle().apply { putParcelableArray(Notification.EXTRA_MESSAGES, arrayOf(first, second, malformed)) }
        assertEquals("Newest 世界", NotificationContentExtractor.body(extras, emptyMap(), sdk = 24))
        assertEquals("Newest 世界", NotificationContentExtractor.body(extras, emptyMap()))
    }
    @Test fun bigTextAndFlatLinesKeepExistingFallbackOrder() {
        val extras = Bundle().apply { putCharSequence(Notification.EXTRA_BIG_TEXT, "Expanded"); putCharSequence(Notification.EXTRA_TEXT, "Summary") }
        assertEquals("Expanded", NotificationContentExtractor.body(extras, emptyMap()))
        assertEquals("Latest flat line", NotificationContentExtractor.body(Bundle(), mapOf(Notification.EXTRA_TEXT_LINES to "Old\nLatest flat line")))
    }
}
