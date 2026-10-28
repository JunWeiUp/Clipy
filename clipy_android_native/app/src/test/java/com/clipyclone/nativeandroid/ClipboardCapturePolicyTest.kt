package com.clipyclone.nativeandroid

import org.junit.Assert.*
import org.junit.Test

class ClipboardCapturePolicyTest {
    @Test fun absentPreferenceKeepsShippingPasswordManagerExclusions() {
        for (source in listOf("com.android.onepassword", "com.agilebits.onepassword", "com.onepassword.android")) {
            assertFalse(ClipboardCapturePolicy.allows(source, null))
            assertFalse(ClipboardCapturePolicy.allows(source.uppercase(), null))
        }
        assertTrue(ClipboardCapturePolicy.allows("com.example.editor", null))
    }
    @Test fun explicitUserPreferencesReplaceDefaultsIncludingAnEmptyList() {
        assertTrue(ClipboardCapturePolicy.allows("com.onepassword.android", emptyList()))
        assertFalse(ClipboardCapturePolicy.allows("com.example.private", listOf("COM.EXAMPLE.PRIVATE")))
        assertTrue(ClipboardCapturePolicy.allows("com.onepassword.android", listOf("com.example.private")))
    }
}
