import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../models.dart';
import 'app_database.dart';

class CollectorRepository {
  CollectorRepository._();
  static final CollectorRepository instance = CollectorRepository._();

  /// Hard cap so long-running installs don't grow the DB without bound.
  static const maxRows = 2000;
  int _insertsSinceTrim = 0;

  Future<Database> get _db => AppDatabase.instance.database;

  CollectorEvent _fromRow(Map<String, Object?> row) {
    return CollectorEvent(
      id: row['id'] as String,
      category: row['category'] as String,
      timestamp: row['timestamp'] as int,
      deviceId: row['device_id'] as String,
      payload: Map<String, dynamic>.from(
          jsonDecode(row['payload_json'] as String) as Map),
    );
  }

  Future<List<CollectorEvent>> fetchPage({
    String? category,
    required int offset,
    required int limit,
  }) async {
    final db = await _db;
    final rows = category == null
        ? await db.query(
            'collector_events',
            where: 'category != ?',
            whereArgs: [CollectorCategories.notification],
            orderBy: 'timestamp DESC',
            limit: limit,
            offset: offset,
          )
        : await db.query(
            'collector_events',
            where: 'category = ?',
            whereArgs: [category],
            orderBy: 'timestamp DESC',
            limit: limit,
            offset: offset,
          );
    return rows.map(_fromRow).toList();
  }

  Future<int> count({String? category}) async {
    final db = await _db;
    final result = category == null
        ? await db.rawQuery(
            "SELECT COUNT(*) AS c FROM collector_events WHERE category != ?",
            [CollectorCategories.notification],
          )
        : await db.rawQuery(
            'SELECT COUNT(*) AS c FROM collector_events WHERE category = ?',
            [category],
          );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> insert(CollectorEvent event, {bool synced = false}) async {
    final db = await _db;
    await db.insert(
      'collector_events',
      {
        'id': event.id,
        'category': event.category,
        'timestamp': event.timestamp,
        'device_id': event.deviceId,
        'payload_json': jsonEncode(event.payload),
        'synced': synced ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // Trim in batches: an exact-count check per insert would double the writes.
    _insertsSinceTrim++;
    if (_insertsSinceTrim >= 50) {
      _insertsSinceTrim = 0;
      // Keep unsynced rows so pending events are never dropped before flush.
      await db.rawDelete('''
        DELETE FROM collector_events
        WHERE synced = 1 AND id NOT IN (
          SELECT id FROM collector_events
          ORDER BY timestamp DESC
          LIMIT ?
        )
      ''', [maxRows]);
    }
  }

  Future<void> markSynced(String id, {bool synced = true}) async {
    await (await _db).update(
      'collector_events',
      {'synced': synced ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> hasRecentDuplicate({
    required String category,
    required int sinceMs,
    required Map<String, dynamic> payloadMatch,
  }) async {
    final db = await _db;
    final clauses = <String>['category = ?', 'timestamp >= ?'];
    final args = <Object?>[category, sinceMs];
    for (final entry in payloadMatch.entries) {
      clauses.add("json_extract(payload_json, '\$.${entry.key}') = ?");
      args.add(entry.value);
    }
    final rows = await db.query(
      'collector_events',
      where: clauses.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasPayloadMatch({
    required String category,
    required Map<String, dynamic> payloadMatch,
  }) async {
    final db = await _db;
    final clauses = <String>['category = ?'];
    final args = <Object?>[category];
    for (final entry in payloadMatch.entries) {
      clauses.add("json_extract(payload_json, '\$.${entry.key}') = ?");
      args.add(entry.value);
    }
    final rows = await db.query(
      'collector_events',
      where: clauses.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<CollectorEvent>> fetchPending({int limit = 500}) async {
    final rows = await (await _db).query(
      'collector_events',
      where: 'synced = 0',
      orderBy: 'timestamp ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// Clipboard sync now uses text/plain directly; skip legacy pending rows.
  Future<void> markAllClipboardSynced() async {
    await (await _db).update(
      'collector_events',
      {'synced': 1},
      where: 'category = ? AND synced = 0',
      whereArgs: [CollectorCategories.clipboard],
    );
  }
}
