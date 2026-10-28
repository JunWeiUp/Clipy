package com.clipyclone.nativeandroid.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class NativePeerDiagnostics(val peerId: String, val name: String? = null, val host: String? = null,
    val sessionUpAt: Long? = null, val sessionDownAt: Long? = null, val lastSentAt: Long? = null,
    val lastAckAt: Long? = null, val lastReceivedAt: Long? = null, val lastError: String? = null, val lastErrorAt: Long? = null)

/** Process-local metadata, bounded to the 512 most recently updated peer records. */
class NativeDiagnostics {
    private val state = MutableStateFlow<Map<String, NativePeerDiagnostics>>(emptyMap())
    val records = state.asStateFlow()
    private fun update(peerId: String, change: (NativePeerDiagnostics) -> NativePeerDiagnostics) {
        if (peerId.isEmpty()) return
        state.update { old ->
            val next = LinkedHashMap(old)
            val value = change(next.remove(peerId) ?: NativePeerDiagnostics(peerId))
            next[peerId] = value
            while (next.size > 512) next.remove(next.keys.first())
            next
        }
    }
    fun reset() { state.value = emptyMap() }
    fun noteSessionUp(peerId: String, name: String, host: String) = update(peerId) {
        it.copy(name = name, host = host, sessionUpAt = System.currentTimeMillis(), lastError = null, lastErrorAt = null)
    }
    fun noteSessionDown(peerId: String) = update(peerId) { it.copy(sessionDownAt = System.currentTimeMillis()) }
    fun noteSent(peerId: String) = update(peerId) { it.copy(lastSentAt = System.currentTimeMillis()) }
    fun noteAck(peerId: String) = update(peerId) { it.copy(lastAckAt = System.currentTimeMillis()) }
    fun noteReceived(peerId: String) = update(peerId) { it.copy(lastReceivedAt = System.currentTimeMillis()) }
    fun noteError(peerId: String, message: String, name: String? = null, host: String? = null) = update(peerId) {
        it.copy(name = name ?: it.name, host = host ?: it.host, lastError = message, lastErrorAt = System.currentTimeMillis())
    }
}
