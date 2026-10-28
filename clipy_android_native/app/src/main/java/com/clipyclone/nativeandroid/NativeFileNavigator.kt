package com.clipyclone.nativeandroid

import android.content.Context
import android.content.Intent
import android.os.Environment
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File

enum class OpenFileResult { OPENED, MISSING, NO_ACTIVITY, FAILED }

object NativeFileNavigator {
    fun openFolder(context: Context, path: String): OpenFileResult {
        val file = File(path)
        val dir = file.parentFile
        if (!file.exists() || dir?.isDirectory != true) return OpenFileResult.MISSING
        return try {
            if (openDirectory(context, dir) || openViewer(context, file)) OpenFileResult.OPENED else OpenFileResult.NO_ACTIVITY
        } catch (_: Exception) { OpenFileResult.FAILED }
    }
    private fun openDirectory(context: Context, directory: File): Boolean {
        @Suppress("DEPRECATION")
        val root = Environment.getExternalStorageDirectory().canonicalPath
        val path = directory.canonicalPath
        if (!path.startsWith(root + File.separator)) return false
        val relative = path.removePrefix(root + File.separator)
        val uri = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:$relative")
        val known = setOf("com.google.android.documentsui", "com.android.documentsui", "com.android.fileexplorer",
            "com.mi.android.globalFileexplorer", "com.sec.android.app.myfiles", "com.huawei.hidisk", "com.heytap.filemanager", "com.baidu.motor.filemanager")
        for (mime in arrayOf(DocumentsContract.Document.MIME_TYPE_DIR, "resource/folder")) {
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            @Suppress("DEPRECATION")
            val handlers = context.packageManager.queryIntentActivities(intent, 0)
            if (handlers.isEmpty()) continue
            handlers.firstOrNull { it.activityInfo.packageName in known }?.let { intent.setPackage(it.activityInfo.packageName) }
            try { context.startActivity(intent); return true } catch (_: Exception) { }
        }
        return false
    }
    private fun openViewer(context: Context, file: File): Boolean = try {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(context.packageManager) == null) false else { context.startActivity(intent); true }
    } catch (_: Exception) { false }
}
