import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../storage_paths.dart';
import 'legacy_migration.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbName = 'clipy.db';
  static const schemaVersion = 1;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await StoragePaths.appStorageDirectory();
    final path = p.join(dir.path, _dbName);
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onCreate: _onCreate,
    );
    await LegacyMigration.runIfNeeded(db);
    return db;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE clipboard_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content_hash TEXT UNIQUE,
        item_type TEXT NOT NULL,
        item_value TEXT NOT NULL,
        source_app TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_clipboard_created ON clipboard_history(created_at DESC)');

    await db.execute('''
      CREATE TABLE notifications (
        id TEXT PRIMARY KEY,
        notification_key TEXT,
        package_name TEXT NOT NULL,
        app_name TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        body TEXT NOT NULL,
        post_time INTEGER NOT NULL,
        group_key TEXT,
        is_clearable INTEGER NOT NULL DEFAULT 1,
        extras_json TEXT NOT NULL DEFAULT '{}',
        synced_at INTEGER
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_notifications_package_time ON notifications(package_name, post_time DESC)');
    await db.execute(
        'CREATE INDEX idx_notifications_post_time ON notifications(post_time DESC)');

    await db.execute('''
      CREATE TABLE collector_events (
        id TEXT PRIMARY KEY,
        category TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_collector_category_time ON collector_events(category, timestamp DESC)');
    await db.execute(
        'CREATE INDEX idx_collector_synced ON collector_events(synced)');

    await db.execute('''
      CREATE TABLE file_transfers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        sender_name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_file_transfers_created ON file_transfers(created_at DESC)');

    await db.execute('''
      CREATE TABLE app_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_app_logs_created ON app_logs(created_at DESC)');
  }
}
