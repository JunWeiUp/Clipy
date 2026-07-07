import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../log_manager.dart';
import '../models.dart';
import '../storage_paths.dart';

class LegacyMigration {
  static const _prefKey = 'dbMigrationVersion';
  static const _targetVersion = 1;

  static Future<void> runIfNeeded(Database db) async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getInt(_prefKey) ?? 0;
    if (done >= _targetVersion) return;

    final dir = await StoragePaths.appStorageDirectory();
    await _importClipboard(db, File('${dir.path}/history.json'));
    await _importNotifications(db, File('${dir.path}/notification_history.jsonl'));
    await _importCollectorEvents(db, File('${dir.path}/collector_events.jsonl'));
    await _importFileHistory(db, prefs);

    await prefs.setInt(_prefKey, _targetVersion);
    appLog('LegacyMigration: completed v$_targetVersion');
  }

  static Future<void> _importClipboard(Database db, File file) async {
    if (!await file.exists()) return;
    try {
      final content = await file.readAsString();
      final list = jsonDecode(content) as List<dynamic>;
      final batch = db.batch();
      for (final item in list) {
        final entry = HistoryEntry.fromJson(Map<String, dynamic>.from(item as Map));
        batch.insert(
          'clipboard_history',
          _clipboardRow(entry),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
      await file.rename('${file.path}.migrated.bak');
      appLog('LegacyMigration: imported clipboard history');
    } catch (e) {
      appLog('LegacyMigration: clipboard import error: $e', level: 'warning');
    }
  }

  static Map<String, Object?> _clipboardRow(HistoryEntry entry) {
    return {
      'content_hash': entry.contentHash,
      'item_type': entry.item.type,
      'item_value': entry.item.value.toString(),
      'source_app': entry.sourceApp,
      'created_at': entry.date.millisecondsSinceEpoch,
    };
  }

  static Future<void> _importNotifications(Database db, File file) async {
    if (!await file.exists()) return;
    try {
      final batch = db.batch();
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final entry = NotificationEntry.fromJson(
            Map<String, dynamic>.from(jsonDecode(trimmed) as Map));
        batch.insert(
          'notifications',
          _notificationRow(entry),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await file.rename('${file.path}.migrated.bak');
      appLog('LegacyMigration: imported notifications');
    } catch (e) {
      appLog('LegacyMigration: notifications import error: $e', level: 'warning');
    }
  }

  static Map<String, Object?> _notificationRow(NotificationEntry entry) {
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

  static Future<void> _importCollectorEvents(Database db, File file) async {
    if (!await file.exists()) return;
    try {
      final batch = db.batch();
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final event = CollectorEvent.fromJson(
            Map<String, dynamic>.from(jsonDecode(trimmed) as Map));
        if (event.category == CollectorCategories.notification) continue;
        batch.insert(
          'collector_events',
          {
            'id': event.id,
            'category': event.category,
            'timestamp': event.timestamp,
            'device_id': event.deviceId,
            'payload_json': jsonEncode(event.payload),
            'synced': 1,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
      await file.rename('${file.path}.migrated.bak');
      appLog('LegacyMigration: imported collector events');
    } catch (e) {
      appLog('LegacyMigration: collector import error: $e', level: 'warning');
    }
  }

  static Future<void> _importFileHistory(
      Database db, SharedPreferences prefs) async {
    final jsonStr = prefs.getString('fileHistory');
    if (jsonStr == null || jsonStr.isEmpty) return;
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final batch = db.batch();
      for (final item in list) {
        final map = Map<String, dynamic>.from(item as Map);
        batch.insert('file_transfers', {
          'file_name': map['fileName'] ?? '',
          'file_path': map['filePath'] ?? '',
          'file_size': (map['fileSize'] as num?)?.toInt() ?? 0,
          'sender_name': map['senderName'] ?? '',
          'created_at': (map['date'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        });
      }
      await batch.commit(noResult: true);
      await prefs.remove('fileHistory');
      appLog('LegacyMigration: imported file history');
    } catch (e) {
      appLog('LegacyMigration: file history import error: $e', level: 'warning');
    }
  }
}
