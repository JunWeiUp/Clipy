import 'package:clipy_flutter/features/history/history_feed_controller.dart';
import 'package:clipy_flutter/models.dart';
import 'package:clipy_flutter/ui/clipboard_history_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows history selects and previews the actual entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entries = [
      HistoryEntry(
        item: HistoryItem(type: 'text', value: 'First clipboard item'),
        date: DateTime(2026, 1, 2),
        sourceApp: 'Editor',
        contentHash: 'first',
      ),
      HistoryEntry(
        item: HistoryItem(type: 'text', value: 'Second clipboard item'),
        date: DateTime(2026, 1, 1),
        sourceApp: 'Browser',
        contentHash: 'second',
      ),
    ];
    final feed = HistoryFeedController(
      ({
        required offset,
        required limit,
        required query,
        required filter,
      }) async => offset == 0 ? entries : [],
    );
    addTearDown(feed.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en', 'US'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: PaginatedClipboardHistoryList(
            controller: feed,
            windowsLayout: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('First clipboard item'), findsNWidgets(2));
    expect(find.textContaining('Editor ·'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    await tester.tap(find.text('Second clipboard item'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Second clipboard item'), findsNWidgets(2));
    expect(find.textContaining('Browser ·'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
  });
}
