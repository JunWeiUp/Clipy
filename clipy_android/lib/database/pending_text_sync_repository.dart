import 'package:sqflite/sqflite.dart';
import 'app_database.dart';

/// One queued text/plain (clipboard) frame awaiting ACK from a peer.
/// Persisted so a restart mid-delivery still completes (per sync power plan
/// v2 reliable delivery). Bounded (50/peer) + 24h TTL via [cleanOld].
class PendingTextSyncEntry {
  final String hash;
  final String data;
  final String type;
  final String targetPeerId;
  final DateTime createdAt;

  const PendingTextSyncEntry({
    required this.hash,
    required this.data,
    required this.type,
    required this.targetPeerId,
    required this.createdAt,
  });
}

class PendingTextSyncRepository {
  PendingTextSyncRepository._();
  static final PendingTextSyncRepository instance = PendingTextSyncRepository._();

  Future<Database> get _db => AppDatabase.instance.database;

  static const _table = 'pending_text_sync';
  static const int maxPerPeer = 50;

  /// Insert (or replace) a pending frame keyed by (targetPeerId, hash).
  /// Enforces a per-peer cap by evicting the oldest entries when exceeded.
  Future<void> insert({
    required String hash,
    required String data,
    required String type,
    required String targetPeerId,
  }) async {
    final db = await _db;
    await db.insert(
      _table,
      {
        'hash': hash,
        'data': data,
        'type': type,
        'target_peer_id': targetPeerId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // Per-peer cap: drop oldest beyond maxPerPeer.
    final perPeer = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $_table WHERE target_peer_id = ?',
      [targetPeerId],
    )) ?? 0;
    if (perPeer > maxPerPeer) {
      await db.rawDelete(
        'DELETE FROM $_table WHERE rowid IN '
        '(SELECT rowid FROM $_table WHERE target_peer_id = ? '
        'ORDER BY created_at ASC LIMIT ?)',
        [targetPeerId, perPeer - maxPerPeer],
      );
    }
  }

  /// Drop the frame matching this content hash once the peer ACKs.
  Future<void> removeByHash(String hash) async {
    await (await _db).delete(_table, where: 'hash = ?', whereArgs: [hash]);
  }

  /// All pending frames for a peer that just (re)appeared, oldest first.
  Future<List<PendingTextSyncEntry>> fetchByPeer(String peerId) async {
    final rows = await (await _db).query(
      _table,
      where: 'target_peer_id = ?',
      whereArgs: [peerId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Remove entries older than [maxAge] and trim the table to [maxRows].
  Future<void> cleanOld({
    Duration maxAge = const Duration(hours: 24),
    int maxRows = 500,
  }) async {
    final db = await _db;
    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    await db.delete(_table, where: 'created_at < ?', whereArgs: [cutoff]);
    final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $_table')) ??
        0;
    if (count > maxRows) {
      await db.rawDelete(
        'DELETE FROM $_table WHERE rowid IN '
        '(SELECT rowid FROM $_table ORDER BY created_at ASC LIMIT ?)',
        [count - maxRows],
      );
    }
  }

  PendingTextSyncEntry _fromRow(Map<String, Object?> row) {
    return PendingTextSyncEntry(
      hash: row['hash'] as String,
      data: row['data'] as String,
      type: row['type'] as String,
      targetPeerId: row['target_peer_id'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    );
  }
}
