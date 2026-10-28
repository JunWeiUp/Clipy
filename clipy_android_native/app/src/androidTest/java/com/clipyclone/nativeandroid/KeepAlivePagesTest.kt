package com.clipyclone.nativeandroid

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.ui.KeepAliveTabs
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicIntegerArray

@RunWith(AndroidJUnit4::class)
class KeepAlivePagesTest {
    @Test fun hiddenTabsRetainDraftsAndJobsButAreNotLaidOutOrFocusable() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, VisualFixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as VisualFixtureActivity
        val selected = mutableIntStateOf(0); val height = mutableIntStateOf(400)
        val identities = ConcurrentHashMap<Int, Any>(); val drafts = ConcurrentHashMap<Int, MutableState<String>>()
        val requesters = ConcurrentHashMap<Int, FocusRequester>()
        val measured = AtomicIntegerArray(4); val disposed = AtomicIntegerArray(4)
        val focused = AtomicInteger(-1)
        val release = CompletableDeferred<Unit>(); val completed = CompletableDeferred<Unit>()
        suspend fun eventually(predicate: () -> Boolean) = withTimeout(5000) { while (!predicate()) delay(20) }
        fun accessibleText(): List<String> {
            val result = mutableListOf<String>()
            fun visit(node: android.view.accessibility.AccessibilityNodeInfo?) {
                if (node == null) return
                node.text?.let { result += it.toString() }
                repeat(node.childCount) { visit(node.getChild(it)) }
            }
            visit(instrumentation.uiAutomation.rootInActiveWindow)
            return result
        }
        try {
            instrumentation.runOnMainSync {
                activity.setContent {
                    MaterialTheme {
                        Box(Modifier.fillMaxSize()) {
                            KeepAliveTabs(selected.intValue, Modifier.fillMaxWidth().height(height.intValue.dp)) { page ->
                                val identity = remember { Any() }; val draft = remember { mutableStateOf("draft-$page") }
                                val requester = remember { FocusRequester() }
                                SideEffect { identities[page] = identity; drafts[page] = draft; requesters[page] = requester }
                                DisposableEffect(Unit) { onDispose { disposed.incrementAndGet(page) } }
                                LaunchedEffect(Unit) { if (page == 0) { release.await(); completed.complete(Unit) } }
                                Layout(content = {
                                    Column {
                                        Text("Page-$page")
                                        BasicTextField(draft.value, { draft.value = it }, Modifier.focusRequester(requester).onFocusChanged { if (it.isFocused) focused.set(page) else focused.compareAndSet(page, -1) }, readOnly = true)
                                    }
                                }) { children, constraints ->
                                    measured.incrementAndGet(page)
                                    val child = children.single().measure(constraints)
                                    layout(constraints.maxWidth, constraints.maxHeight) { child.place(0, 0) }
                                }
                            }
                        }
                    }
                }
            }
            eventually { measured.get(0) > 0 && identities[0] != null }
            val original = identities[0]
            instrumentation.runOnMainSync { drafts[0]!!.value = "retained draft"; requesters[0]!!.requestFocus() }
            eventually { focused.get() == 0 }
            instrumentation.runOnMainSync { selected.intValue = 1 }
            eventually { measured.get(1) > 0 && focused.get() != 0 }
            val hiddenMeasures = measured.get(0)
            eventually { "Page-1" in accessibleText() }
            assertFalse("Page-0" in accessibleText())
            release.complete(Unit); withTimeout(2000) { completed.await() }
            instrumentation.runOnMainSync { height.intValue = 270; requesters[0]!!.requestFocus() }
            eventually { measured.get(1) > 1 }
            assertEquals(hiddenMeasures, measured.get(0))
            assertEquals(0, disposed.get(0)); assertNotEquals(0, focused.get())
            instrumentation.runOnMainSync { selected.intValue = 0 }
            eventually { measured.get(0) > hiddenMeasures }
            assertSame(original, identities[0]); assertEquals("retained draft", drafts[0]!!.value)
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
