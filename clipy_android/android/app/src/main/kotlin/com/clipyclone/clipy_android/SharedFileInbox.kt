package com.clipyclone.clipy_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Process-scoped, bounded temporary inbox. No Activity, polling or permanent worker is retained. */
object SharedFileInbox {
    private const val CHANNEL = "com.clipyclone.clipy_android/incoming_share"
    private const val MAX_BATCHES = 4
    private const val MAX_FILES = 32
    private const val MAX_FILE_BYTES = 1024L * 1024 * 1024
    private const val MAX_BYTES = 4 * MAX_FILE_BYTES
    private const val DISK_RESERVE = 64L * 1024 * 1024
    private class ImportFailure(val reason: String) : Exception()
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(0, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue())
    private var channel: MethodChannel? = null
    // Main-thread owned. Entries stay here until explicit completion/cancellation.
    private val batches = linkedMapOf<String, Map<String, Any>>()
    private var pending = 0
    // Worker-thread owned; bounds the entire inbox, not just individual files.
    private var stagedBytes = 0L
    private var initialized = false

    fun attach(context: Context, engine: FlutterEngine): MethodChannel {
        val next = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = next
        next.setMethodCallHandler { call, result ->
            when (call.method) {
                "next" -> result.success(batches.values.firstOrNull())
                "complete" -> {
                    val id = call.argument<String>("id")
                    if (id != null && batches.remove(id) != null) {
                        worker.execute {
                            val directory = File(root(context), id)
                            val size = directory.walkTopDown().filter { it.isFile }.sumOf { it.length() }
                            directory.deleteRecursively()
                            stagedBytes = (stagedBytes - size).coerceAtLeast(0)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return next
    }

    fun detach(previous: MethodChannel) {
        if (channel === previous) {
            previous.setMethodCallHandler(null)
            channel = null
        }
    }

    fun enqueue(context: Context, intent: Intent) {
        if (pending + batches.size >= MAX_BATCHES) {
            // Keep a visible error even when Dart is not attached yet.
            batches["overflow"] = mapOf("id" to "overflow", "files" to emptyList<Any>(), "error" to "busy")
            channel?.invokeMethod("ready", null)
            return
        }
        pending++
        val app = context.applicationContext
        worker.execute {
            val id = UUID.randomUUID().toString()
            val files = mutableListOf<Map<String, Any>>()
            var error = ""
            val directory = File(root(app), id)
            try {
                // A previous process cannot still own a transfer. Remove its orphaned cache once.
                if (!initialized) {
                    root(app).deleteRecursively()
                    initialized = true
                }
                check(directory.mkdirs())
                val uris = linkedSetOf<Uri>()
                if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                    IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                        ?.let { if (it.size > MAX_FILES) throw ImportFailure("tooMany"); uris.addAll(it) }
                } else {
                    IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let { uris.add(it) }
                }
                intent.clipData?.let { clip ->
                    if (clip.itemCount > MAX_FILES) throw ImportFailure("tooMany")
                    for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
                }
                if (uris.size > MAX_FILES) throw ImportFailure("tooMany")
                if (uris.isEmpty()) {
                    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                    require(!text.isNullOrEmpty() && text.length <= 1024 * 1024)
                    val bytes = text.toByteArray(Charsets.UTF_8)
                    check(stagedBytes + bytes.size <= MAX_BYTES)
                    val file = File(directory, "shared-text.txt")
                    file.writeBytes(bytes)
                    stagedBytes += bytes.size
                    files.add(metadata(file))
                } else {
                    for ((index, uri) in uris.withIndex()) {
                        val fileDirectory = File(directory, index.toString()).apply { mkdirs() }
                        var copied = 0L
                        try {
                            // Never accept file:// paths that could expose this app's private files.
                            require(uri.scheme == "content")
                            require(uri.authority != "${app.packageName}.fileprovider")
                            val available = StatFs(root(app).absolutePath).availableBytes - DISK_RESERVE
                            val file = File(fileDirectory, displayName(app, uri, index))
                            app.contentResolver.openInputStream(uri).use { input ->
                                requireNotNull(input)
                                file.outputStream().use { output ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (true) {
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        if (copied + count > MAX_FILE_BYTES) throw ImportFailure("tooLarge")
                                        if (stagedBytes + copied + count > MAX_BYTES || copied + count > available) throw ImportFailure("storageFull")
                                        output.write(buffer, 0, count)
                                        copied += count
                                    }
                                }
                            }
                            stagedBytes += copied
                            files.add(metadata(file))
                        } catch (failure: Exception) {
                            fileDirectory.deleteRecursively()
                            error = (failure as? ImportFailure)?.reason ?: "unreadable"
                        }
                    }
                }
            } catch (failure: Exception) {
                directory.deleteRecursively()
                error = (failure as? ImportFailure)?.reason ?: "unreadable"
            }
            val batch = mapOf("id" to id, "files" to files, "error" to error)
            main.post {
                pending--
                batches[id] = batch
                channel?.invokeMethod("ready", null)
            }
        }
    }

    private fun root(context: Context) = File(context.cacheDir, "incoming-shares")

    private fun metadata(file: File): Map<String, Any> =
        mapOf("path" to file.absolutePath, "name" to file.name, "size" to file.length())

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
