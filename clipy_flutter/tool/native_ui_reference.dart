// Builds the real Flutter application with isolated, fictional data for native UI comparison.
// Requires ORG_GRADLE_PROJECT_nativeParityReference=true; refuses the shipping app's storage path.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:clipy_flutter/app/bootstrap.dart';
import 'package:clipy_flutter/database/app_database.dart';
import 'package:clipy_flutter/database/clipboard_repository.dart';
import 'package:clipy_flutter/models.dart';
import 'package:clipy_flutter/storage_paths.dart';
import 'package:clipy_flutter/sync_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep the normal default-main font registration path from bootstrapApplication.
  runApp(const SizedBox.shrink());
  final directory = await StoragePaths.appStorageDirectory();
  if (!Platform.isAndroid ||
      !directory.path.contains('/com.clipyclone.clipy_android.reference/')) {
    throw StateError('UI reference must use the isolated .reference package');
  }
  const language = String.fromEnvironment(
    'PARITY_LANGUAGE',
    defaultValue: 'en',
  );
  const dark = bool.fromEnvironment('PARITY_DARK');
  const empty = bool.fromEnvironment('PARITY_EMPTY');
  const older = bool.fromEnvironment('PARITY_OLDER');
  const notifications = bool.fromEnvironment('PARITY_NOTIFICATIONS');
  const p1Fixtures = bool.fromEnvironment('PARITY_P1_FIXTURES');
  final epoch = DateTime.now().millisecondsSinceEpoch;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('appLanguage', language);
  await prefs.setString('appearance', dark ? 'dark' : 'light');
  await prefs.setBool('syncEnabled', false);
  await prefs.setBool('notificationSyncEnabled', false);
  await prefs.setBool('syncRelayEnabled', false);
  await prefs.setInt('dbMigrationVersion', 1);
  await prefs.setString('deviceName', 'Android');
  await prefs.setInt('syncPort', 5566);
  await prefs.setStringList('clipboardSyncPeerIds', []);
  await prefs.setStringList('notificationSyncPeerIds', []);
  await prefs.setStringList('authorizedPeerIds', []);
  await prefs.setStringList('manualSyncPeers', []);
  await prefs.setString('clipy.peerEndpoints.v2', '[]');
  final database = await AppDatabase.instance.database;
  for (final table in [
    'clipboard_history',
    'notifications',
    'file_transfers',
    'app_logs',
    'pending_notification_sync',
    'pending_text_sync',
    'pending_sync',
  ]) {
    await database.delete(table);
  }
  if (!empty) {
    final examples = [
      (
        language == 'zh'
            ? '为每一次复制，保留一份安心。'
            : 'Everything you copied. Within reach.',
        'Example Notes',
        epoch,
      ),
      ('https://example.com/clipy', 'Example Browser', epoch - 60000),
      if (older)
        ('An older saved note.', 'Example Notes', epoch - 3 * 24 * 3600 * 1000),
    ];
    for (final (text, source, timestamp) in examples) {
      await ClipboardRepository.instance.insert(
        HistoryEntry(
          item: HistoryItem(type: 'text', value: text),
          date: DateTime.fromMillisecondsSinceEpoch(timestamp),
          sourceApp: source,
          contentHash: sha256.convert(utf8.encode(text)).toString(),
        ),
      );
    }
  }
  if (notifications) {
    await prefs.setStringList('notificationCollectedPackages', [
      'org.example.parity.notes',
    ]);
    await prefs.setStringList('notificationSyncedPackages', [
      'org.example.parity.notes',
    ]);
    for (var index = 0; index < 2; index++) {
      await database.insert('notifications', {
        'id': 'parity-notification-$index',
        'notification_key': 'parity-key-$index',
        'package_name': 'org.example.parity.notes',
        'app_name': 'Example Notes',
        'title': 'Synthetic notification ${index + 1}',
        'subtitle': 'Fixture subtitle',
        'body': List.generate(
          index == 0 ? 30 : 1,
          (line) => 'Synthetic notification detail line ${line + 1}',
        ).join('\n'),
        'post_time': epoch - index * 60000,
        'is_clearable': 1,
        'is_archived': index,
        'sync_state': index,
        'extras_json': '{}',
      });
    }
  }
  if (p1Fixtures) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 400, 200),
      Paint()..color = const Color(0xFF193967),
    );
    canvas.drawCircle(
      const Offset(100, 100),
      60,
      Paint()..color = const Color(0xFFABC7FF),
    );
    canvas.drawRect(
      const Rect.fromLTWH(220, 40, 120, 120),
      Paint()..color = const Color(0xFFF2C36B),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(400, 200);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final media = File('${directory.path}/parity-media.png');
    await media.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    for (final item in [
      HistoryItem(type: 'image', value: media.path),
      HistoryItem(
        type: 'fileURLs',
        value: ['/synthetic/alpha.txt', '/synthetic/beta.pdf'],
      ),
    ]) {
      await ClipboardRepository.instance.insert(
        HistoryEntry(
          item: item,
          date: DateTime.fromMillisecondsSinceEpoch(
            epoch + (item.type == 'image' ? 2000 : 1000),
          ),
          sourceApp: 'Parity Media',
          contentHash: 'parity-${item.type}',
        ),
      );
    }
    for (var index = 0; index < 3; index++) {
      await database.insert('app_logs', {
        'level': 'INFO',
        'message': 'Synthetic parity log ${index + 1}',
        'created_at': epoch + index,
      });
    }
  }
  await bootstrapApplication();
  if (p1Fixtures) {
    SyncManager.instance.diagnostics.noteError(
      'parity-diagnostic-peer',
      'Synthetic connection error',
      name: 'Parity diagnostic peer',
      host: '192.0.2.10',
    );
  }
  await File('${directory.path}/ui-parity-fixture.json').writeAsString(
    jsonEncode({
      'epoch': epoch,
      'language': language,
      'dark': dark,
      'empty': empty,
      'older': older,
      'notifications': notifications,
      'p1Fixtures': p1Fixtures,
    }),
  );
}
