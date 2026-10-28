package com.clipyclone.nativeandroid.sync

import com.clipyclone.nativeandroid.data.ReceivedFile
import com.clipyclone.nativeandroid.data.ReceivedFileStore
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

const val FILE_CHUNK_BYTES = 1024 * 1024
const val FILE_MAX_BYTES = 1024 * 1024 * 1024L

data class FileProgress(val fileId: String, val name: String, val transferred: Long, val total: Long,
                        val outgoing: Boolean, val completed: Boolean = false, val failed: Boolean = false) {
    val fraction: Float get() = if (total == 0L) if (completed) 1f else 0f else (transferred.toDouble() / total).toFloat().coerceIn(0f, 1f)
}

/** Interactive v3 transfers. No file frame is placed in pending_sync or resumed after a disconnect. */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeFileTransfer(
    ownerScope: CoroutineScope,
    private val identity: () -> Pair<String, String>,
    private val crypto: SyncCrypto,
    private val storage: ReceivedFileStore,
    private val channel: suspend (String) -> SyncChannel?,
    private val reply: suspend (LanPeer, SyncEnvelope) -> Boolean,
    private val received: (ReceivedFile) -> Unit,
    private val idleTimeoutMs: Long = 120000,
) {
    private data class Key(val peer: String, val file: String)
    private class Outgoing(val peer: String, val result: CompletableDeferred<Boolean>) {
        @Volatile var connectionId: String? = null
    }
    private class Incoming(val peer: LanPeer, val fileId: String, val name: String, val size: Long,
                           val chunkSize: Int, val chunks: Int, val hash: String, val part: File,
                           val generation: Long, val sender: String) {
        val mutex = Mutex()
        var writer: RandomAccessFile? = null
        var nextChunk = 0
        var bytes = 0L
        var verifying = false
        var deadline: Job? = null
        var finalizer: Job? = null
        @Volatile var record: ReceivedFile? = null
        val terminal = AtomicBoolean(false)
    }
    private val scope = CoroutineScope(SupervisorJob(ownerScope.coroutineContext[Job]) + Dispatchers.Default)
    private val io = Dispatchers.IO.limitedParallelism(4)
    private val generation = AtomicLong()
    private val operationsLock = Any()
    private val operations = mutableMapOf<Key, Deferred<Boolean>>()
    private val outgoing = ConcurrentHashMap<Key, Outgoing>()
    private val incoming = ConcurrentHashMap<Key, Incoming>()
    private val incomingSlots = kotlinx.coroutines.sync.Semaphore(64)
    init { require(idleTimeoutMs > 0) }
    private val mutableProgress = MutableStateFlow<Map<String, FileProgress>>(emptyMap())
    private val events = MutableSharedFlow<FileProgress>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val active = mutableProgress.asStateFlow()
    val progress = events.asSharedFlow()

    private fun emit(value: FileProgress) {
        mutableProgress.update { if (value.completed || value.failed) it - value.fileId else it + (value.fileId to value) }
        events.tryEmit(value)
    }
    private fun envelope(type: String, payload: String, msgId: String = UUID.randomUUID().toString(), hash: String? = null): SyncEnvelope {
        val (id, name) = identity()
        return SyncEnvelope(type, id, msgId = msgId, name = name, payload = payload, hash = hash)
    }
    suspend fun send(file: File, peerId: String): Boolean {
        val key = Key(peerId, UUID.randomUUID().toString())
        val epoch = generation.get()
        val task = synchronized(operationsLock) {
            if (operations.size >= 32 || !scope.isActive) return false
            scope.async(start = CoroutineStart.LAZY) { sendFile(file, key, epoch) }.also { operations[key] = it }
        }
        task.start()
        return try { task.await() }
        catch (cancelled: CancellationException) { currentCoroutineContext().ensureActive(); false }
        finally { synchronized(operationsLock) { if (operations[key] === task) operations.remove(key) } }
    }
    private suspend fun sendFile(file: File, key: Key, epoch: Long): Boolean {
        var size = 0L
        var sent = 0L
        var success = false
        val waiter = CompletableDeferred<Boolean>()
        val state = Outgoing(key.peer, waiter)
        outgoing[key] = state
        try {
            val info = withContext(io) { file.isFile to file.length() }
            if (!info.first || info.second > FILE_MAX_BYTES) return false
            size = info.second
            val target = channel(key.peer) ?: return false
            state.connectionId = target.peer.connectionId
            if (generation.get() != epoch || !target.current()) return false
            emit(FileProgress(key.file, file.name, 0, size, true))
            val hash = hashFile(file, size)
            val chunks = if (size == 0L) 0 else ((size + FILE_CHUNK_BYTES - 1) / FILE_CHUNK_BYTES).toInt()
            val meta = JSONObject().put("fileId", key.file).put("name", file.name).put("size", size)
                .put("chunkSize", FILE_CHUNK_BYTES).put("chunks", chunks).put("sha256", hash)
            if (generation.get() != epoch || !target.current() || !target.write(envelope(SyncType.FILE_META, crypto.encryptText(meta.toString()), hash = hash))) return false
            coroutineScope {
                // One queued encrypted frame + producer and consumer: bounded to roughly 4MiB on the wire.
                val frames = Channel<Pair<SyncEnvelope, Int>>(1)
                val producer = launch(io) {
                    try {
                        file.inputStream().use { input ->
                            var remaining = size
                            repeat(chunks) { index ->
                                ensureActive()
                                if (waiter.isCompleted || generation.get() != epoch || !target.current()) return@use
                                val length = minOf(FILE_CHUNK_BYTES.toLong(), remaining).toInt()
                                val buffer = ByteArray(length + 4)
                                ByteBuffer.wrap(buffer).putInt(index)
                                var offset = 4
                                while (offset < buffer.size) {
                                    val count = input.read(buffer, offset, buffer.size - offset)
                                    if (count < 0) throw IOException("File changed while sending")
                                    offset += count
                                }
                                frames.send(envelope(SyncType.FILE_CHUNK, crypto.encryptBytes(buffer), msgId = key.file) to length)
                                remaining -= length
                            }
                            if (remaining != 0L || input.read() != -1) throw IOException("File size changed while sending")
                        }
                        frames.close()
                    } catch (error: Throwable) { frames.close(error); throw error }
                }
                try {
                    for ((frame, bytes) in frames) {
                        if (waiter.isCompleted || generation.get() != epoch || !target.current()) break
                        if (!target.write(frame)) throw IOException("File connection closed")
                        sent += bytes
                        emit(FileProgress(key.file, file.name, sent, size, true))
                    }
                } finally { producer.cancel(); frames.cancel() }
            }
            if (generation.get() != epoch || !target.current()) return false
            if (sent != size) return false
            val timeout = ((45 + size / (200 * 1024)).coerceIn(45, 600)) * 1000
            success = withTimeoutOrNull(timeout) { waiter.await() } == true
            return success
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { return false }
        finally {
            outgoing.remove(key, state)
            emit(FileProgress(key.file, file.name, sent, size, true, completed = success, failed = !success))
        }
    }

    suspend fun receive(peer: LanPeer, frame: SyncEnvelope) {
        if (frame.v != SYNC_VERSION) return
        when (frame.type) {
            SyncType.FILE_META -> metadata(peer, frame)
            SyncType.FILE_CHUNK -> chunk(peer, frame)
            SyncType.FILE_ACK -> {
                val data = frame.payload?.let(crypto::decryptText)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
                val key = Key(peer.peerId, data.optString("fileId"))
                val waiting = outgoing[key] ?: return
                if (waiting.connectionId == peer.connectionId) waiting.result.complete(data.opt("ok") == true)
            }
        }
    }
    private suspend fun metadata(peer: LanPeer, frame: SyncEnvelope) {
        val meta = frame.payload?.let(crypto::decryptText)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
        val id = meta.opt("fileId") as? String ?: return
        if (id.isEmpty() || id.length > 128) return
        val key = Key(peer.peerId, id)
        fun integer(key: String, fallback: Long): Long = when (val value = meta.opt(key)) {
            is Int -> value.toLong()
            is Long -> value
            else -> fallback
        }
        val size = integer("size", -1)
        if (size > FILE_MAX_BYTES) { ack(peer, id, false, "tooLarge"); return }
        val name = meta.opt("name") as? String ?: ""
        val chunkSize = integer("chunkSize", 0)
        val chunks = integer("chunks", -1)
        val hash = meta.optString("sha256").lowercase()
        if (size < 0 || name.isEmpty() || chunkSize !in 1..MAX_FRAME_BYTES.toLong() ||
            chunks != (if (size == 0L) 0L else (size + chunkSize - 1) / chunkSize) || !Regex("[a-f0-9]{64}").matches(hash)) {
            ack(peer, id, false, "ioError"); return
        }
        incoming.remove(key)?.let { discard(it) }
        if (!incomingSlots.tryAcquire()) { ack(peer, id, false, "ioError"); return }
        val epoch = generation.get()
        var state: Incoming? = null
        try {
            val part = storage.createPart()
            state = Incoming(peer, id, ReceivedFileStore.sanitizeFileName(name), size, chunkSize.toInt(), chunks.toInt(), hash, part,
                epoch, frame.name ?: peer.peerId.take(8))
            withContext(io) { state.writer = RandomAccessFile(part, "rw") }
            if (generation.get() != epoch) { discard(state); return }
            incoming[key] = state
            emit(FileProgress(id, state.name, 0, size, false))
            if (chunks == 0L) finish(state) else armDeadline(state)
        } catch (cancelled: CancellationException) { if (state != null) discard(state) else incomingSlots.release(); throw cancelled }
        catch (_: Exception) { if (state != null) discard(state) else incomingSlots.release(); ack(peer, id, false, "ioError") }
    }
    private suspend fun chunk(peer: LanPeer, frame: SyncEnvelope) {
        val state = incoming[Key(peer.peerId, frame.msgId)] ?: return
        if (state.peer.connectionId != peer.connectionId) return
        try {
            withContext(io) {
                state.mutex.withLock {
                    if (!live(state) || state.verifying) return@withLock
                    val bytes = frame.payload?.let(crypto::decryptBytes) ?: throw IOException("Invalid chunk ciphertext")
                    if (bytes.size < 4) throw IOException("Missing chunk index")
                    val index = ByteBuffer.wrap(bytes).int
                    val expectedBytes = minOf(state.chunkSize.toLong(), state.size - state.bytes).toInt()
                    if (index != state.nextChunk || index >= state.chunks || bytes.size - 4 != expectedBytes) throw IOException("Invalid chunk order or length")
                    (state.writer ?: throw IOException("File writer closed")).write(bytes, 4, expectedBytes)
                    state.nextChunk++; state.bytes += expectedBytes
                    emit(FileProgress(state.fileId, state.name, state.bytes, state.size, false))
                    if (state.nextChunk == state.chunks) finish(state) else armDeadline(state)
                }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { incoming.remove(Key(peer.peerId, state.fileId), state); discard(state); ack(peer, state.fileId, false, "ioError") }
    }
    private fun live(state: Incoming): Boolean = generation.get() == state.generation && incoming[Key(state.peer.peerId, state.fileId)] === state
    private fun armDeadline(state: Incoming) {
        state.deadline?.cancel()
        state.deadline = scope.launch {
            delay(idleTimeoutMs)
            if (incoming.remove(Key(state.peer.peerId, state.fileId), state)) discard(state)
        }
    }
    private fun finish(state: Incoming) {
        state.verifying = true
        state.deadline?.cancel(); state.deadline = null
        state.finalizer = scope.launch {
            var error: String? = null
            try {
                state.mutex.withLock {
                    withContext(io) { state.writer?.fd?.sync(); state.writer?.close(); state.writer = null }
                    if (!live(state)) return@withLock
                    if (state.bytes != state.size || hashFile(state.part, state.size) != state.hash) { error = "hashMismatch"; return@withLock }
                    // Publishing is a short, non-cancellable rename+DB transaction, after the last cancellation check.
                    if (live(state)) withContext(NonCancellable) {
                        state.record = storage.publish(state.part, state.name, state.size, state.sender)
                    }
                }
                if (live(state)) ack(state.peer, state.fileId, state.record != null, error ?: if (state.record == null) "ioError" else null)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (live(state)) runCatching { ack(state.peer, state.fileId, false, "ioError") } }
            finally {
                incoming.remove(Key(state.peer.peerId, state.fileId), state)
                withContext(NonCancellable + io) {
                    if (state.record == null) runCatching { state.part.delete() }
                    terminal(state)
                }
            }
        }
    }
    private fun terminal(state: Incoming) {
        if (!state.terminal.compareAndSet(false, true)) return
        incomingSlots.release()
        val record = state.record
        emit(FileProgress(state.fileId, state.name, if (record != null) state.size else 0, state.size, false,
            completed = record != null, failed = record == null))
        if (record != null) runCatching { received(record) }
    }
    private suspend fun discard(state: Incoming) {
        val me = currentCoroutineContext()[Job]
        withContext(NonCancellable + io) {
            if (state.deadline !== me) state.deadline?.cancel()
            if (state.finalizer !== me) state.finalizer?.cancel()
            state.mutex.withLock {
                runCatching { state.writer?.close() }; state.writer = null
                if (state.record == null) runCatching { state.part.delete() }
            }
            terminal(state)
        }
    }
    private suspend fun ack(peer: LanPeer, id: String, ok: Boolean, error: String? = null) {
        val json = JSONObject().put("fileId", id).put("ok", ok)
        error?.let { json.put("error", it) }
        reply(peer, envelope(SyncType.FILE_ACK, crypto.encryptText(json.toString())))
    }
    private suspend fun hashFile(file: File, expectedLength: Long): String = withContext(io) {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                ensureActive()
                val count = input.read(buffer)
                if (count == -1) break
                total += count
                if (total > expectedLength) throw IOException("File grew during checksum")
                digest.update(buffer, 0, count)
            }
            if (total != expectedLength) throw IOException("File size changed during checksum")
        }
        digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    suspend fun disconnected(peer: LanPeer) {
        val states = incoming.values.filter { it.peer.peerId == peer.peerId && it.peer.connectionId == peer.connectionId }
        states.forEach { incoming.remove(Key(it.peer.peerId, it.fileId), it); discard(it) }
        outgoing.entries.filter { it.key.peer == peer.peerId && it.value.connectionId == peer.connectionId }.forEach { entry ->
            entry.value.result.complete(false)
            synchronized(operationsLock) { operations[entry.key]?.cancel() }
        }
    }
    suspend fun reset() {
        generation.incrementAndGet()
        val jobs = synchronized(operationsLock) { operations.values.toList().also { operations.clear() } }
        outgoing.values.forEach { it.result.complete(false) }
        jobs.forEach { it.cancel() }
        val states = incoming.values.toList(); incoming.clear()
        states.forEach { discard(it) }
        withContext(NonCancellable) { jobs.joinAll(); states.mapNotNull { it.finalizer }.joinAll() }
        outgoing.clear()
        mutableProgress.value = emptyMap()
    }
}
