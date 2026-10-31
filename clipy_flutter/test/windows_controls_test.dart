import 'package:clipy_flutter/ui/windows_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Fluent toggle supports pointer, keyboard and disabled semantics',
    (tester) async {
      var value = false;
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return WindowsToggle(
                  value: value,
                  label: 'Startup',
                  onChanged: enabled ? (v) => setState(() => value = v) : null,
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(WindowsToggle));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(value, isFalse);
      update(() => enabled = false);
      await tester.pump();
      await tester.tap(find.byType(WindowsToggle));
      expect(value, isFalse);
      expect(
        tester.getSemantics(find.byType(WindowsToggle)),
        matchesSemantics(
          label: 'Startup',
          hasToggledState: true,
          hasEnabledState: true,
        ),
      );
    },
  );
  testWidgets('Settings row stacks long labels and keycaps at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: WindowsSettingRow(
              title: 'Open the clipboard quick panel',
              subtitle:
                  'A long accessible description for the configured shortcut.',
              icon: Icons.keyboard,
              control: WindowsKeyCaps('Ctrl + Shift + V'),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Shift'), findsOneWidget);
  });
}
