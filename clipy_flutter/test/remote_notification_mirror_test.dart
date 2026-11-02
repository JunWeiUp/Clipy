import 'dart:convert';

import 'package:clipy_flutter/database/notification_repository.dart';
import 'package:clipy_flutter/models.dart';
import 'package:clipy_flutter/notification_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late NotificationRepository repository;
  late NotificationManager manager;
  late List<String> acknowledgements;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE notifications (
        id TEXT PRIMARY KEY,
        notification_key TEXT,
        package_name TEXT NOT NULL,
        app_name TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        body TEXT NOT NULL,
        post_time INTEGER NOT NULL,
        group_key TEXT,
        is_clearable INTEGER NOT NULL DEFAULT 1,
        is_archived INTEGER NOT NULL DEFAULT 0,
        sync_state INTEGER NOT NULL DEFAULT 0,
        extras_json TEXT NOT NULL DEFAULT '{}',
        synced_at INTEGER
      )
    ''');
    repository = NotificationRepository.forDatabase(db);
    acknowledgements = [];
    manager = NotificationManager.forTesting(
      repository: repository,
      acknowledge: (hash, peerId) => acknowledgements.add('$peerId:$hash'),
    );
  });

  tearDown(() => db.close());

  NotificationEntry entry(
    String id, {
    String packageName = 'com.example.chat',
    String? key,
    String? group,
  }) => NotificationEntry(
    id: id,
    notificationKey: key,
    packageName: packageName,
    appName: packageName,
    title: id,
    body: 'Message $id',
    postTime: 1000,
    groupKey: group,
  );

  test(
    'Windows source metadata does not turn an empty post into content',
    () async {
      final result = await repository.upsert(
        NotificationEntry(
          id: 'empty',
          packageName: 'example.app',
          appName: 'Example',
          title: '',
          body: '',
          postTime: 1,
          extras: {
            'clipyWindowsSourceId': 'peer',
            'clipyWindowsSourceName': 'Phone',
            'clipyWindowsReceivedAt': 1234,
            'clipyWindowsRead': false,
          },
        ),
      );
      expect(result.accepted, isFalse);
      expect(await repository.count(), 0);
    },
  );

  test(
    'remote post is stored before ACK and duplicate delivery is ACKed',
    () async {
      final post = jsonEncode(entry('post-1', key: 'chat-1').toJson());
      await manager.handleRemoteNotification(post, 'android-peer');
      expect(await repository.count(), 1);
      expect(acknowledgements, ['android-peer:post-1']);

      await manager.handleRemoteNotification(post, 'android-peer');
      expect(await repository.count(), 1);
      expect(acknowledgements, ['android-peer:post-1', 'android-peer:post-1']);
    },
  );

  test('remote dismiss removes only the matching package and key', () async {
    await repository.upsert(entry('a', key: 'key-a'));
    await repository.upsert(
      entry('b', packageName: 'com.example.other', key: 'key-b'),
    );

    await manager.handleRemoteDismiss(
      jsonEncode({
        'packageName': 'com.example.chat',
        'notificationKey': 'key-b',
      }),
    );
    expect(await repository.count(), 2);

    await manager.handleRemoteDismiss(
      jsonEncode({'packageName': 'com.example.chat'}),
    );
    expect(await repository.count(), 2);

    await manager.handleRemoteDismiss(
      jsonEncode({
        'packageName': 'com.example.chat',
        'notificationKey': 'key-a',
      }),
    );
    expect(
      (await repository.fetchPage(offset: 0, limit: 10)).map((e) => e.id),
      ['b'],
    );
  });

  test(
    'remote group dismiss and clear update local mirrored history',
    () async {
      await repository.upsert(entry('a', key: 'key-a', group: 'group-1'));
      await repository.upsert(entry('b', key: 'key-b', group: 'group-1'));
      await repository.upsert(entry('c', key: 'key-c', group: 'group-2'));

      await manager.handleRemoteDismiss(
        jsonEncode({'packageName': 'com.example.chat', 'groupKey': 'group-1'}),
      );
      expect(
        (await repository.fetchPage(offset: 0, limit: 10)).map((e) => e.id),
        ['c'],
      );

      await manager.clearAll();
      expect(await repository.count(), 0);
    },
  );
  test(
    'Windows read state persists on the row and filters before paging',
    () async {
      for (var i = 0; i < 45; i++) {
        await repository.upsert(
          entry('item-$i', key: 'key-$i').copyWith(
            postTime: i,
            extras: {
              'clipyWindowsSourceId': 'phone',
              'clipyWindowsSourceName': 'Test phone',
              'clipyWindowsReceivedAt': DateTime.now().millisecondsSinceEpoch,
            },
          ),
        );
        if (i >= 3) await repository.markWindowsRead('item-$i');
      }
      final reopened = NotificationRepository.forDatabase(db);
      expect(
        (await reopened.fetchPage(
          offset: 0,
          limit: 2,
          unreadOnly: true,
        )).map((e) => e.id),
        ['item-2', 'item-1'],
      );
      expect(
        (await reopened.fetchPage(
          offset: 2,
          limit: 2,
          unreadOnly: true,
        )).map((e) => e.id),
        ['item-0'],
      );
      expect(
        (await reopened.fetchPage(
          offset: 0,
          limit: 40,
          query: 'item-1',
          unreadOnly: true,
        )).map((e) => e.id),
        ['item-1'],
      );
      final summary = (await reopened.windowsSourceSummary()).single;
      expect(summary['sourceId'], 'phone');
      expect(summary['sourceName'], 'Test phone');
      expect(summary['total'], 45);
      expect(summary['unread'], 3);
      expect(summary['today'], 45);
      await reopened.removeById('item-44');
      expect((await reopened.windowsSourceSummary()).single['total'], 44);
    },
  );

  test(
    'duplicate receipt preserves local read state, changed content is unread',
    () async {
      final original = entry('local', key: 'local-key').copyWith(
        extras: {'clipyWindowsSourceId': 'phone', 'clipyWindowsRead': false},
      );
      await repository.upsert(original);
      await repository.markWindowsRead(original.id);
      expect((await repository.upsert(original)).accepted, false);
      expect(
        await repository.fetchPage(offset: 0, limit: 10, unreadOnly: true),
        isEmpty,
      );
      await repository.upsert(original.copyWith(body: 'Changed message'));
      expect(
        (await repository.fetchPage(
          offset: 0,
          limit: 10,
          unreadOnly: true,
        )).single.body,
        'Changed message',
      );
    },
  );

  test(
    'notification search matches stored data and escapes SQL wildcards',
    () async {
      await repository.upsert(entry('literal%_value', key: 'a'));
      await repository.upsert(entry('literalXXvalue', key: 'b'));
      expect(
        (await repository.fetchPage(
          offset: 0,
          limit: 10,
          query: '%_',
        )).map((e) => e.id),
        ['literal%_value'],
      );
      expect(
        (await repository.fetchPage(
          offset: 0,
          limit: 10,
          query: 'example.chat',
        )).length,
        2,
      );
      expect(
        (await repository.fetchPage(
          offset: 0,
          limit: 1,
          query: 'literal',
        )).length,
        1,
      );
    },
  );
}
