import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../models.dart';
import 'app_database.dart';

class NotificationPackageGroup {
  final String packageName;
  final String appName;
  final int count;
  final int latestPostTime;

  const NotificationPackageGroup({
    required this.packageName,
    required this.appName,
    required this.count,
    required this.latestPostTime,
  });
}

class NotificationRepository {
  NotificationRepository._();
  static final NotificationRepository instance = NotificationRepository._();

  static const duplicateWindowMs = 30000;
  /// Hard cap so long-running installs don't grow the DB without bound.
  static const maxRows = 5000;
  int _insertsSinceTrim = 0;

  Future<Database> get _db => AppDatabase.instance.database;

  NotificationEntry _fromRow(Map<String, Object?> row) {
    return NotificationEntry(
      id: row['id'] as String,
      notificationKey: row['notification_key'] as String?,
      packageName: row['package_name'] as String,
      appName: row['app_name'] as String,
      title: row['title'] as String,
      subtitle: row['subtitle'] as String?,
      body: row['body'] as String,
      postTime: row['post_time'] as int,
      groupKey: row['group_key'] as String?,
      isClearable: (row['is_clearable'] as int? ?? 1) == 1,
      extras: Map<String, dynamic>.from(
          jsonDecode(row['extras_json'] as String? ?? '{}') as Map),
    );
  }

  Map<String, Object?> _toRow(NotificationEntry entry) {
    return {
      'id': entry.id,
      'notification_key': entry.notificationKey,
      'package_name': entry.packageName,
      'app_name': entry.appName,
      'title': entry.title,
      'subtitle': entry.subtitle,
      'body': entry.body,
      'post_time': entry.postTime,
      'group_key': entry.groupKey,
      'is_clearable': entry.isClearable ? 1 : 0,
      'extras_json': jsonEncode(entry.extras),
    };
  }

  bool _isEmpty(NotificationEntry entry) {
    return entry.title.trim().isEmpty &&
        (entry.subtitle ?? '').trim().isEmpty &&
        entry.body.trim().isEmpty &&
        entry.extras.values.every((v) => v.toString().trim().isEmpty);
  }

  Future<bool> upsert(NotificationEntry entry) async {
    if (_isEmpty(entry)) return false;
    final db = await _db;

    final byId = await db.query(
      'notifications',
      where: 'id = ?',
      whereArgs: [entry.id],
      limit: 1,
    );
    if (byId.isNotEmpty) {
      await db.update('notifications', _toRow(entry), where: 'id = ?', whereArgs: [entry.id]);
      return true;
    }

    final dupRows = await db.query(
      'notifications',
      where: 'package_name = ? AND ABS(post_time - ?) <= ?',
      whereArgs: [entry.packageName, entry.postTime, duplicateWindowMs],
      orderBy: 'post_time DESC',
      limit: 20,
    );
    for (final row in dupRows) {
      final existing = _fromRow(row);
      if (_isDuplicate(existing, entry)) {
        await db.delete('notifications', where: 'id = ?', whereArgs: [existing.id]);
        break;
      }
    }

    await db.insert('notifications', _toRow(entry),
        conflictAlgorithm: ConflictAlgorithm.replace);
    // Trim in batches: an exact-count check per insert would double the writes.
    _insertsSinceTrim++;
    if (_insertsSinceTrim >= 50) {
      _insertsSinceTrim = 0;
      await _trimToLimit(db);
    }
    return true;
  }

  Future<void> _trimToLimit(Database db) async {
    await db.rawDelete('''
      DELETE FROM notifications
      WHERE id NOT IN (
        SELECT id FROM notifications
        ORDER BY post_time DESC
        LIMIT ?
      )
    ''', [maxRows]);
  }

  bool _isDuplicate(NotificationEntry existing, NotificationEntry incoming) {
    if (existing.notificationKey != null &&
        incoming.notificationKey != null &&
        existing.notificationKey == incoming.notificationKey) {
      return true;
    }
    return existing.title.trim() == incoming.title.trim() &&
        (existing.subtitle ?? '').trim() == (incoming.subtitle ?? '').trim() &&
        existing.body.trim() == incoming.body.trim() &&
        existing.groupKey == incoming.groupKey;
  }

  Future<int> count() async {
    final result = await (await _db).rawQuery('SELECT COUNT(*) AS c FROM notifications');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<List<NotificationPackageGroup>> fetchPackageGroups({
    required int offset,
    required int limit,
  }) async {
    final rows = await (await _db).rawQuery('''
      SELECT package_name, app_name, COUNT(*) AS cnt, MAX(post_time) AS latest
      FROM notifications
      GROUP BY package_name
      ORDER BY latest DESC
      LIMIT ? OFFSET ?
    ''', [limit, offset]);
    return rows
        .map((row) => NotificationPackageGroup(
              packageName: row['package_name'] as String,
              appName: row['app_name'] as String,
              count: row['cnt'] as int,
              latestPostTime: row['latest'] as int,
            ))
        .toList();
  }

  Future<int> packageGroupCount() async {
    final result = await (await _db).rawQuery(
        'SELECT COUNT(DISTINCT package_name) AS c FROM notifications');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<List<NotificationEntry>> fetchByPackage(
    String packageName, {
    required int offset,
    required int limit,
  }) async {
    final rows = await (await _db).query(
      'notifications',
      where: 'package_name = ?',
      whereArgs: [packageName],
      orderBy: 'post_time DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<NotificationEntry>> fetchPage({
    required int offset,
    required int limit,
  }) async {
    final rows = await (await _db).query(
      'notifications',
      orderBy: 'post_time DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> removeById(String id) async {
    await (await _db).delete('notifications', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    await (await _db).delete('notifications');
  }

  Future<List<String>> distinctPackageNames() async {
    final rows = await (await _db).rawQuery(
        'SELECT DISTINCT package_name FROM notifications ORDER BY package_name');
    return rows.map((r) => r['package_name'] as String).toList();
  }
}
