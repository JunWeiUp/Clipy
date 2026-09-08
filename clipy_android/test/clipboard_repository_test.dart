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
