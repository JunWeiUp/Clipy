import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/home_page.dart';
import 'package:clipy_flutter/features/history/history_feed_controller.dart';
import 'package:clipy_flutter/features/history/windows_quick_panel.dart';
import 'package:clipy_flutter/features/settings/windows_settings_page.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'settings never leaks into quick panel; opening main preserves its module',
    (tester) async {
      SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
      await AppLanguageController.instance.init();
      await tester.binding.setSurfaceSize(const Size(1088, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const channel = MethodChannel('com.clipyclone.clipy_android/tray');
      const codec = StandardMethodCodec();
      var nativeMode = 'main';
      void emit(String mode) {
        nativeMode = mode;
        tester.binding.channelBuffers.push(
          channel.name,
          codec.encodeMethodCall(MethodCall('windowMode', mode)),
          (_) {},
        );
      }

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'getWindowMode') return nativeMode;
        if (call.method == 'getWindowsBehavior') return {'startup': false};
        if (call.method == 'getHotkeys') return <String, dynamic>{};
        if (call.method == 'getFirewallStatus') return -1;
        if (call.method == 'dismissQuickPanel' ||
            call.method == 'openMainWindow') {
          emit('main');
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final feed = HistoryFeedController(
        ({
          required offset,
          required limit,
          required query,
          required filter,
        }) async => [],
      );
      addTearDown(feed.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ClipyTheme.windows(Brightness.light),
          home: HomePage(windowsLayout: true, historyController: feed),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      expect(find.byType(WindowsSettingsPage), findsOneWidget);
      emit('quick');
      await tester.pumpAndSettle();
      expect(find.byType(WindowsQuickPanel), findsOneWidget);
      expect(find.byType(WindowsSettingsPage), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text('Open main window').last);
      await tester.pumpAndSettle();
      expect(find.byType(WindowsSettingsPage), findsOneWidget);
      expect(find.byType(WindowsQuickPanel), findsNothing);
      emit('quick');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide panel'));
      await tester.pumpAndSettle();
      expect(find.byType(WindowsQuickPanel), findsNothing);
      emit('quick');
      await tester.pumpAndSettle();
      expect(find.byType(WindowsQuickPanel), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
