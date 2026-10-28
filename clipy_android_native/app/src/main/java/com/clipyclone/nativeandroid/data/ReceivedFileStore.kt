package com.clipyclone.nativeandroid.data

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

data class ReceivedFile(val id: Long, val name: String, val path: String, val size: Long,
                        val sender: String, val createdAt: Long)

/** Owns receive-directory selection, atomic publication, history, and managed-file trimming. */
class ReceivedFileStore(
    private val context: Context,
    private val databaseFile: File = File(context.filesDir, "clipy.db"),
    private val downloads: File? = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
    private val privateDirectory: File = File(context.filesDir, "Clipy"),
) {
    private val directoryLock = Mutex()
    private val publication = Mutex()
    @Volatile private var chosenDirectory: File? = null
    suspend fun directory(): File = withContext(Dispatchers.IO) {
        directoryLock.withLock {
            chosenDirectory ?: run {
                val public = downloads?.let { File(it, "Clipy") }
                val selected = if (public != null && writable(public)) public else {
                    check(writable(privateDirectory)) { "Receive directory unavailable" }; privateDirectory
                }
                selected.canonicalFile.also { chosenDirectory = it }
            }
        }
    }
    private fun writable(directory: File): Boolean = try {
        check(directory.isDirectory || directory.mkdirs())
        File.createTempFile(".clipy-probe-", ".tmp", directory).let { check(it.delete()) }
        true
    } catch (_: Exception) { false }
    suspend fun createPart(): File {
        var created: File? = null
        try {
            return withContext(Dispatchers.IO) {
                // The remote fileId is never used as a pathname.
                File.createTempFile(".incoming-", ".part", directory()).also { created = it }
            }
        } catch (cancelled: CancellationException) {
            withContext(NonCancellable + Dispatchers.IO) { runCatching { created?.delete() } }
            throw cancelled
        }
    }
    suspend fun publish(part: File, requestedName: String, size: Long, sender: String): ReceivedFile = withContext(Dispatchers.IO) {
        publication.withLock {
            val dir = directory()
            require(part.parentFile?.canonicalFile == dir && part.isFile && part.length() == size)
            val name = sanitizeFileName(requestedName)
            val target = reserveDestination(dir, name)
            var committed = false
            try {
                if (!part.renameTo(target)) throw IOException("Could not publish received file")
                val expired = mutableListOf<String>()
                val record = ClipyDatabase(context, databaseFile).use { helper ->
                    val db = helper.writableDatabase
                    db.beginTransaction()
                    try {
                        val now = System.currentTimeMillis()
                        val id = db.insertOrThrow("file_transfers", null, ContentValues().apply {
                            put("file_name", name); put("file_path", target.absolutePath); put("file_size", size)
                            put("sender_name", sender); put("created_at", now)
                        })
                        db.rawQuery("SELECT file_path FROM file_transfers WHERE id NOT IN (SELECT id FROM file_transfers ORDER BY created_at DESC,id DESC LIMIT 20)", null).use { cursor ->
                            while (cursor.moveToNext()) expired += cursor.getString(0)
                        }
                        db.execSQL("DELETE FROM file_transfers WHERE id NOT IN (SELECT id FROM file_transfers ORDER BY created_at DESC,id DESC LIMIT 20)")
                        db.setTransactionSuccessful()
                        ReceivedFile(id, name, target.absolutePath, size, sender, now)
                    } finally { db.endTransaction() }
                }
                committed = true
                // Cleanup is best-effort after the new record commits; it cannot turn success into a failed ACK.
                expired.forEach { path -> runCatching { if (File(path).isFile && isManaged(File(path))) File(path).delete() } }
                record
            } finally {
                if (!committed) { runCatching { target.delete() }; runCatching { part.delete() } }
            }
        }
    }
    suspend fun page(offset: Int = 0, limit: Int = 20): List<ReceivedFile> = withContext(Dispatchers.IO) {
        require(offset >= 0 && limit > 0)
        ClipyDatabase(context, databaseFile).use { helper ->
            helper.readableDatabase.query("file_transfers", null, null, null, null, null, "created_at DESC,id DESC", "$offset,$limit").use { c ->
                buildList {
                    while (c.moveToNext()) add(ReceivedFile(c.getLong(c.getColumnIndexOrThrow("id")),
                        c.getString(c.getColumnIndexOrThrow("file_name")), c.getString(c.getColumnIndexOrThrow("file_path")),
                        c.getLong(c.getColumnIndexOrThrow("file_size")), c.getString(c.getColumnIndexOrThrow("sender_name")),
                        c.getLong(c.getColumnIndexOrThrow("created_at"))))
                }
            }
        }
    }
    suspend fun delete(record: ReceivedFile) = withContext(Dispatchers.IO) {
        publication.withLock {
            val file = File(record.path)
            if (file.exists() && (!file.isFile || !file.delete())) throw IOException("File deletion failed; record retained")
            ClipyDatabase(context, databaseFile).use { it.writableDatabase.delete("file_transfers", "id=?", arrayOf(record.id.toString())) }
        }
    }
    private fun isManaged(file: File): Boolean {
        val path = file.canonicalPath
        return listOfNotNull(downloads?.let { File(it, "Clipy") }, privateDirectory).any {
            path.startsWith(it.canonicalPath + File.separator)
        }
    }
    private fun reserveDestination(dir: File, name: String): File {
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val suffix = if (dot > 0) name.substring(dot) else ""
        var index = 1
        while (true) {
            val file = File(dir, if (index == 1) name else "$stem ($index)$suffix")
            if (file.createNewFile()) return file
            index++
        }
    }
    companion object {
        fun sanitizeFileName(name: String): String = name.replace('/', '_').replace('\\', '_')
            .replace("\u0000", "").trimStart('.').ifEmpty { "file" }
    }
}
