import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/features/devices/mac_screen_controls.dart';
import 'package:clipy_flutter/sync_manager.dart';

void main() {
  testWidgets(
    'controls require configuration; helper and actual state gate unlock',
    (tester) async {
      final states = SyncManager.instance.macScreens;
      addTearDown(() => states.value = {});
      states.value = {
        'mac': const MacScreenState(
          configured: false,
          locked: false,
          helper: false,
          challenge: 'n',
        ),
      };
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MacScreenControls(peerId: 'mac')),
        ),
      );
      expect(find.text('Mac unlocked'), findsOneWidget);
      expect(find.text('Lock'), findsNothing);
      expect(find.text('Unlock'), findsNothing);
      states.value = {
        'mac': const MacScreenState(
          configured: true,
          locked: true,
          helper: false,
          challenge: 'n',
        ),
      };
      await tester.pump();
      expect(find.text('Mac locked'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Unlock'),
            )
            .onPressed,
        isNull,
      );
      states.value = {
        'mac': const MacScreenState(
          configured: true,
          locked: true,
          helper: true,
          challenge: 'n',
        ),
      };
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Unlock'),
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('Control key'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Unlock'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Device disconnected'), findsOneWidget);
      states.value = {};
      await tester.pump();
      expect(find.text('Mac locked'), findsNothing);
      expect(find.text('Unlock'), findsNothing);
    },
  );
}
