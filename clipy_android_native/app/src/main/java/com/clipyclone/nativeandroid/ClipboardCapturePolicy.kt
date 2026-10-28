package com.clipyclone.nativeandroid

/** Same defaults as the shipping Dart clipboard manager; an explicit list replaces them. */
internal object ClipboardCapturePolicy {
    private val defaultExcludedApps = listOf(
        "com.agilebits.onepassword7", "com.apple.keychainaccess",
        "com.android.onepassword", "com.agilebits.onepassword", "com.onepassword.android",
    )
    fun allows(source: String, configured: List<String>?): Boolean =
        (configured ?: defaultExcludedApps).none { it.equals(source, ignoreCase = true) }
}
