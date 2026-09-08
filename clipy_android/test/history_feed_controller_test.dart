import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/features/history/history_feed_controller.dart';
import 'package:clipy_android/models.dart';

HistoryEntry entry(String value) => HistoryEntry(
  item: HistoryItem(type: 'text', value: value),
  contentHash: value,
  date: DateTime(2026, 9, 8),
);

void main() {
  test('refresh retains the extent of already loaded pages', () async {
    var calls = 0;
    final limits = <int>[];
    final feed = HistoryFeedController(pageSize: 2, ({
      required offset,
      required limit,
      required query,
      required filter,
    }) async {
      limits.add(limit);
      calls++;
      if (calls == 1) return [entry('a'), entry('b')];
      if (calls == 2) return [entry('c'), entry('d')];
      return [entry('new'), entry('a'), entry('b'), entry('c')];
    });
    addTearDown(feed.dispose);
    await feed.refresh();
    await feed.loadMore();
    await feed.refresh();
    expect(limits, [2, 2, 4]);
    expect(feed.entries.length, 4);
    expect(feed.entries.first.item.value, 'new');
    expect(feed.hasMore, isTrue);
  });
  test(
    'a search during loading discards stale results and loads the newest query',
    () async {
      final first = Completer<List<HistoryEntry>>();
      final requests = <String>[];
      final feed = HistoryFeedController(({
        required offset,
        required limit,
        required query,
        required filter,
      }) {
        requests.add(query);
        return requests.length == 1
            ? first.future
            : Future.value([entry(query)]);
      });
      addTearDown(feed.dispose);
      final loading = feed.refresh();
      unawaited(feed.search('new', 'text'));
      unawaited(feed.search('newest', 'text'));
      first.complete([entry('stale')]);
      await loading;
      expect(requests, ['', 'newest']);
      expect(feed.entries.single.item.value, 'newest');
      expect(feed.loading, isFalse);
    },
  );

  test(
    'refresh during pagination restarts at zero and preserves new order',
    () async {
      final pagination = Completer<List<HistoryEntry>>();
      final offsets = <int>[];
      final feed = HistoryFeedController(pageSize: 2, ({
        required offset,
        required limit,
        required query,
        required filter,
      }) {
        offsets.add(offset);
        if (offsets.length == 1) return Future.value([entry('a'), entry('b')]);
        if (offsets.length == 2) return pagination.future;
        return Future.value([entry('b'), entry('a')]);
      });
      addTearDown(feed.dispose);
      await feed.refresh();
      final loading = feed.loadMore();
      unawaited(feed.refresh());
      pagination.complete([entry('c')]);
      await loading;
      expect(offsets, [0, 2, 0]);
      expect(feed.entries.map((e) => e.item.value), ['b', 'a']);
    },
  );

  test('failed fetch leaves saved rows visible and can retry', () async {
    var fail = false;
    final feed = HistoryFeedController(({
      required offset,
      required limit,
      required query,
      required filter,
    }) async {
      if (fail) throw StateError('database unavailable');
      return [entry('saved')];
    });
    addTearDown(feed.dispose);
    await feed.refresh();
    fail = true;
    await feed.refresh();
    expect(feed.failed, isTrue);
    expect(feed.entries.single.item.value, 'saved');
    expect(feed.loading, isFalse);
    fail = false;
    await feed.refresh();
    expect(feed.failed, isFalse);
  });

  test(
    'disposing an in-flight query prevents publishing or notifying',
    () async {
      final result = Completer<List<HistoryEntry>>();
      final feed = HistoryFeedController(
        ({required offset, required limit, required query, required filter}) =>
            result.future,
      );
      var notifications = 0;
      feed.addListener(() => notifications++);
      final loading = feed.refresh();
      feed.dispose();
      result.complete([entry('late')]);
      await loading;
      expect(notifications, 1);
      expect(feed.entries, isEmpty);
    },
  );
}
