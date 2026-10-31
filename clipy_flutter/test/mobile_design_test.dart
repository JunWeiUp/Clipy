import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/devices_page.dart';
import 'package:clipy_flutter/features/settings/mobile_settings_content.dart';
import 'package:clipy_flutter/sync_manager.dart';
import 'package:clipy_flutter/sync/discovery_scan.dart';
import 'package:clipy_flutter/features/devices/device_widgets.dart';
import 'package:clipy_flutter/ui/app_components.dart';
import 'package:clipy_flutter/ui/app_theme.dart';

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

  testWidgets('device scan progress survives page re-open and resets on stop', (
    tester,
  ) async {
    final progress = SyncManager.instance.discoveryProgress;
    addTearDown(() => progress.value = const DiscoveryProgress());
    await mount(tester, const SyncTargetDeviceList(), scale: 1.6);
    progress.value = const DiscoveryProgress(
      running: true,
      completed: 12,
      total: 64,
    );
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      12 / 64,
    );
    expect(find.textContaining('12/64'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SyncTargetDeviceList())),
    );
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    progress.value = const DiscoveryProgress();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'connection editor validates before changing the listening port',
    (tester) async {
      final original = SyncManager.instance.port;
      await mount(tester, const ConnectionEditor());
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Sync Port'),
        '70000',
      );
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

  testWidgets('device cards lead the page and sync controls expand on demand', (
    tester,
  ) async {
    final manager = SyncManager.instance;
    final original = manager.clipboardSyncPeerIds;
    manager.clipboardSyncPeerIds = ['layout-fixture'];
    addTearDown(() => manager.clipboardSyncPeerIds = original);
    await mount(
      tester,
      const DevicesPage(),
      scale: 1.6,
      brightness: Brightness.dark,
    );
    expect(
      find.byTooltip('Automatic sync settings').hitTestable(),
      findsOneWidget,
    );
    expect(find.byType(SwitchListTile).hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Automatic sync settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile).hitTestable(), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
