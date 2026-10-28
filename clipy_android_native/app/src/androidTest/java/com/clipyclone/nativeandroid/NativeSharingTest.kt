package com.clipyclone.nativeandroid

import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.clipy_android.SharedFileInbox
import com.clipyclone.nativeandroid.sharing.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class NativeSharingTest {
    @Test fun textShareRemainsUntilExplicitCompletionAndOversizeIsReported() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val before = SharedFileInbox.pending.value.map { it.id }.toSet()
        instrumentation.runOnMainSync { SharedFileInbox.enqueue(context, Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Share fixture 世界")) }
        val share = withTimeout(3000) { SharedFileInbox.pending.first { rows -> rows.any { it.id !in before } }.first { it.id !in before } }
        assertEquals("Share fixture 世界", share.text); assertEquals(1, share.itemCount); assertTrue(share.files.isEmpty())
        instrumentation.runOnMainSync { SharedFileInbox.complete(context, share.id) }
        assertTrue(SharedFileInbox.pending.value.none { it.id == share.id })
        val baseline = SharedFileInbox.pending.value.map { it.id }.toSet()
        instrumentation.runOnMainSync { SharedFileInbox.enqueue(context, Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "x".repeat(1024 * 1024 + 1))) }
        val error = withTimeout(3000) { SharedFileInbox.pending.first { rows -> rows.any { it.id !in baseline } }.first { it.id !in baseline } }
        assertEquals("tooLarge", error.error); assertEquals(0, error.itemCount)
        instrumentation.runOnMainSync { SharedFileInbox.complete(context, error.id) }
    }
    @Test fun rejectsPrivateFileUrisAndOverThirtyTwoItems() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        suspend fun imported(intent: Intent): IncomingShare {
            val before = SharedFileInbox.pending.value.map { it.id }.toSet()
            instrumentation.runOnMainSync { SharedFileInbox.enqueue(context, intent) }
            return withTimeout(3000) { SharedFileInbox.pending.first { rows -> rows.any { it.id !in before } }.first { it.id !in before } }
        }
        val privateUri = imported(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, Uri.fromFile(File(context.filesDir, "private-fixture"))))
        assertEquals("unreadable", privateUri.error); assertTrue(privateUri.files.isEmpty())
        instrumentation.runOnMainSync { SharedFileInbox.complete(context, privateUri.id) }
        val many = imported(Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM,
            ArrayList((0..32).map { Uri.parse("content://fixture/items/$it") })))
        assertEquals("tooMany", many.error)
        instrumentation.runOnMainSync { SharedFileInbox.complete(context, many.id) }
    }
    @Test fun contentStreamsAreByteExactDeduplicatedAndRemovedAfterReview() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val one = Uri.parse("content://${ShareFixtureProvider.AUTHORITY}/one")
        val two = Uri.parse("content://${ShareFixtureProvider.AUTHORITY}/two")
        val before = SharedFileInbox.pending.value.map { it.id }.toSet()
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(one, two, one))
        intent.clipData = android.content.ClipData.newRawUri("fixture", one)
        instrumentation.runOnMainSync { SharedFileInbox.enqueue(context, intent) }
        val share = withTimeout(5000) { SharedFileInbox.pending.first { rows -> rows.any { it.id !in before } }.first { it.id !in before } }
        try {
            assertEquals("", share.error); assertEquals(2, share.files.size)
            assertArrayEquals(ShareFixtureProvider.bytes("one"), File(share.files[0].path).readBytes())
            assertArrayEquals(ShareFixtureProvider.bytes("two"), File(share.files[1].path).readBytes())
        } finally { instrumentation.runOnMainSync { SharedFileInbox.complete(context, share.id) } }
        withTimeout(3000) { while (share.files.any { File(it.path).exists() }) delay(20) }
    }
    @Test fun singlePickerUsesSafeNamesAndCancellationDoesNotLeaveStagedFiles() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val staged = SharedFileInbox.stageSingle(context, Uri.parse("content://${ShareFixtureProvider.AUTHORITY}/name"))
        assertFalse(staged.file.name.contains('/'))
        assertArrayEquals(ShareFixtureProvider.bytes("name"), staged.file.readBytes())
        staged.close(); assertFalse(staged.file.exists())
        val root = File(context.cacheDir, "incoming-shares")
        val before = root.listFiles()?.map { it.name }?.toSet().orEmpty()
        val pending = async { SharedFileInbox.stageSingle(context, Uri.parse("content://${ShareFixtureProvider.AUTHORITY}/blocked")) }
        delay(100); pending.cancelAndJoin()
        withTimeout(3000) { while (root.listFiles()?.any { it.name !in before } == true) delay(20) }
    }

    @Test fun retryOnlyFailedItemsAndChangingDeviceResetsTheDeliverySet() = runBlocking {
        val share = IncomingShare("fixture", listOf(SharedItem("first", "first", 1), SharedItem("second", "second", 2)), "text")
        val session = ShareSendSession(share); val files = mutableListOf<String>(); var texts = 0; var rejectSecond = true
        suspend fun text(value: String, peer: String): Boolean { texts++; return true }
        suspend fun file(item: SharedItem, peer: String): Boolean { files += "${peer}:${item.name}"; return item.name != "second" || !rejectSecond }
        val first = session.send("A", ::text, ::file)!!
        assertTrue(first.failed); assertEquals(setOf(-1, 0), session.state.value.sent)
        rejectSecond = false
        assertTrue(session.send("A", ::text, ::file)!!.complete)
        assertEquals(1, texts); assertEquals(listOf("A:first", "A:second", "A:second"), files)
        session.select("B"); assertTrue(session.state.value.sent.isEmpty())
        assertTrue(session.send("B", ::text, ::file)!!.complete)
        assertEquals(2, texts); assertEquals(listOf("B:first", "B:second"), files.takeLast(2))
    }
}
