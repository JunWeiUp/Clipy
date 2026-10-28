package com.clipyclone.nativeandroid

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.data.ContentHash
import com.clipyclone.nativeandroid.sync.HistoryWrite
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeClipboardTest {
    @Test fun baselineResumeExplicitCopyAndRemoteLoopbackMatchExistingBehavior() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(Intent(context, VisualFixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        lateinit var system: ClipboardManager
        instrumentation.runOnMainSync { system = context.getSystemService(ClipboardManager::class.java) }
        withTimeout(3000) {
            var focused = false
            while (!focused) { instrumentation.runOnMainSync { focused = activity.hasWindowFocus() }; if (!focused) delay(20) }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val writes = Channel<Pair<String, Boolean>>(Channel.UNLIMITED)
        val clipboard = NativeClipboard(context, scope) { text, _, broadcast -> writes.send(text to broadcast) }
        fun main(action: () -> Unit) { instrumentation.runOnMainSync(action); instrumentation.waitForIdleSync() }
        try {
            main { system.setPrimaryClip(ClipData.newPlainText("fixture", "baseline")); clipboard.attach() }
            assertTrue(writes.tryReceive().isFailure)
            main { system.setPrimaryClip(ClipData.newPlainText("fixture", "new foreground text")) }
            assertEquals("new foreground text" to true, withTimeout(2000) { writes.receive() })
            main { assertTrue(clipboard.copy("explicit history copy")) }
            assertTrue(writes.tryReceive().isFailure)
            main { clipboard.acceptRemote(HistoryWrite(true, "remote fixture", listOf(ContentHash.text("remote fixture")))) }
            assertTrue(writes.tryReceive().isFailure)
            main { clipboard.detach(); system.setPrimaryClip(ClipData.newPlainText("fixture", "while background")) }
            assertTrue(writes.tryReceive().isFailure)
            main { clipboard.attach() }
            assertEquals("while background" to true, withTimeout(2000) { writes.receive() })
            val indented = "  pasted code\n\t"
            main { clipboard.detach(); system.setPrimaryClip(ClipData.newPlainText("fixture", indented)) }
            main { clipboard.attach() }
            assertEquals(indented to true, withTimeout(2000) { writes.receive() })
            main { assertTrue(clipboard.copy(indented)) }
            assertTrue(writes.tryReceive().isFailure)
            main {
                clipboard.detach()
                system.setPrimaryClip(ClipData.newRawUri("fixture", android.net.Uri.parse("https://example.invalid/not-text")))
            }
            main { clipboard.attach() }
            assertTrue(writes.tryReceive().isFailure)
            main { system.setPrimaryClip(ClipData.newPlainText("fixture", "remote fixture")) }
            assertEquals("remote fixture" to false, withTimeout(2000) { writes.receive() })
        } finally { main { clipboard.detach(); activity.finish() }; scope.cancel(); writes.close() }
    }

    @Test fun failedPersistenceCanRetryTheSameClipboardWithoutRollingBackNewerText() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(Intent(context, VisualFixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        lateinit var system: ClipboardManager
        instrumentation.runOnMainSync { system = context.getSystemService(ClipboardManager::class.java) }
        withTimeout(3000) {
            var focused = false
            while (!focused) { instrumentation.runOnMainSync { focused = activity.hasWindowFocus() }; if (!focused) delay(20) }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val attempts = Channel<String>(Channel.UNLIMITED)
        var fail = true
        val clipboard = NativeClipboard(context, scope) { text, _, _ ->
            attempts.send(text)
            if (fail) { fail = false; throw java.io.IOException("fixture") }
        }
        fun main(action: () -> Unit) { instrumentation.runOnMainSync(action); instrumentation.waitForIdleSync() }
        try {
            main { system.setPrimaryClip(ClipData.newPlainText("fixture", "baseline")); clipboard.attach() }
            main { system.setPrimaryClip(ClipData.newPlainText("fixture", "retry fixture")) }
            assertEquals("retry fixture", withTimeout(2000) { attempts.receive() })
            main { clipboard.onFocus() }
            assertEquals("retry fixture", withTimeout(2000) { attempts.receive() })
        } finally { main { clipboard.detach(); activity.finish() }; scope.cancel(); attempts.close() }
    }
}
