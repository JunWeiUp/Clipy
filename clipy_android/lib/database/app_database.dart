import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../log_manager.dart';
import '../storage_paths.dart';
import 'legacy_migration.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbName = 'clipy.db';
  static const schemaVersion = 5;

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
      onUpgrade: (db, oldVersion, newVersion) async {
        appLog('AppDatabase: upgrade from $oldVersion to $newVersion');
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS pending_notification_sync (
              notification_id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              hash TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          // Reliable delivery queue for text/plain (clipboard) frames awaiting
          // ACK. Per sync power plan v2 — survives restart so content copied
          // just before a crash/quit still reaches the peer on next reappearance.
          await db.execute('''
            CREATE TABLE IF NOT EXISTS pending_text_sync (
              hash TEXT NOT NULL,
              data TEXT NOT NULL,
              type TEXT NOT NULL,
              target_peer_id TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              UNIQUE(target_peer_id, hash)
            )
          ''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_pending_text_sync_peer ON pending_text_sync(target_peer_id)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_pending_text_sync_hash ON pending_text_sync(hash)');
        }
        if (oldVersion < 4) {
          await db.execute(
              'ALTER TABLE notifications ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 5) {
          // sync_state: 0 = 待同步（默认），1 = Mac 已 ack 确认送达。
          // 用于 refreshActiveNotifications 的 backfill：只把 sync_state=0
          // 且不在 pending_notification_sync 队列里的通知补发，已 ack 的不重复补。
          await db.execute(
              'ALTER TABLE notifications ADD COLUMN sync_state INTEGER NOT NULL DEFAULT 0');
        }
      },
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
        is_archived INTEGER NOT NULL DEFAULT 0,
        sync_state INTEGER NOT NULL DEFAULT 0,
        extras_json TEXT NOT NULL DEFAULT '{}',
        synced_at INTEGER
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_notifications_package_time ON notifications(package_name, post_time DESC)');
    await db.execute(
        'CREATE INDEX idx_notifications_post_time ON notifications(post_time DESC)');

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

    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_notification_sync (
        notification_id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        hash TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_text_sync (
        hash TEXT NOT NULL,
        data TEXT NOT NULL,
        type TEXT NOT NULL,
        target_peer_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(target_peer_id, hash)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pending_text_sync_peer ON pending_text_sync(target_peer_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pending_text_sync_hash ON pending_text_sync(hash)');
  }
}
