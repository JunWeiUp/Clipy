package com.clipyclone.nativeandroid

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clipyclone.nativeandroid.data.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class HistoryStorageTest {
    @Test fun corruptDatabaseIsNeverDeletedOrReplacedWithAnEmptyLibrary() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "corruption-${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(root, "history.db")
        val original = ByteArray(4096) { ((it * 37 + 19) % 256).toByte() }
        file.writeBytes(original)
        try {
            repeat(2) {
                val helper = ClipyDatabase(context, file)
                try {
                    assertThrows(android.database.sqlite.SQLiteException::class.java) { helper.writableDatabase }
                } finally { helper.close() }
                assertTrue("Original corrupt database must remain available for recovery", file.isFile)
                assertArrayEquals(original, file.readBytes())
            }
        } finally { root.deleteRecursively() }
    }

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun <T> fixture(block: (File) -> T): T {
        val file = File(context.cacheDir, "fixture-${UUID.randomUUID()}.db")
        return try { block(file) } finally { SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun duplicateMovesToTopAndSearchIsLiteralBeforeLimit() = fixture { file ->
        ClipyDatabase(context, file).use { helper ->
            val repo = HistoryRepository(helper)
            repo.saveText("literal 100%_!", 1)
            repeat(70) { repo.saveText("new item $it", 100L + it) }
            assertEquals("literal 100%_!", repo.page("%_!", limit = 1).single().value)
            repo.saveText("https://example.com", 200)
            assertEquals(1, repo.page(filter = HistoryFilter.LINKS).size)
            repo.saveText("new item 0", 300)
            assertEquals("new item 0", repo.page(limit = 1).single().value)
            assertEquals(72, repo.page(limit = 100).size)
            val id = repo.page(limit = 1).single().id
            repo.delete(id)
            assertEquals(71, repo.page(limit = 100).size)
        }
    }

    @Test fun failedReplacementPreservesOriginalRow() = fixture { file ->
        ClipyDatabase(context, file).use { helper ->
            val repo = HistoryRepository(helper)
            repo.saveText("keep me", 1)
            helper.writableDatabase.execSQL("CREATE TRIGGER fail_insert BEFORE INSERT ON clipboard_history BEGIN SELECT RAISE(ABORT, 'test'); END")
            try { repo.saveText("keep me", 2); fail("Expected insert failure") } catch (_: android.database.SQLException) { }
            assertEquals(1L, repo.page().single().createdAt)
        }
    }

    @Test fun everyShippedSchemaUpgradesWithoutLosingData() {
        for (version in 1..6) fixture { file ->
            SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
                db.execSQL("CREATE TABLE clipboard_history (id INTEGER PRIMARY KEY AUTOINCREMENT, content_hash TEXT UNIQUE, item_type TEXT NOT NULL, item_value TEXT NOT NULL, source_app TEXT, created_at INTEGER NOT NULL)")
                val extras = (if (version >= 4) ", is_archived INTEGER NOT NULL DEFAULT 0" else "") +
                    (if (version >= 5) ", sync_state INTEGER NOT NULL DEFAULT 0" else "")
                db.execSQL("CREATE TABLE notifications (id TEXT PRIMARY KEY, notification_key TEXT, package_name TEXT NOT NULL, app_name TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT, body TEXT NOT NULL, post_time INTEGER NOT NULL, group_key TEXT, is_clearable INTEGER NOT NULL DEFAULT 1, extras_json TEXT NOT NULL DEFAULT '{}', synced_at INTEGER $extras)")
                db.execSQL("INSERT INTO clipboard_history(content_hash,item_type,item_value,created_at) VALUES('fixture','text','retained',42)")
                db.execSQL("INSERT INTO notifications(id,package_name,app_name,title,body,post_time) VALUES('n','example.test','Example','Title','Body',42)")
                db.version = version
            }
            ClipyDatabase(context, file).use { helper ->
                assertEquals("retained", HistoryRepository(helper).page().single().value)
                assertEquals(6, helper.readableDatabase.version)
                helper.readableDatabase.rawQuery("SELECT is_archived, sync_state, body FROM notifications", null).use {
                    assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)); assertEquals(0, it.getInt(1)); assertEquals("Body", it.getString(2))
                }
                if (version < 6) helper.readableDatabase.rawQuery("SELECT COUNT(*) FROM pending_sync", null).use {
                    assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0))
                }
            }
        }
    }

    @Test fun pagingIncludesOlderRowsBeyondPreviewCap() = fixture { file ->
        ClipyDatabase(context, file).use { helper ->
            val db = helper.writableDatabase
            db.beginTransaction()
            try {
                repeat(600) { index -> db.execSQL(
                    "INSERT INTO clipboard_history(content_hash,item_type,item_value,created_at) VALUES(?,'text',?,?)",
                    arrayOf("hash$index", "item$index", index)) }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
            val repository = HistoryRepository(helper)
            assertEquals(600, repository.page(limit = 600).size)
            val lastPage = repository.page(limit = 50, offset = 550)
            assertEquals(50, lastPage.size)
            assertEquals("item49", lastPage.first().value)
            assertEquals("item0", lastPage.last().value)
            repository.clear()
            assertTrue(repository.page().isEmpty())
        }
    }

    @Test fun newerDatabaseIsRejectedAndPreserved() = fixture { file ->
        SQLiteDatabase.openOrCreateDatabase(file, null).use { it.version = 7; it.execSQL("CREATE TABLE sentinel(value TEXT)") }
        try { ClipyDatabase(context, file).use { it.writableDatabase }; fail("Expected downgrade rejection") }
        catch (_: android.database.sqlite.SQLiteException) { }
        SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { assertEquals(7, it.version) }
    }
}
