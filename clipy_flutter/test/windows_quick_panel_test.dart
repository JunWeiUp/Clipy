import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/history_feed_controller.dart';
import 'package:clipy_flutter/features/history/windows_quick_panel.dart';
import 'package:clipy_flutter/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('quick panel filters, copies, and opens full history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
    await AppLanguageController.instance.init();
    final entries = [
      HistoryEntry(
        item: HistoryItem(type: 'text', value: 'Test text'),
        date: DateTime(2026),
        contentHash: 'text',
      ),
      HistoryEntry(
        item: HistoryItem(type: 'image', value: '/example.png'),
        date: DateTime(2026),
        contentHash: 'image',
      ),
    ];
    final feed = HistoryFeedController(
      ({
        required offset,
        required limit,
        required query,
        required filter,
      }) async => entries
          .where(
            (e) =>
                (filter == 'all' ||
                    (filter == 'text' && e.item.type == 'text') ||
                    (filter == 'images' && e.item.type == 'image')) &&
                e.item.title.toLowerCase().contains(query.toLowerCase()),
          )
          .skip(offset)
          .take(limit)
          .toList(),
    );
    addTearDown(feed.dispose);
    HistoryEntry? copied;
    var opened = false;
    var closed = false;
    var pinned = false;
    var pasted = false;
    await tester.binding.setSurfaceSize(const Size(400, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsQuickPanel(
          controller: feed,
          copy: (entry) async => copied = entry,
          paste: () async {
            pasted = true;
            return true;
          },
          setPinned: (value) async => pinned = value,
          onOpenFull: () => opened = true,
          onClose: () => closed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test text'));
    await tester.pumpAndSettle();
    expect(copied?.contentHash, 'text');
    expect(pasted, isTrue);
    pasted = false;
    await tester.tap(find.byTooltip('Copy Content').first);
    await tester.pumpAndSettle();
    expect(pasted, isFalse);
    expect(copied?.contentHash, 'text');
    await tester.tap(find.byTooltip('Pin panel'));
    await tester.pump();
    expect(pinned, isTrue);
    expect(find.byTooltip('Unpin panel'), findsOneWidget);
    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.text('Test text'), findsNothing);
    expect(find.text('[Image]'), findsOneWidget);
    await tester.tap(find.text('Open main window').last);
    expect(opened, isTrue);
    await tester.tap(find.byTooltip('Hide panel'));
    expect(closed, isTrue);
    closed = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
