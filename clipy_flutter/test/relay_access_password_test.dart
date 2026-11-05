import 'dart:convert';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/relay_settings.dart';
import 'package:clipy_flutter/sync/relay_configuration.dart';
import 'package:clipy_flutter/sync/relay_groups.dart';
import 'package:clipy_flutter/sync/relay_identity.dart';
import 'package:clipy_flutter/sync_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'wss://example.invalid/relay/v1/ws';
  const other = 'wss://other.invalid/relay/v1/ws';
  // Isolated test credential, never a deployed relay credential.
  const fixture = 'fixture-access-123';
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'syncRelayURL': url,
      'syncRelayDeviceId': 'phone',
      'appLanguage': 'en',
    });
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('password accepts exact ASCII bounds without trimming', () {
    for (final value in ['', '!' * 8, '~' * 128, fixture]) {
      expect(RelayConfiguration.validPassword(value), isTrue);
    }
    for (final value in [
      'a' * 7,
      'a' * 129,
      ' abcdefgh',
      'abcdefgh ',
      'abc defgh',
      'abcdefgh\n',
      'abcd\u007fefgh',
      '密码abcdefgh',
    ]) {
      expect(
        RelayConfiguration.validPassword(value),
        isFalse,
        reason: 'invalid boundary',
      );
    }
  });

  test(
    'secure credential is URL-bound and never read from enrollment',
    () async {
      await ClipyRelayIdentity.saveAccessPassword(
        'wss://EXAMPLE.invalid:443/relay/v1/ws',
        fixture,
      );
      expect(await ClipyRelayIdentity.accessPassword(url), fixture);
      expect(await ClipyRelayIdentity.accessPassword(other), '');
      expect(
        await ClipyRelayIdentity.accessPassword(
          'wss://example.invalid:444/relay/v1/ws',
        ),
        '',
      );
      final config = {
        'app': 'clipy',
        'group': 'test',
        'device': 'phone',
        'token': 'a' * 32,
        'trusted_peers': <String, String>{},
        'password': 'imported-untrusted',
      };
      final updated = RelayConfiguration.update(
        existing: '',
        device: 'phone',
        enrollment: jsonEncode(config),
      );
      expect(updated.containsKey('password'), isFalse);
      expect(await ClipyRelayIdentity.accessPassword(url), fixture);
      await expectLater(
        ClipyRelayIdentity.saveAccessPassword(url, 'bad '),
        throwsFormatException,
      );
      expect(await ClipyRelayIdentity.accessPassword(url), fixture);
      await ClipyRelayIdentity.saveAccessPassword(url, '');
      expect(await ClipyRelayIdentity.accessPassword(url), '');
    },
  );

  test(
    'group loads and pending retries use current scoped credential without persisting it',
    () async {
      await SodiumInit.init();
      await ClipyRelayIdentity.saveAccessPassword(url, fixture);
      final groups = await ClipyRelayGroups.load();
      expect(groups.config['password'], fixture);
      await ClipyRelayGroups.savePending(groups);
      expect(await ClipyRelayIdentity.groupDraft(), isNot(contains(fixture)));
      await ClipyRelayGroups.persist(groups);
      expect(await ClipyRelayIdentity.config(), isNot(contains(fixture)));
      await ClipyRelayIdentity.saveAccessPassword(url, 'replacement-fixture');
      await expectLater(ClipyRelayGroups.persist(groups), throwsStateError);
      expect(
        (await ClipyRelayGroups.pending())!.config['password'],
        'replacement-fixture',
      );
      await ClipyRelayIdentity.saveGroupDraft(
        jsonEncode({'url': other, 'password': fixture}),
      );
      await expectLater(ClipyRelayGroups.pending(), throwsFormatException);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('syncRelayURL', other);
      expect(
        (await ClipyRelayGroups.load()).config.containsKey('password'),
        isFalse,
      );
    },
  );

  test(
    'saving an access credential keeps LAN and identity settings intact',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('peerId', 'stable-lan-id');
      await prefs.setInt('syncPort', 5566);
      await SyncManager.instance.updateRelaySettings(
        enabled: false,
        url: url,
        token: '',
        accessPassword: fixture,
      );
      expect(await ClipyRelayIdentity.accessPassword(url), fixture);
      expect(await ClipyRelayIdentity.config(), '');
      expect(prefs.getString('peerId'), 'stable-lan-id');
      expect(prefs.getInt('syncPort'), 5566);
      expect(
        prefs.getKeys().any((key) => key.toLowerCase().contains('password')),
        isFalse,
      );
      await SyncManager.instance.updateRelaySettings(
        enabled: false,
        url: other,
        token: '',
      );
      expect(await ClipyRelayIdentity.accessPassword(other), '');
    },
  );

  test(
    'missing credential cannot enable relay; corrupt secure values are unavailable',
    () async {
      await expectLater(
        SyncManager.instance.updateRelaySettings(
          enabled: true,
          url: url,
          token: '',
        ),
        throwsFormatException,
      );
      for (final raw in [
        'not-json',
        '[]',
        jsonEncode({'url': url, 'password': 123}),
        jsonEncode({'url': url, 'password': 'short'}),
      ]) {
        FlutterSecureStorage.setMockInitialValues({
          'commonRelayAccessPassword': raw,
        });
        expect(await ClipyRelayIdentity.accessPassword(url), '');
      }
    },
  );

  test('invitation exports and imports exclude access credentials', () {
    final invitation = {
      'version': 1,
      'app': 'clipy',
      'group': 'fixture',
      'password': fixture,
    };
    final encoded = ClipyRelayGroups.encodeInvitation(invitation);
    expect(
      ClipyRelayGroups.decodeInvitation(encoded).containsKey('password'),
      isFalse,
    );
    expect(
      ClipyRelayGroups.decodeInvitation(
        jsonEncode(invitation),
      ).containsKey('password'),
      isFalse,
    );
  });

  testWidgets(
    'editor masks stored credential, reveals on demand, clears on URL edit and validates',
    (tester) async {
      await AppLanguageController.instance.init();
      await ClipyRelayIdentity.saveAccessPassword(url, fixture);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RelaySettings(showGroupManagement: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const PageStorageKey('relay-access-password'));
      expect(tester.widget<TextField>(field).controller!.text, fixture);
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.ensureVisible(field);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).obscureText, isFalse);
      await tester.enterText(
        find.byKey(const PageStorageKey('relay-url')),
        other,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '');
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, 'too short');
      await tester.ensureVisible(find.text('Save relay settings'));
      await tester.tap(find.text('Save relay settings'));
      await tester.pumpAndSettle();
      expect(
        find.text('Use 8–128 printable ASCII characters without spaces.'),
        findsOneWidget,
      );
      expect(await ClipyRelayIdentity.accessPassword(url), fixture);
      expect(await ClipyRelayIdentity.accessPassword(other), '');
      expect(tester.takeException(), isNull);
    },
  );
}
