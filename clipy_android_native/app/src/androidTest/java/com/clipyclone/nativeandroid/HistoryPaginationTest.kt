package com.clipyclone.nativeandroid

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.data.ClipyDatabase
import com.clipyclone.nativeandroid.data.HistoryRepository
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class HistoryPaginationTest {
    @Test fun appendKeepsLoadedRowsUntilRefreshAndSearchResetsTheLoadedRange() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val application = instrumentation.targetContext.applicationContext as Application
        val root = File(application.cacheDir, "pagination-${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(root, "history.db")
        val store = ViewModelStore()
        lateinit var model: HistoryViewModel
        try {
            ClipyDatabase(application, file).use { helper ->
                val repository = HistoryRepository(helper)
                repeat(120) { repository.saveText("pagination fixture $it", now = it.toLong()) }
            }
            instrumentation.runOnMainSync {
                model = HistoryViewModel(application, file)
                store.put("history", model)
            }
            suspend fun ready() = withTimeout(5000) { model.state.first { !it.loading } }
            val first = ready()
            assertEquals(50, first.entries.size)
            assertTrue(first.canLoadMore)
            val original = first.entries.first()
            // A separate repository writer changes an already loaded row. A load-more
            // operation must retain the visible page; explicit refresh picks up the change.
            ClipyDatabase(application, file).use { it.writableDatabase.execSQL(
                "UPDATE clipboard_history SET item_value=? WHERE id=?", arrayOf("updated fixture", original.id)) }
            instrumentation.runOnMainSync { model.more() }
            val second = ready()
            assertEquals(100, second.entries.size)
            assertEquals(first.entries, second.entries.take(50))
            assertEquals(100, second.entries.map { it.id }.distinct().size)
            instrumentation.runOnMainSync { model.refresh() }
            val refreshed = ready()
            assertEquals(100, refreshed.entries.size)
            assertEquals("updated fixture", refreshed.entries.first().value)
            instrumentation.runOnMainSync { model.more() }
            val last = ready()
            assertEquals(120, last.entries.size)
            assertFalse(last.canLoadMore)
            instrumentation.runOnMainSync { model.search("no such fixture") }
            assertTrue(ready().entries.isEmpty())
            instrumentation.runOnMainSync { model.search("") }
            assertEquals(50, ready().entries.size)
        } finally {
            instrumentation.runOnMainSync { store.clear() }
            root.deleteRecursively()
        }
    }
}
