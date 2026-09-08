import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/features/devices/devices_page.dart';
import 'package:clipy_android/features/settings/mobile_settings_content.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/ui/app_components.dart';
import 'package:clipy_android/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
    await AppLanguageController.instance.init();
    SyncManager.instance.isEnabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.clipyclone.clipy_android/widget'),
          (_) async => false,
        );
  });

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ClipyTheme.build(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'connection editor validates before changing the listening port',
    (tester) async {
      final original = SyncManager.instance.port;
      await mount(tester, const ConnectionEditor());
      await tester.enterText(find.byType(TextFormField).at(2), '70000');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
      expect(SyncManager.instance.port, original);
    },
  );

  testWidgets('settings fit a small dark screen with large text', (
    tester,
  ) async {
    await mount(
      tester,
      ListView(
        children: [
          MobileSettingsContent(onOpenLogs: () {}, onOpenReceivedFiles: () {}),
        ],
      ),
      scale: 1.6,
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView).first, const Offset(0, -440));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('destructive action can be cancelled without confirmation', (
    tester,
  ) async {
    bool? result;
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await confirmRemoval(
              context,
              title: 'Clear history',
              message: 'Permanent deletion',
            );
          },
          child: const Text('Open confirmation'),
        ),
      ),
    );
    await tester.tap(find.text('Open confirmation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
