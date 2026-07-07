import 'package:sqflite/sqflite.dart';
import 'app_database.dart';

class AppLogRecord {
  final int id;
  final String level;
  final String message;
  final int createdAt;

  AppLogRecord({
    required this.id,
    required this.level,
    required this.message,
    required this.createdAt,
  });

  String get formatted {
    final ts = DateTime.fromMillisecondsSinceEpoch(createdAt)
        .toString()
        .split('.')[0];
    return '[$ts] [${level.toUpperCase()}] $message';
  }
}

class AppLogRepository {
  AppLogRepository._();
  static final AppLogRepository instance = AppLogRepository._();

  static const _maxRows = 2000;

  Future<Database> get _db => AppDatabase.instance.database;

  Future<void> insert({required String level, required String message}) async {
    final db = await _db;
    await db.insert('app_logs', {
      'level': level,
      'message': message,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await db.rawDelete('''
      DELETE FROM app_logs
      WHERE id NOT IN (
        SELECT id FROM app_logs
        ORDER BY id DESC
        LIMIT ?
      )
    ''', [_maxRows]);
  }

  Future<List<AppLogRecord>> fetchPage({
    required int offset,
    required int limit,
  }) async {
    final rows = await (await _db).query(
      'app_logs',
      orderBy: 'id DESC',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((row) => AppLogRecord(
              id: row['id'] as int,
              level: row['level'] as String,
              message: row['message'] as String,
              createdAt: row['created_at'] as int,
            ))
        .toList();
  }

  Future<int> count() async {
    final result = await (await _db).rawQuery('SELECT COUNT(*) AS c FROM app_logs');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> clearAll() async {
    await (await _db).delete('app_logs');
  }
}
