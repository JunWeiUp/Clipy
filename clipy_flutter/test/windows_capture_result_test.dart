import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/windows_capture_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('capture result exposes preview and action callbacks', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
    await AppLanguageController.instance.init();
    await tester.binding.setSurfaceSize(const Size(360, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsCaptureResult(
          path: '/nonexistent/screenshot.png',
          copied: true,
          onClose: () => actions.add('close'),
          onSave: () => actions.add('save'),
          onReveal: () => actions.add('reveal'),
          onSend: () => actions.add('send'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('Save as'));
    await tester.tap(find.text('Open folder'));
    await tester.tap(find.text('Send'));
    await tester.tap(find.byTooltip('Close'));
    expect(actions, ['save', 'reveal', 'send', 'close']);
    expect(tester.takeException(), isNull);
  });
}
