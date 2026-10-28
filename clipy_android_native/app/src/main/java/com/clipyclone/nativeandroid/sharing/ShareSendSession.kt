package com.clipyclone.nativeandroid.sharing

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex

data class ShareSendState(val peerId: String? = null, val sent: Set<Int> = emptySet(), val sending: Boolean = false, val current: Int? = null)
data class ShareSendResult(val complete: Boolean, val failed: Boolean, val textUnconfirmed: Boolean)

/** Same-peer retries skip confirmed successes; selecting a new peer starts a new delivery set. */
class ShareSendSession(private val share: IncomingShare) {
    private val mutable = MutableStateFlow(ShareSendState()); val state = mutable.asStateFlow()
    private val operation = Mutex()
    fun select(peerId: String) {
        mutable.update { if (it.sending || it.peerId == peerId) it else it.copy(peerId = peerId, sent = emptySet()) }
    }
    suspend fun send(peerId: String, sendText: suspend (String, String) -> Boolean,
                     sendFile: suspend (SharedItem, String) -> Boolean): ShareSendResult? {
        if (!operation.tryLock()) return null
        var failed = false; var unconfirmed = false
        try {
            mutable.update { it.copy(peerId = peerId, sent = if (it.peerId == peerId) it.sent else emptySet(), sending = true) }
            if (share.text.isNotEmpty() && -1 !in mutable.value.sent) {
                if (!sendText(share.text, peerId)) { unconfirmed = true; failed = true }
                else mutable.update { it.copy(sent = it.sent + -1) }
            }
            if (!failed) for ((index, file) in share.files.withIndex()) {
                if (index in mutable.value.sent) continue
                mutable.update { it.copy(current = index) }
                if (!sendFile(file, peerId)) { failed = true; break }
                mutable.update { it.copy(sent = it.sent + index) }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failed = true }
        finally { mutable.update { it.copy(sending = false, current = null) }; operation.unlock() }
        return ShareSendResult(!failed && mutable.value.sent.size == share.itemCount, failed, unconfirmed)
    }
}
