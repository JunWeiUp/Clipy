import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models.dart';
import 'app_database.dart';
import '../storage_paths.dart';

class ClipboardRepository {
  ClipboardRepository._() : _database = null;

  /// An explicit connection keeps storage tests isolated from app state.
  ClipboardRepository.forDatabase(Database database) : _database = database;
  final Database? _database;
  static final ClipboardRepository instance = ClipboardRepository._();

  Future<Database> get _db async =>
      _database ?? await AppDatabase.instance.database;

  HistoryEntry _fromRow(Map<String, Object?> row) {
    return HistoryEntry(
      item: HistoryItem(
        type: row['item_type'] as String,
        value: row['item_type'] == 'fileURLs'
            ? (jsonDecode(row['item_value'] as String) as List).cast<String>()
            : row['item_value'] as String,
      ),
      date: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      sourceApp: row['source_app'] as String?,
      contentHash: row['content_hash'] as String?,
    );
  }

  Future<List<HistoryEntry>> fetchPage({
    required int offset,
    required int limit,
    String query = '',
    String filter = 'all',
  }) async {
    final conditions = <String>[];
    final args = <Object?>[];
    if (query.trim().isNotEmpty) {
      // Bind and escape LIKE metacharacters: searching "100%" is literal.
      final escaped = query
          .trim()
          .replaceAll('!', '!!')
          .replaceAll('%', '!%')
          .replaceAll('_', '!_');
      conditions.add(
        "((item_type IN ('text', 'fileURL', 'fileURLs') AND item_value LIKE ? ESCAPE '!') OR source_app LIKE ? ESCAPE '!')",
      );
      args.addAll(['%$escaped%', '%$escaped%']);
    }
    switch (filter) {
      case 'text':
        conditions.add("item_type = 'text'");
      case 'links':
        conditions.add(
          "item_type = 'text' AND (LOWER(TRIM(item_value)) LIKE 'https://%' OR LOWER(TRIM(item_value)) LIKE 'http://%')",
        );
      case 'files':
        conditions.add("item_type IN ('fileURL', 'fileURLs')");
      case 'images':
        conditions.add("item_type = 'image'");
    }
    final rows = await (await _db).query(
      'clipboard_history',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  Future<int> count() async {
    final result = await (await _db).rawQuery(
      'SELECT COUNT(*) AS c FROM clipboard_history',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// The most-recent history entry (highest created_at), or null if empty.
  /// Used by [ClipboardManager.handleRemoteSync] to detect a duplicate remote
  /// push that is already at the top, so it can skip the re-insert + notify
  /// (which would otherwise cause a UI refresh storm on every reconnect-driven
  /// pending-frame resend).
  Future<HistoryEntry?> latestEntry() async {
    final rows = await (await _db).query(
      'clipboard_history',
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Recent text/plain rows for history.fetch replay (newest first).
  Future<List<({String text, String hash})>> fetchRecentTexts({
    int limit = 200,
  }) async {
    final rows = await (await _db).query(
      'clipboard_history',
      columns: ['item_value', 'content_hash'],
      where: "item_type = ?",
      whereArgs: ['text'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    final out = <({String text, String hash})>[];
    for (final row in rows) {
      final text = row['item_value'] as String? ?? '';
      final hash = row['content_hash'] as String? ?? '';
      if (text.isEmpty || hash.isEmpty) continue;
      out.add((text: text, hash: hash));
    }
    return out;
  }

  Future<void> insert(HistoryEntry entry) async {
    final db = await _db;
    // Delete and reinsert atomically: a failed write preserves the old row.
    await db.transaction((txn) async {
      if (entry.contentHash != null) {
        await txn.delete(
          'clipboard_history',
          where: 'content_hash = ?',
          whereArgs: [entry.contentHash],
        );
      }
      await txn.insert('clipboard_history', {
        'content_hash': entry.contentHash,
        'item_type': entry.item.type,
        'item_value': entry.item.type == 'fileURLs'
            ? jsonEncode(entry.item.value)
            : entry.item.value.toString(),
        'source_app': entry.sourceApp,
        'created_at': entry.date.millisecondsSinceEpoch,
      });
    });
  }

  /// Insert multiple entries in a single transaction using INSERT OR IGNORE
  /// semantics: a row with the same `content_hash` (UNIQUE) is left completely
  /// untouched — not deleted, not re-inserted, its `created_at` is NOT bumped.
  /// This is critical for the history.fetch catch-up path: if we delete +
  /// re-insert, the row's created_at refreshes to now, it jumps to the top of
  /// the list, and the UI rebuilds on every fetch even though nothing changed
  /// — the "endless refresh" symptom.
  ///
  /// Returns the number of rows actually inserted (new entries only).
  Future<int> insertBatch(List<HistoryEntry> entries) async {
    if (entries.isEmpty) return 0;
    final db = await _db;
    var inserted = 0;
    await db.transaction((txn) async {
      for (final entry in entries) {
        final result = await txn.insert('clipboard_history', {
          'content_hash': entry.contentHash,
          'item_type': entry.item.type,
          'item_value': entry.item.value.toString(),
          'source_app': entry.sourceApp,
          'created_at': entry.date.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        // insert returns 0 (actually the rowid, but 0 for ignored) when the
        // UNIQUE constraint triggered an IGNORE. SQLite's insertOrIgnore in
        // sqflite returns the rowid; 0 means it was ignored.
        if (result != 0) inserted++;
      }
    });
    return inserted;
  }

  Future<void> trimToLimit(int limit) async {
    if (limit <= 0) return;
    final db = await _db;
    final discarded = await db.transaction((txn) async {
      final images = await txn.rawQuery(
        '''
        SELECT item_value FROM clipboard_history
        WHERE item_type = 'image' AND id NOT IN (
          SELECT id FROM clipboard_history ORDER BY created_at DESC LIMIT ?
        )
      ''',
        [limit],
      );
      await txn.rawDelete(
        '''
        DELETE FROM clipboard_history WHERE id NOT IN (
          SELECT id FROM clipboard_history ORDER BY created_at DESC LIMIT ?
        )
      ''',
        [limit],
      );
      return images;
    });
    await _deleteOwnedImages(discarded);
  }

  Future<void> clearAll() async {
    final db = await _db;
    final images = await db.transaction((txn) async {
      final paths = await txn.query(
        'clipboard_history',
        columns: ['item_value'],
        where: "item_type = 'image'",
      );
      await txn.delete('clipboard_history');
      return paths;
    });
    await _deleteOwnedImages(images);
  }

  Future<void> _deleteOwnedImages(List<Map<String, Object?>> rows) async {
    if (!Platform.isWindows) return;
    final root = Directory(
      p.join(
        (await StoragePaths.appStorageDirectory()).path,
        'clipboard-images',
      ),
    );
    for (final row in rows) {
      final path = row['item_value'] as String?;
      if (path == null || !p.isWithin(root.path, path)) continue;
      try {
        await File(path).delete();
      } on FileSystemException {
        // A missing or locked preview does not block history cleanup.
      }
    }
  }

  /// Returns the subset of `hashes` that already exist in the DB. Used by the
  /// batch catch-up path to skip frames the receiver already has, keeping a
  /// history.fetch replay idempotent without N individual lookups.
  Future<Set<String>> existingHashes(List<String> hashes) async {
    if (hashes.isEmpty) return {};
    final placeholders = List.filled(hashes.length, '?').join(',');
    final rows = await (await _db).rawQuery(
      'SELECT content_hash FROM clipboard_history WHERE content_hash IN ($placeholders)',
      hashes,
    );
    return rows.map((r) => r['content_hash']).whereType<String>().toSet();
  }
}
