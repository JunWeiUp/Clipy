import 'package:clipy_flutter/sync_manager.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:clipy_flutter/features/devices/relay_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStore = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  testWidgets(
    'mounting or remounting relay settings never saves or restarts sync',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'syncRelayURL': 'wss://example.com/relay/v1/ws',
        'syncRelayEnabled': false,
      });
      var secureWrites = 0;
      var saves = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStore, (call) async {
            if (call.method == 'write') secureWrites++;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(secureStore, null),
      );
      for (var index = 0; index < 2; index++) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ClipyTheme.build(Brightness.dark),
            home: Scaffold(
              body: SingleChildScrollView(
                key: const PageStorageKey('devices-page'),
                child: RelaySettings(
                  key: ValueKey(index),
                  onSettingsChanged: () => saves++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(ExpansionTile));
        await tester.tap(find.byType(ExpansionTile));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
      }
      await SyncManager.instance.updateRelaySettings(
        enabled: false,
        url: 'wss://example.com/relay/v1/ws',
        token: '',
      );
      expect(
        secureWrites,
        0,
        reason: 'reading fields must not write credentials',
      );
      expect(
        saves,
        0,
        reason: 'loading relay settings must not restart LAN discovery',
      );
    },
  );
}
