import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/devices_page.dart';
import 'package:clipy_flutter/sync_manager.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'Windows devices shows offline authorized device and sync controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
      await AppLanguageController.instance.init();
      final manager = SyncManager.instance;
      final oldClipboard = manager.clipboardSyncPeerIds;
      final oldNotifications = manager.notificationSyncPeerIds;
      final oldEnabled = manager.isEnabled;
      manager.isEnabled = false;
      manager.clipboardSyncPeerIds = ['offline-device'];
      manager.notificationSyncPeerIds = [];
      addTearDown(() {
        manager.clipboardSyncPeerIds = oldClipboard;
        manager.notificationSyncPeerIds = oldNotifications;
        manager.isEnabled = oldEnabled;
      });
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ClipyTheme.windows(Brightness.light),
          home: const Scaffold(body: DevicesPage(windowsLayout: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsNWidgets(2));
      expect(find.text('Sync clipboard'), findsOneWidget);
      expect(find.text('Sync notifications'), findsOneWidget);
      final send = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send File…'),
      );
      expect(send.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
