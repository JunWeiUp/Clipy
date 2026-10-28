package com.clipyclone.nativeandroid

import android.content.Context
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.clipy_android.ClipyApplication
import com.clipyclone.nativeandroid.sync.FlutterStringLists
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit three-key fixture setup/restore; never edits the whole preference XML or system settings. */
@RunWith(AndroidJUnit4::class)
class NativeNotificationColdDriverTest {
    private val keys = listOf("flutter.notificationSyncEnabled", "flutter.notificationCollectedPackages", "flutter.notificationSyncedPackages")
    @Test fun prepare() = runBlocking<Unit> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("notificationColdStartDriver") == "prepare")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue("Only the isolated preview may be prepared", context.packageName.endsWith(".nativepreview"))
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        assertFalse("LAN must remain disabled", prefs.getBoolean("flutter.syncEnabled", false))
        val backup = context.getSharedPreferences("native_nls_fixture_backup", Context.MODE_PRIVATE)
        assertFalse("Restore the existing fixture backup before preparing again", backup.contains("values"))
        val json = JSONObject()
        keys.forEach { key ->
            val raw = prefs.all[key]
            val row = JSONObject().put("present", prefs.contains(key))
            when (raw) {
                null -> row.put("type", "absent")
                is Boolean -> row.put("type", "boolean").put("value", raw)
                is String -> row.put("type", "string").put("value", raw)
                is Set<*> -> row.put("type", "set").put("value", JSONArray(raw.toList()))
                else -> error("Unsupported fixture preference")
            }
            json.put(key, row)
        }
        check(backup.edit().putString("values", json.toString()).putInt("preparePid", android.os.Process.myPid()).commit())
        val pkg = instrumentation.context.packageName
        check(prefs.edit().putBoolean(keys[0], true).putString(keys[1], FlutterStringLists.encode(listOf(pkg)))
            .putString(keys[2], FlutterStringLists.encode(listOf(pkg))).commit())
        (context.applicationContext as ClipyApplication).notifications.reloadPreferences()
        android.util.Log.i("ClipyNlsFixture", "cold-driver=prepared-three-keys")
    }
    @Test fun restore() = runBlocking<Unit> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("notificationColdStartDriver") == "restore")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(context.packageName.endsWith(".nativepreview"))
        val backup = context.getSharedPreferences("native_nls_fixture_backup", Context.MODE_PRIVATE)
        val raw = backup.getString("values", null) ?: error("No fixture backup")
        val app = context.applicationContext as ClipyApplication
        app.notifications.setEnabled(false); app.notifications.awaitCollectionIdle()
        val json = JSONObject(raw)
        val edit = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
        keys.forEach { key ->
            val row = json.getJSONObject(key)
            if (!row.getBoolean("present")) edit.remove(key)
            else when (row.getString("type")) {
                "boolean" -> edit.putBoolean(key, row.getBoolean("value"))
                "string" -> edit.putString(key, row.getString("value"))
                "set" -> { val values = row.getJSONArray("value"); edit.putStringSet(key, (0 until values.length()).map { values.getString(it) }.toSet()) }
                else -> error("Invalid fixture backup")
            }
        }
        check(edit.commit()); app.notifications.reloadPreferences()
        check(backup.edit().remove("values").remove("preparePid").commit())
        android.util.Log.i("ClipyNlsFixture", "cold-driver=restored-three-keys")
    }
}
