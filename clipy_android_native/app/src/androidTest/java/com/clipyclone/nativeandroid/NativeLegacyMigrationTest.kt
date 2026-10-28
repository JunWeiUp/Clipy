package com.clipyclone.nativeandroid

import android.content.Context
import android.content.SharedPreferences
import android.database.DatabaseUtils
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.data.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.time.Instant
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class NativeLegacyMigrationTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture(block: (File, SharedPreferences, ClipyDatabase) -> Unit) {
        val name = "legacy-${UUID.randomUUID()}"
        val root = File(context.cacheDir, name).apply { mkdirs() }
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        try { ClipyDatabase(context, File(root, "data.db")).use { block(root, prefs, it) } }
        finally { context.deleteSharedPreferences(name); root.deleteRecursively() }
    }
    @Test fun importsAllExistingSourcesAndArchivesOriginalFiles() = fixture { root, prefs, helper ->
        val time = System.currentTimeMillis()
        val history = JSONArray().put(JSONObject().put("item", JSONObject().put("text", "legacy fixture"))
            .put("date", 0).put("sourceApp", "Example").put("contentHash", JSONObject.NULL))
            .put(JSONObject().put("item", JSONObject().put("fileURLs", JSONArray().put("/example/a").put("/example/b")))
                .put("date", Instant.ofEpochMilli(time).toString()).put("contentHash", "files-fixture"))
        File(root, "history.json").writeText(history.toString())
        val notification = JSONObject().put("id", "n-fixture").put("packageName", "example.app").put("appName", "Example")
            .put("title", "Title").put("body", "Body").put("postTime", time)
            .put("extras", JSONObject().put("clipyArchived", true).put("nested", JSONObject().put("value", 7)))
        File(root, "notification_history.jsonl").writeText(notification.toString() + "\n")
        prefs.edit().putString("flutter.fileHistory", JSONArray().put(JSONObject().put("fileName", "fixture.txt")
            .put("filePath", "/example/fixture.txt").put("fileSize", 12).put("senderName", "Example Mac").put("date", time)).toString()).commit()
        val db = helper.writableDatabase
        NativeLegacyMigration.run(context, db, root, prefs)
        assertEquals(1L, prefs.getLong("flutter.dbMigrationVersion", 0)); assertFalse(prefs.contains("flutter.fileHistory"))
        assertFalse(File(root, "history.json").exists()); assertTrue(File(root, "history.json.migrated.bak").isFile)
        assertTrue(File(root, "notification_history.jsonl.migrated.bak").isFile)
        assertEquals(2L, DatabaseUtils.queryNumEntries(db, "clipboard_history"))
        db.rawQuery("SELECT created_at FROM clipboard_history WHERE item_type='text'", null).use {
            assertTrue(it.moveToFirst()); assertEquals(978307200000L, it.getLong(0)) // Fixed Apple reference epoch.
        }
        db.rawQuery("SELECT item_value FROM clipboard_history WHERE item_type='fileURLs'", null).use {
            assertTrue(it.moveToFirst()); assertEquals(2, JSONArray(it.getString(0)).length())
        }
        db.rawQuery("SELECT is_archived,extras_json FROM notifications", null).use {
            assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)); assertEquals(7, JSONObject(it.getString(1)).getJSONObject("nested").getInt("value"))
        }
        assertEquals(1L, DatabaseUtils.queryNumEntries(db, "file_transfers"))
        NativeLegacyMigration.run(context, db, root, prefs)
        assertEquals(2L, DatabaseUtils.queryNumEntries(db, "clipboard_history"))
    }
    @Test fun malformedSourceRollsBackAndKeepsOriginalForRetry() = fixture { root, prefs, helper ->
        File(root, "history.json").writeText("[{\"item\":{\"text\":\"first\"},\"date\":0},{\"date\":0}]")
        val db = helper.writableDatabase
        try { NativeLegacyMigration.run(context, db, root, prefs); fail("Malformed row accepted") } catch (_: org.json.JSONException) { }
        assertEquals(0L, DatabaseUtils.queryNumEntries(db, "clipboard_history"))
        assertTrue(File(root, "history.json").isFile); assertFalse(prefs.contains("flutter.dbMigrationVersion"))
    }
    @Test fun committedImportJournalPreventsDuplicateNullHashRowsAfterPreferenceFailure() = fixture { root, prefs, helper ->
        File(root, "history.json").writeText("[{\"item\":{\"text\":\"no hash\"},\"date\":0}]")
        val failing = object : SharedPreferences by prefs {
            override fun edit(): SharedPreferences.Editor {
                val base = prefs.edit()
                return object : SharedPreferences.Editor by base {
                    override fun remove(key: String?): SharedPreferences.Editor { base.remove(key); return this }
                    override fun putLong(key: String?, value: Long): SharedPreferences.Editor { base.putLong(key, value); return this }
                    override fun commit() = false
                }
            }
        }
        val db = helper.writableDatabase
        try { NativeLegacyMigration.run(context, db, root, failing); fail("Expected preferences failure") } catch (_: IllegalStateException) { }
        assertEquals(1L, DatabaseUtils.queryNumEntries(db, "clipboard_history"))
        File(root, "history.json.migrated.bak").copyTo(File(root, "history.json"))
        NativeLegacyMigration.run(context, db, root, prefs)
        assertEquals(1L, DatabaseUtils.queryNumEntries(db, "clipboard_history"))
        assertTrue(File(root, "history.json.migrated.bak").isFile)
        assertTrue(File(root, "history.json.migrated.bak.2").isFile)
    }
}
