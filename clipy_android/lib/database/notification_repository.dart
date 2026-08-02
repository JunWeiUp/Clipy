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

/// Result of [NotificationRepository.upsert].
class NotificationUpsertResult {
  final bool accepted;
  /// Local entries removed because this post replaces them (same slot / WeChat
  /// conversation). Callers should dismiss these on peers before posting new.
  final List<NotificationEntry> replaced;

  const NotificationUpsertResult({
    required this.accepted,
    this.replaced = const [],
  });

  static const rejected = NotificationUpsertResult(accepted: false);
}

class NotificationRepository {
  NotificationRepository._();
  static final NotificationRepository instance = NotificationRepository._();

  static const duplicateWindowMs = 30000;
  /// Hard cap so long-running installs don't grow the DB without bound.
  static const maxRows = 5000;
  /// WeChat updates the same conversation notification in-place (same person /
  /// same chat title). Treat those as replacements, not new history rows.
  static const wechatPackageName = 'com.tencent.mm';
  int _insertsSinceTrim = 0;

  Future<Database> get _db => AppDatabase.instance.database;

  NotificationEntry _fromRow(Map<String, Object?> row) {
    final extras = Map<String, dynamic>.from(
        jsonDecode(row['extras_json'] as String? ?? '{}') as Map);
    final archivedCol = (row['is_archived'] as int? ?? 0) == 1;
    final archivedExtra = extras['clipyArchived'] == true ||
        extras['clipyArchived']?.toString() == 'true';
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
      isArchived: archivedCol || archivedExtra,
      extras: extras,
    );
  }

  Map<String, Object?> _toRow(NotificationEntry entry) {
    final extras = Map<String, dynamic>.from(entry.extras);
    if (entry.isArchived) {
      extras['clipyArchived'] = true;
    } else {
      extras.remove('clipyArchived');
    }
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
      'is_archived': entry.isArchived ? 1 : 0,
      'extras_json': jsonEncode(extras),
    };
  }

  bool _isEmpty(NotificationEntry entry) {
    return entry.title.trim().isEmpty &&
        (entry.subtitle ?? '').trim().isEmpty &&
        entry.body.trim().isEmpty &&
        entry.extras.values.every((v) => v.toString().trim().isEmpty);
  }

  /// Upserts a notification entry.
  ///
  /// Returns [NotificationUpsertResult.rejected] when the entry is an exact
  /// re-send of something we already have (identical content).
  ///
  /// WeChat (`com.tencent.mm`) in-place updates: the previous snapshot is kept
  /// with [NotificationEntry.isArchived]=true and a unique notificationKey, so
  /// every message stays in history. Other apps still replace the same slot.
  ///
  /// [NotificationUpsertResult.replaced] lists entries that were deleted (and
  /// should be dismissed on peers). Archived WeChat snapshots are not listed.
  Future<NotificationUpsertResult> upsert(NotificationEntry entry) async {
    if (_isEmpty(entry)) return NotificationUpsertResult.rejected;
    final db = await _db;
    final replaced = <NotificationEntry>[];

    final byId = await db.query(
      'notifications',
      where: 'id = ?',
      whereArgs: [entry.id],
      limit: 1,
    );
    if (byId.isNotEmpty) {
      final existing = _fromRow(byId.first);
      if (_isDuplicate(existing, entry)) {
        return NotificationUpsertResult.rejected;
      }
      await db.update('notifications', _toRow(entry),
          where: 'id = ?', whereArgs: [entry.id]);
      return const NotificationUpsertResult(accepted: true);
    }

    // Same notification slot (stable Android sbn.key).
    final key = entry.notificationKey;
    if (key != null && key.isNotEmpty) {
      final byKey = await db.query(
        'notifications',
        where: 'notification_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (byKey.isNotEmpty) {
        final existing = _fromRow(byKey.first);
        if (_isDuplicate(existing, entry)) {
          return NotificationUpsertResult.rejected;
        }
        if (entry.packageName == wechatPackageName) {
          // Keep prior WeChat message as archived history; free the live key.
          await _archiveInPlace(db, existing);
        } else {
          replaced.add(existing);
          await db.delete('notifications',
              where: 'id = ?', whereArgs: [existing.id]);
        }
      }
    }

    final dupRows = await db.query(
      'notifications',
      where: 'package_name = ?',
      whereArgs: [entry.packageName],
      orderBy: 'post_time DESC',
      limit: 50,
    );
    for (final row in dupRows) {
      final existing = _fromRow(row);
      if (_isDuplicate(existing, entry)) {
        // Exact content re-send — ignore. Never delete archived WeChat history.
        return NotificationUpsertResult.rejected;
      }
    }

    await db.insert('notifications', _toRow(entry),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _insertsSinceTrim++;
    if (_insertsSinceTrim >= 50) {
      _insertsSinceTrim = 0;
      await _trimToLimit(db);
    }
    return NotificationUpsertResult(accepted: true, replaced: replaced);
  }

  /// Detach a live notification slot so a newer WeChat update can use the same
  /// Android key, while keeping the old message as a distinct history row.
  Future<void> _archiveInPlace(Database db, NotificationEntry existing) async {
    if (existing.isArchived) return;
    final archived = existing.copyWith(
      notificationKey: 'clipy-archived:${existing.id}',
      isArchived: true,
    );
    await db.update(
      'notifications',
      _toRow(archived),
      where: 'id = ?',
      whereArgs: [existing.id],
    );
  }

  Future<void> _trimToLimit(Database db) async {
    final thresholdRow = await db.rawQuery(
      'SELECT post_time FROM notifications ORDER BY post_time DESC LIMIT 1 OFFSET ?',
      [maxRows],
    );
    if (thresholdRow.isEmpty) return;
    final threshold = thresholdRow.first['post_time'] as int;
    await db.delete('notifications', where: 'post_time < ?', whereArgs: [threshold]);
  }

  /// True when [incoming] is an exact content re-send of [existing].
  ///
  /// IMPORTANT: same Android `notificationKey` alone is NOT a duplicate.
  /// Messaging apps reuse the StatusBarNotification key when a second message
  /// arrives and the system folds/stacks the notification — content changes
  /// but the key stays the same. Treating key equality as duplicate dropped
  /// those folded updates on Xiaomi and similar OEMs.
  bool _isDuplicate(NotificationEntry existing, NotificationEntry incoming) {
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

  Future<void> removeByNotificationKey(String key) async {
    await (await _db).delete('notifications',
        where: 'notification_key = ?', whereArgs: [key]);
  }

  Future<void> clearAll() async {
    await (await _db).delete('notifications');
  }

  Future<List<String>> distinctPackageNames() async {
    final rows = await (await _db).rawQuery(
        'SELECT DISTINCT package_name FROM notifications ORDER BY package_name');
    return rows.map((r) => r['package_name'] as String).toList();
  }

  // ---- Pending notification sync (offline delivery queue) ----

  Future<void> insertPendingSync({
    required String notificationId,
    required String content,
    required String hash,
  }) async {
    final db = await _db;
    await db.insert(
      'pending_notification_sync',
      {
        'notification_id': notificationId,
        'content': content,
        'hash': hash,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removePendingSync(String notificationId) async {
    await (await _db).delete(
      'pending_notification_sync',
      where: 'notification_id = ?',
      whereArgs: [notificationId],
    );
  }

  Future<List<Map<String, dynamic>>> fetchAllPendingSync() async {
    return (await _db).query(
      'pending_notification_sync',
      orderBy: 'created_at ASC',
    );
  }

  /// Remove entries older than [maxAgeDays] and trim to [maxRows].
  Future<void> cleanOldPendingSync({
    int maxAgeDays = 7,
    int maxRows = 500,
  }) async {
    final db = await _db;
    final cutoff = DateTime.now()
        .subtract(Duration(days: maxAgeDays))
        .millisecondsSinceEpoch;
    await db.delete('pending_notification_sync',
        where: 'created_at < ?', whereArgs: [cutoff]);
    final count = Sqflite.firstIntValue(await db
            .rawQuery('SELECT COUNT(*) FROM pending_notification_sync')) ??
        0;
    if (count > maxRows) {
      await db.rawDelete(
        'DELETE FROM pending_notification_sync WHERE notification_id IN '
        '(SELECT notification_id FROM pending_notification_sync '
        'ORDER BY created_at ASC LIMIT ?)',
        [count - maxRows],
      );
    }
  }
}
