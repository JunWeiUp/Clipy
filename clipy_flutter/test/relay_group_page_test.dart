import 'dart:convert';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/relay_group_page.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';
import 'package:clipy_flutter/sync/relay_groups.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('empty saved relay URL uses the default creation server', () async {
    SharedPreferences.setMockInitialValues({'syncRelayURL': '  '});
    FlutterSecureStorage.setMockInitialValues({});
    expect(
      (await ClipyRelayGroups.load()).config['url'],
      'wss://eglish.top/relay/v1/ws',
    );
  });
  testWidgets(
    'managed group exposes leave and disband with explicit confirmation',
    (tester) async {
      await tester.runAsync(() async {
        await SodiumInit.init();
      });
      SharedPreferences.setMockInitialValues({'appLanguage': 'zh'});
      await AppLanguageController.instance.init();
      final state = {
        'version': 1,
        'app': 'clipy',
        'group': 'fixture',
        'revision': 1,
        'previous': '',
        'members': [
          {
            'device': 'mac',
            'name': 'Test Mac',
            'manager': true,
            'public_key': '01' * 32,
            'signing_key': '02' * 32,
          },
        ],
        'invitation': '',
        'request_hash': '',
      };
      FlutterSecureStorage.setMockInitialValues({
        'commonRelayConfig': jsonEncode({
          'url': 'wss://example.invalid/relay/v1/ws',
          'app': 'clipy',
          'group': 'fixture',
          'device': 'mac',
          'token': 't' * 32,
          'secret_key': '01' * 32,
          'trusted_peers': <String, String>{},
          'group_entry': {
            'payload': base64Encode(utf8.encode(jsonEncode(state))),
            'signature': '00' * 64,
            'signer': 'mac',
          },
        }),
      });
      await tester.pumpWidget(const MaterialApp(home: RelayGroupPage()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('解散设备组'), 200);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('解散设备组'));
      await tester.pumpAndSettle();
      expect(find.text('解散设备组'), findsOneWidget);
      await tester.tap(find.text('解散设备组'));
      await tester.pumpAndSettle();
      expect(find.text('解散整个设备组？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('Test Mac（本机）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'create/join layout $language $brightness narrow large text',
        (tester) async {
          await tester.runAsync(() async {
            await SodiumInit.init();
          });
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({'appLanguage': language});
          FlutterSecureStorage.setMockInitialValues({});
          await AppLanguageController.instance.init();
          await tester.pumpWidget(
            MaterialApp(
              theme: ClipyTheme.build(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const RelayGroupPage(),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(
              language == 'zh' ? '创建你的设备组' : 'Create your device group',
            ),
            findsOneWidget,
          );
          expect(find.byType(TextField), findsNWidgets(2));
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.text(language == 'zh' ? '加入已有组' : 'Join group'),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(language == 'zh' ? '加入已有设备组' : 'Join an existing group'),
            findsOneWidget,
          );
          expect(
            find.text(language == 'zh' ? '设备组名称' : 'Group name'),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
