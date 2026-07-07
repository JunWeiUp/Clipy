import 'package:sqflite/sqflite.dart';
import '../models.dart';
import 'app_database.dart';

class ClipboardRepository {
  ClipboardRepository._();
  static final ClipboardRepository instance = ClipboardRepository._();

  Future<Database> get _db => AppDatabase.instance.database;

  HistoryEntry _fromRow(Map<String, Object?> row) {
    return HistoryEntry(
      item: HistoryItem(
        type: row['item_type'] as String,
        value: row['item_value'] as String,
      ),
      date: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      sourceApp: row['source_app'] as String?,
      contentHash: row['content_hash'] as String?,
    );
  }

  Future<List<HistoryEntry>> fetchPage({required int offset, required int limit}) async {
    final rows = await (await _db).query(
      'clipboard_history',
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  Future<int> count() async {
    final result = await (await _db).rawQuery('SELECT COUNT(*) AS c FROM clipboard_history');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> insert(HistoryEntry entry) async {
    final db = await _db;
    if (entry.contentHash != null) {
      await db.delete(
        'clipboard_history',
        where: 'content_hash = ?',
        whereArgs: [entry.contentHash],
      );
    }
    await db.insert('clipboard_history', {
      'content_hash': entry.contentHash,
      'item_type': entry.item.type,
      'item_value': entry.item.value.toString(),
      'source_app': entry.sourceApp,
      'created_at': entry.date.millisecondsSinceEpoch,
    });
  }

  Future<void> trimToLimit(int limit) async {
    if (limit <= 0) return;
    final db = await _db;
    await db.rawDelete('''
      DELETE FROM clipboard_history
      WHERE id NOT IN (
        SELECT id FROM clipboard_history
        ORDER BY created_at DESC
        LIMIT ?
      )
    ''', [limit]);
  }

  Future<void> clearAll() async {
    await (await _db).delete('clipboard_history');
  }
}
