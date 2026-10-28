package com.clipyclone.nativeandroid

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.ui.SelectableDocumentView
import com.clipyclone.nativeandroid.ui.SelectableLongText
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class SelectableLongTextTest {
    @Test fun oneMiBMultilineDocumentStaysBoundedAndSelectAllCopyKeepsEveryCharacter() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, VisualFixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as VisualFixtureActivity
        val text = "x\n".repeat(512 * 1024)
        val copied = AtomicInteger(); val failed = AtomicInteger()
        try {
            instrumentation.runOnMainSync {
                activity.setContent {
                    MaterialTheme {
                        Box(Modifier.fillMaxSize()) {
                            SelectableLongText(text, Modifier.fillMaxWidth().height(260.dp),
                                onCopyFailed = { failed.incrementAndGet() }, copy = { assertEquals(text, it); copied.set(it.length); false })
                        }
                    }
                }
            }
            var view: SelectableDocumentView? = null
            withTimeout(15000) {
                while ((view?.documentHeight ?: 0) == 0) {
                    instrumentation.runOnMainSync { view = activity.window.decorView.findViewWithTag("clipy-long-text") }
                    delay(20)
                }
            }
            instrumentation.runOnMainSync {
                val document = requireNotNull(view)
                assertEquals(text.length, document.text.length)
                assertTrue(document.height > 0 && document.height <= (260 * activity.resources.displayMetrics.density).toInt() + 1)
                assertTrue(document.documentHeight > 262142)
                document.scrollTo(0, (document.documentHeight + document.paddingTop + document.paddingBottom - document.height).coerceAtLeast(0))
                assertTrue(document.scrollY > 262142)
                document.requestFocus()
                assertTrue(document.onTextContextMenuItem(android.R.id.selectAll))
                assertEquals(0, document.selectionStart); assertEquals(text.length, document.selectionEnd)
                assertTrue(document.onTextContextMenuItem(android.R.id.copy))
                assertEquals(text.length, copied.get()); assertEquals(1, failed.get())
                assertEquals(text.length, document.text.length)
                assertTrue(document.cachedBlockCount <= 3)
                val start = 4090; val end = 8210
                document.copyText = { assertEquals(text.substring(start, end), it); true }
                document.selectDocumentRange(start, end)
                assertTrue(document.onTextContextMenuItem(android.R.id.copy))
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
