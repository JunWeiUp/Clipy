package com.clipyclone.nativeandroid.sharing

import java.io.File

data class SharedItem(val path: String, val name: String, val size: Long)
data class IncomingShare(val id: String, val files: List<SharedItem>, val text: String = "", val error: String = "") {
    val itemCount: Int get() = files.size + if (text.isEmpty()) 0 else 1
}
class ShareImportException(val code: String) : Exception(code)
class StagedFile(val file: File, private val cleanup: suspend () -> Unit) {
    suspend fun close() = cleanup()
}
