import 'dart:io';
import 'dart:ui' as ui;
import 'package:clipy_flutter/features/history/history_feed_controller.dart';
import 'package:clipy_flutter/models.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:clipy_flutter/ui/clipboard_history_list.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['CLIPY_VISUAL_FONT'] case final String path) {
      final data = ByteData.sublistView(await File(path).readAsBytes());
      for (final family in [
        'Ahem',
        'Roboto',
        '.SF Pro Text',
        '.SF Pro Display',
        'Segoe UI',
      ]) {
        await (FontLoader(family)..addFont(Future.value(data))).load();
      }
      for (final font in [
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        (
          'packages/cupertino_icons/CupertinoIcons',
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
        ),
      ]) {
        await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
      }
    }
  });
  for (final platform in ['android', 'ios', 'windows']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '$platform ${brightness.name} scale $scale: search, clear and long content',
          (tester) async {
            final desktop = platform == 'windows';
            await tester.binding.setSurfaceSize(
              desktop ? const Size(1088, 680) : const Size(393, 760),
            );
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final entries = [
              HistoryEntry(
                item: HistoryItem(
                  type: 'text',
                  value:
                      'Design review: confirm the search flow and device sharing.\nKeep the keyboard path accessible.',
                ),
                date: DateTime(2026, 1, 2, 15, 41),
                sourceApp: 'Notes on Mac',
                contentHash: 'a',
              ),
              HistoryEntry(
                item: HistoryItem(
                  type: 'text',
                  value: 'https://example.com/design/clipy',
                ),
                date: DateTime(2026, 1, 2, 15, 36),
                sourceApp: 'Browser',
                contentHash: 'b',
              ),
              HistoryEntry(
                item: HistoryItem(
                  type: 'text',
                  value: List.filled(120, '长内容与 Large text').join(' '),
                ),
                date: DateTime(2026, 1, 1, 18, 2),
                sourceApp: 'A long application name that should not overflow',
                contentHash: 'c',
              ),
            ];
            final feed = HistoryFeedController(
              ({
                required offset,
                required limit,
                required query,
                required filter,
              }) async => offset > 0
                  ? []
                  : entries
                        .where((e) => e.item.value.toString().contains(query))
                        .toList(),
            );
            addTearDown(feed.dispose);
            final theme = desktop
                ? ClipyTheme.windows(brightness)
                : platform == 'ios'
                ? ClipyTheme.ios(brightness)
                : ClipyTheme.build(brightness);
            final filters = ValueNotifier<String>('all');
            addTearDown(filters.dispose);
            final captureKey = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                locale: const Locale('en', 'US'),
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                home: RepaintBoundary(
                  key: captureKey,
                  child: Scaffold(
                    body: SafeArea(
                      child: PaginatedClipboardHistoryList(
                        controller: feed,
                        filterNotifier: filters,
                        windowsLayout: desktop,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (Platform.environment['CLIPY_VISUAL_DIR']
                case final String directory) {
              final boundary =
                  captureKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 1);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(directory).create(recursive: true);
                await File(
                  '$directory/$platform-history-${brightness.name}-$scale.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            if (!desktop) {
              await tester.longPress(
                find.textContaining('Design review:').first,
              );
              await tester.pumpAndSettle();
              expect(find.byType(SelectableText), findsOneWidget);
              if (platform == 'ios') {
                expect(find.byType(CupertinoPopupSurface), findsOneWidget);
                expect(find.byType(CupertinoButton), findsNWidgets(3));
              }
              expect(tester.takeException(), isNull);
              await tester.tapAt(const Offset(10, 10));
              await tester.pumpAndSettle();
            }
            final input = platform == 'ios'
                ? find.byType(CupertinoSearchTextField)
                : find.byType(TextField);
            await tester.enterText(input, 'no matching record');
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pumpAndSettle();
            expect(feed.entries, isEmpty);
            await tester.enterText(input, '');
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pumpAndSettle();
            expect(feed.entries.length, 3);
            filters.value = 'links';
            await tester.pumpAndSettle();
            expect(feed.filter, 'links');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
