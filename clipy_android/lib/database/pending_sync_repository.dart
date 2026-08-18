import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Encoded sync frames awaiting ACK, keyed by (peerId, hash).
/// Mirrors macOS `PendingSyncRepository` / `pending_sync` table.
class PendingSyncFrame {
  final String peerId;
  final String hash;
  final String type;
  final Uint8List data;
  final DateTime enqueueAt;

  const PendingSyncFrame({
    required this.peerId,
    required this.hash,
    required this.type,
    required this.data,
    required this.enqueueAt,
  });
}

class PendingSyncRepository {
  PendingSyncRepository._();
  static final PendingSyncRepository instance = PendingSyncRepository._();

  Future<Database> get _db => AppDatabase.instance.database;

  static const _table = 'pending_sync';
  static const int maxPerPeer = 500;
  static const Duration defaultTtl = Duration(hours: 24);

  /// Insert or replace a pending frame. Returns false if per-peer cap exceeded
  /// for a *new* hash (replace of existing always succeeds).
  Future<bool> enqueue({
    required String peerId,
    required String hash,
    required String type,
    required List<int> data,
    DateTime? enqueueAt,
    Duration ttl = defaultTtl,
    int maxPerPeer = PendingSyncRepository.maxPerPeer,
  }) async {
    if (peerId.isEmpty || hash.isEmpty) return false;
    final db = await _db;
    final cutoff =
        DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    await db.delete(_table, where: 'enqueue_at < ?', whereArgs: [cutoff]);

    final existing = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $_table WHERE peer_id = ? AND hash = ?',
      [peerId, hash],
    )) ??
        0;
    if (existing == 0) {
      final count = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM $_table WHERE peer_id = ?',
        [peerId],
      )) ??
          0;
      if (count >= maxPerPeer) return false;
    }

    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    await db.insert(
      _table,
      {
        'peer_id': peerId,
        'hash': hash,
        'type': type,
        'data': bytes,
        'enqueue_at':
            (enqueueAt ?? DateTime.now()).millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<List<PendingSyncFrame>> fetchDue({
    required String peerId,
    Duration ttl = defaultTtl,
  }) async {
    final cutoff =
        DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    final rows = await (await _db).query(
      _table,
      where: 'peer_id = ? AND enqueue_at >= ?',
      whereArgs: [peerId, cutoff],
      orderBy: 'enqueue_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<Set<String>> pendingHashes(String peerId) async {
    final rows = await (await _db).query(
      _table,
      columns: ['hash'],
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return rows.map((r) => r['hash'] as String).toSet();
  }

  /// Cheap EXISTS probe for the flush fast path — avoids materializing up to
  /// 500 BLOB frames on every syncTick just to discover the queue is empty.
  Future<bool> hasPending(String peerId) async {
    final rows = await (await _db).rawQuery(
      'SELECT 1 FROM $_table WHERE peer_id = ? LIMIT 1',
      [peerId],
    );
    return rows.isNotEmpty;
  }

  Future<void> remove({required String peerId, required String hash}) async {
    await (await _db).delete(
      _table,
      where: 'peer_id = ? AND hash = ?',
      whereArgs: [peerId, hash],
    );
  }

  Future<void> removeByHash(String hash) async {
    await (await _db).delete(_table, where: 'hash = ?', whereArgs: [hash]);
  }

  Future<void> removeAllForPeer(String peerId) async {
    await (await _db)
        .delete(_table, where: 'peer_id = ?', whereArgs: [peerId]);
  }

  Future<void> cleanOld({
    Duration maxAge = defaultTtl,
    int maxRows = 2000,
  }) async {
    final db = await _db;
    final cutoff =
        DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    await db.delete(_table, where: 'enqueue_at < ?', whereArgs: [cutoff]);
    final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $_table')) ??
        0;
    if (count > maxRows) {
      await db.rawDelete(
        'DELETE FROM $_table WHERE rowid IN '
        '(SELECT rowid FROM $_table ORDER BY enqueue_at ASC LIMIT ?)',
        [count - maxRows],
      );
    }
  }

  PendingSyncFrame _fromRow(Map<String, Object?> row) {
    final raw = row['data'];
    final Uint8List bytes;
    if (raw is Uint8List) {
      bytes = raw;
    } else if (raw is List<int>) {
      bytes = Uint8List.fromList(raw);
    } else {
      bytes = Uint8List(0);
    }
    return PendingSyncFrame(
      peerId: row['peer_id'] as String,
      hash: row['hash'] as String,
      type: row['type'] as String,
      data: bytes,
      enqueueAt:
          DateTime.fromMillisecondsSinceEpoch(row['enqueue_at'] as int),
    );
  }
}
