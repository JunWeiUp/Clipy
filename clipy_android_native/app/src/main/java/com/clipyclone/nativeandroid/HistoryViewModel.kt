package com.clipyclone.nativeandroid

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.clipyclone.nativeandroid.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

data class HistoryState(
    val query: String = "", val filter: HistoryFilter = HistoryFilter.ALL,
    val entries: List<HistoryEntry> = emptyList(), val loading: Boolean = true,
    val writing: Boolean = false, val error: Boolean = false, val canLoadMore: Boolean = false,
)

class HistoryViewModel internal constructor(application: Application, private val databaseFile: File?) : AndroidViewModel(application) {
    constructor(application: Application) : this(application, null)
    private val mutex = Mutex()
    private val mutable = MutableStateFlow(HistoryState())
    val state = mutable.asStateFlow()
    private var queryJob: Job? = null
    private var revision = 0L

    init {
        refresh()
        (application as? com.clipyclone.clipy_android.ClipyApplication)?.let { app ->
            viewModelScope.launch { app.historyRevision.drop(1).collect { refresh() } }
        }
    }

    fun search(query: String, filter: HistoryFilter = mutable.value.filter) {
        mutable.update { it.copy(query = query, filter = filter, entries = emptyList()) }
        refresh(debounce = true)
    }

    fun more() {
        val request = mutable.value
        if (request.loading || !request.canLoadMore) return
        val token = ++revision
        queryJob?.cancel()
        mutable.update { it.copy(loading = true, error = false) }
        queryJob = viewModelScope.launch {
            try {
                // Match the original feed: append one page, without re-reading
                // or replacing the rows the user has already loaded.
                val rows = withRepository { it.page(request.query, request.filter, 50, request.entries.size) }
                if (token == revision) mutable.update { it.copy(entries = request.entries + rows,
                    loading = false, canLoadMore = rows.size == 50) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (token == revision) mutable.update { it.copy(loading = false, error = true) } }
        }
    }

    fun refresh(debounce: Boolean = false) {
        val token = ++revision
        queryJob?.cancel()
        val request = mutable.value
        val requestedLimit = maxOf(50, request.entries.size)
        mutable.update { it.copy(loading = true, error = false) }
        queryJob = viewModelScope.launch {
            try {
                if (debounce) delay(250)
                val rows = withRepository { it.page(request.query, request.filter, requestedLimit) }
                if (token == revision) mutable.update { it.copy(entries = rows,
                    loading = false, canLoadMore = rows.size == requestedLimit) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (token == revision) mutable.update { it.copy(loading = false, error = true) } }
        }
    }

    fun save(text: String, onSuccess: () -> Unit = {}) = mutate(onSuccess) { it.saveText(text) }
    fun clear(onSuccess: () -> Unit, onFailure: () -> Unit) = mutate(onSuccess, onFailure) { it.clear() }
    fun delete(id: Long) = mutate { it.delete(id) }
    private fun mutate(onSuccess: () -> Unit = {}, onFailure: () -> Unit = {}, action: (HistoryRepository) -> Unit) {
        if (mutable.value.writing) return
        mutable.update { it.copy(writing = true) }
        viewModelScope.launch {
            try {
                withRepository(action)
                onSuccess()
                refresh()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { mutable.update { it.copy(error = true) }; onFailure() }
            finally { mutable.update { it.copy(writing = false) } }
        }
    }

    // Each bounded IO operation owns and closes its connection, including on cancellation.
    // No application-wide connection, observer, timer, or background clipboard polling.
    private suspend fun <T> withRepository(block: (HistoryRepository) -> T): T =
        withContext(Dispatchers.IO) {
            mutex.withLock {
                (databaseFile?.let { ClipyDatabase(getApplication(), it) } ?: ClipyDatabase(getApplication()))
                    .use { block(HistoryRepository(it)) }
            }
        }
}
