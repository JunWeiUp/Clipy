import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:clipy_android/database/clipboard_repository.dart';
import 'package:clipy_android/models.dart';

void main() {
  late Database db;
  late ClipboardRepository repository;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''CREATE TABLE clipboard_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT, content_hash TEXT UNIQUE,
      item_type TEXT NOT NULL, item_value TEXT NOT NULL,
      source_app TEXT, created_at INTEGER NOT NULL)''');
    repository = ClipboardRepository.forDatabase(db);
  });
  tearDown(() => db.close());
  HistoryEntry entry(String value, int date) => HistoryEntry(
    item: HistoryItem(type: 'text', value: value),
    contentHash: 'same-hash',
    date: DateTime.fromMillisecondsSinceEpoch(date),
  );

  test('repeated copy replaces the row and refreshes its date', () async {
    await repository.insert(entry('old', 1));
    await repository.insert(entry('new', 2));
    expect(await repository.count(), 1);
    expect((await repository.latestEntry())!.item.value, 'new');
    expect((await repository.latestEntry())!.date.millisecondsSinceEpoch, 2);
  });
  test(
    'search filters the full database before paging and escapes LIKE wildcards',
    () async {
      for (var i = 0; i < 65; i++) {
        await repository.insert(
          HistoryEntry(
            item: HistoryItem(
              type: 'text',
              value: i == 0 ? "100%_done 'quoted'" : 'note $i',
            ),
            contentHash: 'hash-$i',
            sourceApp: i == 1 ? 'Mail' : 'Notes',
            date: DateTime.fromMillisecondsSinceEpoch(i),
          ),
        );
      }
      final found = await repository.fetchPage(
        offset: 0,
        limit: 2,
        query: "100%_done 'quoted'",
      );
      expect(found.single.item.value, "100%_done 'quoted'");
      expect(
        await repository.fetchPage(offset: 0, limit: 2, query: '100%_missing'),
        isEmpty,
      );
      expect(
        (await repository.fetchPage(
          offset: 0,
          limit: 2,
          query: 'mail',
        )).single.sourceApp,
        'Mail',
      );
    },
  );

  test('file and link filters are applied before the result limit', () async {
    await repository.insert(
      HistoryEntry(
        item: HistoryItem(type: 'fileURL', value: '/downloads/readme.txt'),
        date: DateTime(2026),
        contentHash: 'file',
      ),
    );
    await repository.insert(
      HistoryEntry(
        item: HistoryItem(type: 'text', value: 'https://example.com'),
        date: DateTime(2026, 2),
        contentHash: 'link',
      ),
    );
    await repository.insert(
      HistoryEntry(
        item: HistoryItem(type: 'text', value: 'ordinary text'),
        date: DateTime(2026, 3),
        contentHash: 'text',
      ),
    );
    expect(
      (await repository.fetchPage(
        offset: 0,
        limit: 1,
        filter: 'files',
      )).single.item.type,
      'fileURL',
    );
    expect(
      (await repository.fetchPage(
        offset: 0,
        limit: 1,
        filter: 'links',
      )).single.contentHash,
      'link',
    );
    expect(
      await repository.fetchPage(offset: 0, limit: 1, filter: 'images'),
      isEmpty,
    );
  });
  test('failed insert rolls back deletion of the existing record', () async {
    await repository.insert(entry('old', 1));
    await db.execute(
      """CREATE TRIGGER reject_new BEFORE INSERT ON clipboard_history
      WHEN NEW.item_value = 'new' BEGIN SELECT RAISE(ABORT, 'injected failure'); END""",
    );
    await expectLater(
      repository.insert(entry('new', 2)),
      throwsA(isA<DatabaseException>()),
    );
    expect(await repository.count(), 1);
    expect((await repository.latestEntry())!.item.value, 'old');
  });
  test(
    'concurrent copies with the same hash remain one complete row',
    () async {
      await Future.wait(
        List.generate(30, (i) => repository.insert(entry('$i', i))),
      );
      expect(await repository.count(), 1);
      final last = (await repository.latestEntry())!;
      expect(last.item.value, '${last.date.millisecondsSinceEpoch}');
    },
  );
}
