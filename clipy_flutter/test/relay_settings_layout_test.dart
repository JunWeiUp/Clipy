import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/relay_settings.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStore = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const deviceId = '531642cd-5d49-4ab6-a0c8-df95a3934b44';

  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'expanded relay form: $language, $brightness, narrow/large text',
        (tester) async {
          tester.view.physicalSize = const Size(320, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          SharedPreferences.setMockInitialValues({
            'appLanguage': language,
            'syncRelayDeviceId': deviceId,
          });
          await AppLanguageController.instance.init();
          var writes = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(secureStore, (call) async {
                if (call.method == 'write') writes++;
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(secureStore, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ClipyTheme.build(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: const SingleChildScrollView(
                  // Match the real Devices page: the parent stores its offset.
                  key: PageStorageKey('devices-page'),
                  padding: EdgeInsets.all(16),
                  child: RelaySettings(),
                ),
                bottomNavigationBar: NavigationBar(
                  selectedIndex: 1,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.history),
                      label: 'History',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.devices),
                      label: 'Devices',
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final id = find.byKey(const PageStorageKey('relay-device-id'));
          await tester.ensureVisible(id);
          await tester.pumpAndSettle();
          final editable = tester
              .state<EditableTextState>(
                find.descendant(of: id, matching: find.byType(EditableText)),
              )
              .renderEditable;
          final boxes = editable.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: deviceId.length),
          );
          expect(
            boxes.map((box) => box.top).toSet().length,
            greaterThan(1),
            reason: 'the whole ID wraps instead of being clipped horizontally',
          );

          final section = find.text(
            language == 'zh' ? '首次接入 / 更新信任配置' : 'Enrollment / trusted peers',
          );
          final enrollment = find.byKey(
            const PageStorageKey('relay-enrollment-input'),
          );
          for (var cycle = 0; cycle < 2; cycle++) {
            await tester.ensureVisible(section);
            await tester.tap(section);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byType(ErrorWidget), findsNothing);
            await tester.ensureVisible(enrollment);
            await tester.enterText(enrollment, 'fixture-enrollment');
            tester.view.viewInsets = const FakeViewPadding(bottom: 280);
            await tester.pumpAndSettle();
            await tester.ensureVisible(enrollment);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(tester.getSize(enrollment).height, lessThan(320));
            tester.view.resetViewInsets();
            tester.testTextInput.hide();
            FocusManager.instance.primaryFocus?.unfocus();
            await tester.pumpAndSettle();
            await tester.ensureVisible(section);
            await tester.tap(section);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(section);
          await tester.tap(section);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(enrollment).controller!.text,
            'fixture-enrollment',
          );
          final save = find.byType(FilledButton);
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          expect(
            tester.getBottomRight(save).dy,
            lessThanOrEqualTo(tester.getTopLeft(find.byType(NavigationBar)).dy),
          );
          expect(tester.takeException(), isNull);
          expect(
            writes,
            0,
            reason: 'editing and expanding must not save credentials',
          );
        },
      );
    }
  }
}
