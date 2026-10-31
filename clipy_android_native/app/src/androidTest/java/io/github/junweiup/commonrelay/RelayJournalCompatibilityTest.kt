package io.github.junweiup.commonrelay

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

@RunWith(AndroidJUnit4::class)
class RelayJournalCompatibilityTest {
    @Test fun readsDartPendingCompletedAndIncomingReceiptsWithoutResealing() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val fixture = instrumentation.context.assets.open("relay/dart-journal-fixture.json").bufferedReader().use { JSONObject(it.readText()) }
        val root = File(instrumentation.targetContext.cacheDir, "journal-fixture-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val files = fixture.getJSONArray("files")
            repeat(files.length()) {
                val entry = files.getJSONObject(it)
                File(root, entry.getString("name")).writeText(entry.getJSONObject("record").toString())
            }
            val now = AtomicLong(fixture.getLong("clock"))
            val journal = RelayJournal(root.toPath()) { now.get() }
            val scope = fixture.getString("scope")
            val bytes = fixture.getJSONArray("data").let { array -> ByteArray(array.length()) { array.getInt(it).toByte() } }
            assertTrue("Native journal must find Dart's incoming receipt path", journal.contains(scope, "peer", "incoming"))
            val pending = journal.prepare(scope, "pending", "peer", bytes, 60) { throw AssertionError("Existing ciphertext was resealed") }
            assertEquals("opaque-test-ciphertext", pending.getString("body"))
            assertEquals("pending", pending.getString("status"))
            val completed = journal.prepare(scope, "complete", "peer", bytes, 60) { throw AssertionError("Completed receipt was resent") }
            assertEquals("received", completed.getString("status"))
            assertFalse(completed.has("body"))
            assertThrows(Exception::class.java) { journal.prepare(scope, "pending", "other-peer", bytes, 60) { "wrong" } }
            now.addAndGet(61)
            journal.cleanup()
            assertThrows(Exception::class.java) { journal.prepare(scope, "pending", "peer", bytes, 60) { "wrong" } }
            now.addAndGet(7 * 86400L)
            journal.cleanup()
            assertEquals(0, root.listFiles()?.count { it.extension == "json" })
        } finally { root.deleteRecursively() }
    }
}
