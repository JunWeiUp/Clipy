import 'dart:io';
import 'dart:ui' as ui;
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/home_page.dart';
import 'package:clipy_flutter/features/history/history_feed_controller.dart';
import 'package:clipy_flutter/models.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['CLIPY_VISUAL_FONT'];
    if (path != null) {
      final data = ByteData.sublistView(await File(path).readAsBytes());
      for (final family in ['Segoe UI', 'Ahem', 'Roboto']) {
        await (FontLoader(family)..addFont(Future.value(data))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'Windows full shell ${brightness.name}: header search and settings navigation',
      (tester) async {
        SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
        await AppLanguageController.instance.init();
        const tray = MethodChannel('com.clipyclone.clipy_android/tray');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(tray, (
          call,
        ) async {
          if (call.method == 'getWindowsBehavior') {
            return {
              'startup': false,
              'closeExits': false,
              'trayOpensMain': false,
            };
          }
          if (call.method == 'getFirewallStatus') return -1;
          if (call.method == 'getHotkeys') return <String, dynamic>{};
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            tray,
            null,
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1088, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final feed = HistoryFeedController(({
          required offset,
          required limit,
          required query,
          required filter,
        }) async {
          return offset > 0
              ? []
              : [
                  for (final value in [
                    'Quarterly review: improve onboarding',
                    'https://example.com/clipy',
                    'Design review notes',
                  ])
                    if (value.toLowerCase().contains(query.toLowerCase()))
                      HistoryEntry(
                        item: HistoryItem(type: 'text', value: value),
                        date: DateTime.now(),
                        sourceApp: 'Editor',
                        contentHash: value,
                      ),
                ];
        });
        addTearDown(feed.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ClipyTheme.windows(brightness),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: RepaintBoundary(
              key: key,
              child: HomePage(windowsLayout: true, historyController: feed),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Future<void> capture(String name) async {
          final dir = Platform.environment['CLIPY_VISUAL_DIR'];
          if (dir == null) return;
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(dir).create(recursive: true);
            await File(
              '$dir/shell-$name-${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('history');
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'quarterly');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(feed.query, 'quarterly');
        expect(feed.entries, hasLength(1));
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(feed.entries, hasLength(3));
        await tester.tap(find.text('Today').first);
        await tester.pumpAndSettle();
        expect(feed.filter, 'today');
        await tester.tap(find.text('Settings').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('General'), findsWidgets);
        await capture('settings');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
