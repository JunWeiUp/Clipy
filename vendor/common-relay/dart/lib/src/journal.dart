part of '../common_relay.dart';

/// One owner per directory. Use the application's private data directory.
class RelayJournal {
  final Directory directory;
  final int Function() clock;
  static const retention = 7 * 86400;
  RelayJournal(this.directory, {int Function()? clock})
      : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000) {
    directory.createSync(recursive: true);
    cleanup();
  }
  File _file(String scope, String kind, String sender, String id) => File('${directory.path}/${hashes.sha256.convert(jsonBytes([scope, kind, sender, id]))}.json');
  Map<String, dynamic>? _read(File file) => file.existsSync() ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic> : null;
  void _write(File file, Map<String, dynamic> record) {
    final temporary = File('${file.path}.tmp');
    try { temporary.writeAsStringSync(jsonEncode(record), flush: true); temporary.renameSync(file.path); }
    finally { if (temporary.existsSync()) temporary.deleteSync(); }
  }
  Map<String, dynamic> prepare(String scope, String id, String to, Uint8List data, int ttl, String Function(int) seal) {
    if (ttl < 1 || ttl > 86400) throw ArgumentError('TTL');
    final file = _file(scope, 'out', '', id), now = clock();
    final digest = hashes.sha256.convert(data).toString(), old = _read(file);
    if (old != null) {
      if (old['recipient'] != to || old['digest'] != digest) throw StateError('Message ID content conflict');
      if (old['status'] == 'received') return old;
      if (old['status'] != 'pending' || (old['expires'] as int) <= now) throw StateError('Message expired');
      return old;
    }
    final expires = now + ttl;
    final record = <String, dynamic>{'recipient': to, 'digest': digest, 'body': seal(expires), 'expires': expires, 'purge': expires + retention, 'status': 'pending'};
    _write(file, record); return record;
  }
  void complete(String scope, String id) {
    final file = _file(scope, 'out', '', id), row = _read(file);
    if (row != null) { row.remove('body'); row['status'] = 'received'; row['purge'] = clock() + retention; _write(file, row); }
  }
  bool contains(String scope, String sender, String id) => ((_read(_file(scope, 'in', sender, id))?['purge'] as int?) ?? 0) > clock();
  void acknowledge(String scope, String sender, String id) {
    if (!contains(scope, sender, id)) _write(_file(scope, 'in', sender, id), {'purge': clock() + retention});
  }
  void cleanup({int batch = 256}) {
    final now = clock(); var changed = 0;
    for (final entity in directory.listSync(followLinks: false)) {
      if (changed >= batch) break;
      if (entity is! File || !RegExp(r'[/\\][a-f0-9]{64}\.json$').hasMatch(entity.path)) continue;
      final row = _read(entity)!;
      if ((row['purge'] as int) <= now) { entity.deleteSync(); changed++; }
      else if (row['status'] == 'pending' && (row['expires'] as int) <= now) { row.remove('body'); row['status'] = 'expired'; _write(entity, row); changed++; }
    }
  }
}
