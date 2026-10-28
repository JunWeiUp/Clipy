package com.clipyclone.clipy_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import com.clipyclone.nativeandroid.sharing.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Bounded native counterpart of the existing inbox: no Activity or persistent worker retained. */
object SharedFileInbox {
    private const val MAX_BATCHES = 4
    private const val MAX_FILES = 32
    private const val MAX_FILE_BYTES = 1024L * 1024 * 1024
    private const val MAX_BYTES = 4 * MAX_FILE_BYTES
    private const val DISK_RESERVE = 64L * 1024 * 1024
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(0, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue<Runnable>())
    private val state = MutableStateFlow<List<IncomingShare>>(emptyList())
    val pending = state.asStateFlow()
    private var pendingImports = 0
    private var stagedBytes = 0L // worker-thread owned
    private var initialized = false
    private fun root(context: Context) = File(context.cacheDir, "incoming-shares")
    private fun initialize(context: Context) {
        if (!initialized) { root(context).deleteRecursively(); initialized = true }
        check(root(context).isDirectory || root(context).mkdirs())
    }
    fun enqueue(context: Context, intent: Intent) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return
        if (pendingImports + state.value.size >= MAX_BATCHES) {
            if (state.value.none { it.id == "overflow" }) state.value += IncomingShare("overflow", emptyList(), error = "busy")
            return
        }
        pendingImports++
        val app = context.applicationContext
        val copy = Intent(intent)
        worker.execute {
            val id = UUID.randomUUID().toString()
            val directory = File(root(app), id)
            val files = mutableListOf<SharedItem>()
            var text = ""; var error = ""
            try {
                initialize(app); check(directory.mkdirs())
                val uris = linkedSetOf<Uri>()
                if (copy.action == Intent.ACTION_SEND_MULTIPLE) {
                    IntentCompat.getParcelableArrayListExtra(copy, Intent.EXTRA_STREAM, Uri::class.java)?.let {
                        if (it.size > MAX_FILES) throw ShareImportException("tooMany"); uris.addAll(it)
                    }
                } else IntentCompat.getParcelableExtra(copy, Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::add)
                copy.clipData?.let { clip ->
                    if (clip.itemCount > MAX_FILES) throw ShareImportException("tooMany")
                    for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add)
                }
                if (uris.size > MAX_FILES) throw ShareImportException("tooMany")
                if (uris.isEmpty()) {
                    text = copy.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                        ?: copy.clipData?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.text?.toString() ?: ""
                    if (text.isEmpty()) throw ShareImportException("unreadable")
                    if (text.length > 1024 * 1024 || text.toByteArray(Charsets.UTF_8).size > 1024 * 1024) throw ShareImportException("tooLarge")
                } else uris.forEachIndexed { index, uri ->
                    try { files += importFile(app, uri, File(directory, index.toString()), index) }
                    catch (failure: Exception) { error = (failure as? ShareImportException)?.code ?: "unreadable" }
                }
            } catch (failure: Exception) {
                cleanupDirectory(directory)
                files.clear(); text = ""; error = (failure as? ShareImportException)?.code ?: "unreadable"
            }
            val batch = IncomingShare(id, files.toList(), text, error)
            main.post { pendingImports--; state.value += batch }
        }
    }
    fun complete(context: Context, id: String) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (state.value.none { it.id == id }) return
        state.value = state.value.filterNot { it.id == id }
        if (id == "overflow") return
        val app = context.applicationContext
        worker.execute { cleanupDirectory(File(root(app), id)) }
    }
    suspend fun stageSingle(context: Context, uri: Uri): StagedFile {
        val result = CompletableDeferred<StagedFile>()
        val cancelled = AtomicBoolean(false)
        val input = java.util.concurrent.atomic.AtomicReference<java.io.InputStream?>()
        val app = context.applicationContext
        val id = "picker-${UUID.randomUUID()}"
        worker.execute {
            val directory = File(root(app), id)
            try {
                initialize(app)
                val item = importFile(app, uri, directory, 0, cancelled = { cancelled.get() }, reader = { input.set(it) })
                val staged = StagedFile(File(item.path)) {
                    val completed = CompletableDeferred<Unit>()
                    worker.execute { cleanupDirectory(directory); completed.complete(Unit) }
                    completed.await()
                }
                if (cancelled.get()) cleanupDirectory(directory) else result.complete(staged)
            } catch (failure: Exception) {
                cleanupDirectory(directory)
                result.completeExceptionally(if (failure is ShareImportException) failure else ShareImportException("unreadable"))
            }
        }
        return try { result.await() }
        catch (cancel: CancellationException) {
            cancelled.set(true)
            withContext(NonCancellable + Dispatchers.IO) { runCatching { input.getAndSet(null)?.close() } }
            worker.execute { cleanupDirectory(File(root(app), id)) }
            throw cancel
        }
    }
    private fun importFile(context: Context, uri: Uri, directory: File, index: Int, cancelled: () -> Boolean = { false }, reader: (java.io.InputStream?) -> Unit = {}): SharedItem {
        var copied = 0L
        try {
            require(uri.scheme == "content" && uri.authority != "${context.packageName}.fileprovider")
            check(directory.mkdirs())
            val available = StatFs(root(context).absolutePath).availableBytes - DISK_RESERVE
            val file = File(directory, displayName(context, uri, index))
            context.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input)
                reader(input)
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (cancelled()) throw ShareImportException("cancelled")
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (copied + count > MAX_FILE_BYTES) throw ShareImportException("tooLarge")
                        if (stagedBytes + copied + count > MAX_BYTES || copied + count > available) throw ShareImportException("storageFull")
                        output.write(buffer, 0, count); copied += count
                    }
                }
            }
            stagedBytes += copied
            return SharedItem(file.absolutePath, file.name, copied)
        } catch (failure: Exception) { directory.deleteRecursively(); throw failure }
        finally { reader(null) }
    }
    private fun cleanupDirectory(directory: File) {
        val size = directory.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        if (directory.deleteRecursively()) stagedBytes = (stagedBytes - size).coerceAtLeast(0)
    }
    private fun displayName(context: Context, uri: Uri, index: Int): String {
        val raw = try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        } catch (_: Exception) { null } ?: "shared-file-${index + 1}"
        return raw.replace(Regex("[\\\\/\\p{Cntrl}]"), "_").take(120)
            .takeUnless { it.isBlank() || it == "." || it == ".." } ?: "shared-file-${index + 1}"
    }
}
