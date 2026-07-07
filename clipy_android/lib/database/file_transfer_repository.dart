import 'package:sqflite/sqflite.dart';
import 'app_database.dart';

class FileTransferRecord {
  final int id;
  final String fileName;
  final String filePath;
  final int fileSize;
  final String senderName;
  final int createdAt;

  FileTransferRecord({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.senderName,
    required this.createdAt,
  });

  Map<String, dynamic> toDisplayJson() => {
        'fileName': fileName,
        'filePath': filePath,
        'fileSize': fileSize,
        'senderName': senderName,
        'date': createdAt,
      };
}

class FileTransferRepository {
  FileTransferRepository._();
  static final FileTransferRepository instance = FileTransferRepository._();

  Future<Database> get _db => AppDatabase.instance.database;

  Future<void> insert({
    required String fileName,
    required String filePath,
    required int fileSize,
    required String senderName,
  }) async {
    await (await _db).insert('file_transfers', {
      'file_name': fileName,
      'file_path': filePath,
      'file_size': fileSize,
      'sender_name': senderName,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _trim(20);
  }

  Future<void> _trim(int maxRows) async {
    await (await _db).rawDelete('''
      DELETE FROM file_transfers
      WHERE id NOT IN (
        SELECT id FROM file_transfers
        ORDER BY created_at DESC
        LIMIT ?
      )
    ''', [maxRows]);
  }

  Future<List<FileTransferRecord>> fetchPage({
    required int offset,
    required int limit,
  }) async {
    final rows = await (await _db).query(
      'file_transfers',
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((row) => FileTransferRecord(
              id: row['id'] as int,
              fileName: row['file_name'] as String,
              filePath: row['file_path'] as String,
              fileSize: row['file_size'] as int,
              senderName: row['sender_name'] as String,
              createdAt: row['created_at'] as int,
            ))
        .toList();
  }

  Future<int> count() async {
    final result =
        await (await _db).rawQuery('SELECT COUNT(*) AS c FROM file_transfers');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> deleteById(int id) async {
    await (await _db).delete('file_transfers', where: 'id = ?', whereArgs: [id]);
  }
}
