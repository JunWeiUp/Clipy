import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/clipboard_manager.dart';
import 'package:clipy_flutter/features/settings/windows_settings_page.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:clipy_flutter/ui/windows_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Windows settings saves exclusions and opens existing actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
    const tray = MethodChannel('com.clipyclone.clipy_android/tray');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          tray,
          (call) async => call.method == 'getFirewallStatus'
              ? 1
              : call.method == 'getWindowsBehavior'
              ? {'startup': false, 'closeExits': false, 'trayOpensMain': false}
              : call.method == 'setWindowsBehavior'
              ? true
              : call.method == 'getHotkeys'
              ? {
                  'history': true,
                  'screenshot': false,
                  'historyModifiers': 6,
                  'historyKey': 86,
                  'screenshotModifiers': 6,
                  'screenshotKey': 65,
                }
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(tray, null),
    );
    await AppLanguageController.instance.init();
    final oldExcluded = List<String>.of(ClipboardManager.instance.excludedApps);
    addTearDown(
      () => ClipboardManager.instance.updateExcludedApps(oldExcluded),
    );
    var openedLogs = false;
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ClipyTheme.windows(Brightness.light),
        home: Scaffold(
          body: WindowsSettingsPage(
            onOpenLogs: () => openedLogs = true,
            onOpenReceivedFiles: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'secret.exe\nother.exe');
    await tester.tap(find.text('Save Excluded Apps'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getStringList('excludedApps'),
      ['secret.exe', 'other.exe'],
    );
    await tester.tap(find.text('General').first);
    await tester.pumpAndSettle();
    expect(find.text('Start Clipy when signing in'), findsOneWidget);
    expect(find.textContaining('Firewall is enabled'), findsOneWidget);
    await tester.tap(find.byType(WindowsToggle).first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<WindowsToggle>(find.byType(WindowsToggle).first).value,
      isTrue,
    );
    expect(find.text('Active'), findsOneWidget);
    expect(
      find.text('Unavailable; another application may use it'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Edit shortcut').first);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.text('Shortcut is in use; the previous shortcut remains active'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('View Logs'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('View Logs'));
    expect(openedLogs, isTrue);
    expect(tester.takeException(), isNull);
  });
}
