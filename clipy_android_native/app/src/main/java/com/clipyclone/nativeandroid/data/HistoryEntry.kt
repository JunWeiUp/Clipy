package com.clipyclone.nativeandroid.data

import java.security.MessageDigest

data class HistoryEntry(
    val id: Long, val hash: String?, val type: String, val value: String,
    val source: String?, val createdAt: Long,
) {
    // Bound paragraph shaping without splitting an emoji's surrogate pair.
    val preview: String get() {
        var end = minOf(600, value.length)
        if (end < value.length && end > 0 && value[end - 1].isHighSurrogate()) end--
        return value.substring(0, end).replace('\n', ' ') + if (end < value.length) "…" else ""
    }
}

enum class HistoryFilter { ALL, TEXT, LINKS, FILES, IMAGES }

object ContentHash {
    // Dart String.trim also strips BOM and Unicode whitespace (including NBSP).
    fun text(value: String): String {
        val normalized = value.trim { it in '\u0009'..'\u000D' || it == '\u0020' || it == '\u0085' ||
            it == '\u00A0' || it == '\u1680' || it in '\u2000'..'\u200A' ||
            it == '\u2028' || it == '\u2029' || it == '\u202F' || it == '\u205F' ||
            it == '\u3000' || it == '\uFEFF' }
            .replace("\r\n", "\n").replace('\r', '\n')
        return MessageDigest.getInstance("SHA-256").digest(normalized.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
