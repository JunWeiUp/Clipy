package com.clipyclone.nativeandroid.data

import android.content.Context
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/** Same path and schema as the shipped sqflite database; no destructive fallback. */
class ClipyDatabase(context: Context, file: File = File(context.filesDir, "clipy.db")) :
    SQLiteOpenHelper(context, file.absolutePath, null, 6, DatabaseErrorHandler {
        // Android's default handler deletes a corrupt database and its journals.
        // Preserve the complete on-disk evidence; initialization reports a retryable
        // error instead of replacing the user's library with an empty database.
        throw SQLiteDatabaseCorruptException("History database is corrupt; original files preserved")
    }), java.io.Closeable {
    private val applicationContext = context.applicationContext
    private val defaultPath = file.absolutePath == File(context.filesDir, "clipy.db").absolutePath
    private val schema = context.assets.open("schema_v6.sql").bufferedReader().use { it.readText() }

    override fun onCreate(db: SQLiteDatabase) = createMissingTables(db)
    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
        if (defaultPath) NativeLegacyMigration.run(applicationContext, db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion in 1..5 && newVersion == 6) { "Unsupported database migration" }
        if (oldVersion < 4) db.execSQL("ALTER TABLE notifications ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0")
        if (oldVersion < 5) db.execSQL("ALTER TABLE notifications ADD COLUMN sync_state INTEGER NOT NULL DEFAULT 0")
        createMissingTables(db)
    }

    private fun createMissingTables(db: SQLiteDatabase) {
        schema.split(';').map { it.trim() }.filter { it.isNotEmpty() }.forEach {
            db.execSQL(it.replace(Regex("CREATE TABLE (?!IF NOT EXISTS)"), "CREATE TABLE IF NOT EXISTS ")
                .replace(Regex("CREATE INDEX (?!IF NOT EXISTS)"), "CREATE INDEX IF NOT EXISTS "))
        }
    }
}
