import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/devices_page.dart';
import 'package:clipy_flutter/sync/discovery_scan.dart';
import 'package:clipy_flutter/sync_manager.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('cancelling discovery preserves sync enabled and progress count', () {
    final manager = SyncManager.instance;
    final enabled = manager.isEnabled;
    manager.isEnabled = true;
    manager.discoveryProgress.value = const DiscoveryProgress(
      running: true,
      completed: 12,
      total: 254,
    );
    manager.cancelDiscovery();
    expect(manager.discoveryProgress.value.running, isFalse);
    expect(manager.discoveryProgress.value.completed, 12);
    expect(manager.isEnabled, isTrue);
    manager.isEnabled = enabled;
    manager.discoveryProgress.value = const DiscoveryProgress();
  });

  testWidgets(
    'Windows shows manual address and toolbar opens validated IP dialog directly',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'appLanguage': 'en',
        'manualSyncPeers': ['10.8.0.23:5566'],
      });
      await AppLanguageController.instance.init();
      final manager = SyncManager.instance;
      final enabled = manager.isEnabled;
      final clipboard = manager.clipboardSyncPeerIds;
      manager.isEnabled = false;
      manager.clipboardSyncPeerIds = ['offline'];
      addTearDown(() {
        manager.isEnabled = enabled;
        manager.clipboardSyncPeerIds = clipboard;
      });
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ClipyTheme.windows(Brightness.light),
          home: const Scaffold(body: DevicesPage(windowsLayout: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Offline · 1'), findsOneWidget);
      expect(find.text('10.8.0.23:5566'), findsOneWidget);
      manager.isEnabled = true;
      manager.connectionRevision.value++;
      await tester.pump();
      await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.add));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      await tester.enterText(find.byType(TextFormField).first, '999.1.1.1');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
