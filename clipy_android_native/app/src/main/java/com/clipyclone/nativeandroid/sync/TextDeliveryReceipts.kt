package com.clipyclone.nativeandroid.sync

import kotlinx.coroutines.*

/** Only a matching peer/hash ACK confirms delivery. Queue persistence precedes dispatch. */
class TextDeliveryReceipts(private val scope: CoroutineScope, private val timeoutMs: Long = 12000) {
    private data class Key(val peer: String, val hash: String)
    private data class Receipt(val result: CompletableDeferred<Boolean>, val timer: Job)
    private val lock = Any()
    private val pending = mutableMapOf<Key, Receipt>()
    init {
        require(timeoutMs > 0)
        scope.coroutineContext[Job]?.invokeOnCompletion { cancelAll() }
    }
    suspend fun send(peerId: String, hash: String, dispatch: suspend () -> Unit): Boolean {
        val key = Key(peerId, hash)
        var created = false
        val receipt = synchronized(lock) {
            pending[key] ?: run {
                if (!scope.isActive || pending.size >= 32) return false
                val result = CompletableDeferred<Boolean>()
                val timer = scope.launch(start = CoroutineStart.LAZY) { delay(timeoutMs); finish(key, result, false) }
                Receipt(result, timer).also { pending[key] = it; created = true }
            }
        }
        if (created) {
            receipt.timer.start()
            scope.launch {
                try { dispatch() }
                catch (cancelled: CancellationException) { finish(key, receipt.result, false); throw cancelled }
                catch (_: Exception) { finish(key, receipt.result, false) }
            }
        }
        return receipt.result.await()
    }
    private fun finish(key: Key, expected: CompletableDeferred<Boolean>, success: Boolean) {
        val receipt = synchronized(lock) {
            val current = pending[key]
            if (current?.result !== expected) null else pending.remove(key)
        } ?: return
        receipt.timer.cancel()
        receipt.result.complete(success)
    }
    fun acknowledge(peerId: String, hash: String) {
        val key = Key(peerId, hash)
        val receipt = synchronized(lock) { pending[key] } ?: return
        finish(key, receipt.result, true)
    }
    fun cancelAll() {
        val all = synchronized(lock) { pending.values.toList().also { pending.clear() } }
        all.forEach { it.timer.cancel(); it.result.complete(false) }
    }
    val size: Int get() = synchronized(lock) { pending.size }
}
