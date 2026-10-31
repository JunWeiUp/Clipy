import 'package:clipy_flutter/sync/relay_configuration.dart';
import 'package:clipy_flutter/features/devices/relay_group_legacy_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/relay_groups.dart';
import 'package:clipy_flutter/features/devices/relay_group_member_tile.dart';

void main() {
  test('existing credentials remain enrolled without a management anchor', () {
    final old = <String, dynamic>{
      'app': 'clipy',
      'group': 'existing-group',
      'device': 'existing-phone',
      'token': 't' * 32,
      'secret_key': '01' * 32,
    };
    expect(RelayConfiguration.groupAccess(old), RelayGroupAccess.legacy);
    expect(
      RelayConfiguration.groupAccess({
        ...old,
        'group_entry': {'payload': 'cached-test-record'},
      }),
      RelayGroupAccess.managed,
    );
    expect(RelayConfiguration.groupAccess({}), RelayGroupAccess.unconfigured);
    expect(old['group'], 'existing-group');
  });
  testWidgets('device menu exposes rename and keeps removal manager-only', (
    tester,
  ) async {
    var renamed = 0, removed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelayGroupMemberTile(
            member: const {
              'device': 'phone',
              'name': 'Phone',
              'manager': false,
            },
            self: 'phone',
            online: true,
            canManage: false,
            busy: false,
            zh: true,
            onRename: () => renamed++,
            onRemove: () => removed++,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('设备操作'));
    await tester.pumpAndSettle();
    expect(find.text('修改设备名称'), findsOneWidget);
    expect(find.text('移除设备'), findsNothing);
    await tester.tap(find.text('修改设备名称'));
    await tester.pumpAndSettle();
    expect(renamed, 1);
    expect(removed, 0);
  });
  testWidgets('existing group shows preserved identity without a join form', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RelayGroupLegacyView(
              group: 'existing-group',
              device: 'existing-phone',
              trustedDevices: ['trusted-mac'],
              zh: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('已接入设备组'), findsOneWidget);
    expect(find.text('existing-group'), findsOneWidget);
    expect(find.text('组管理待启用'), findsOneWidget);
    expect(find.text('trusted-mac'), findsOneWidget);
    expect(find.text('申请加入'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  test('QR and copied invitations prefer the compact encrypted link', () {
    const link = 'common-relay://example.invalid/i/test#key';
    expect(
      ClipyRelayGroups.encodeInvitation({
        'short_link': link,
        'delegate_secret': 'private-test-value',
      }),
      link,
    );
  });

  test('invitation round trip rejects foreign apps and oversized input', () {
    final code = {
      'version': 1,
      'app': 'clipy',
      'group': 'test',
      'id': 'abcd',
      'name': '手机',
    };
    expect(
      ClipyRelayGroups.decodeInvitation(
        ClipyRelayGroups.encodeInvitation(code),
      ),
      code,
    );
    expect(
      () => ClipyRelayGroups.decodeInvitation(
        '{"version":1,"app":"other","group":"test"}',
      ),
      throwsFormatException,
    );
    expect(
      () => ClipyRelayGroups.decodeInvitation('x' * 8193),
      throwsFormatException,
    );
  });
  testWidgets(
    'ordinary members and self have no remove control; busy prevents removal',
    (tester) async {
      var removes = 0;
      Future<void> show(bool manage, String self, bool busy) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RelayGroupMemberTile(
                member: const {
                  'device': 'phone',
                  'name': 'Phone',
                  'manager': false,
                },
                self: self,
                online: false,
                canManage: manage,
                busy: busy,
                zh: true,
                onRemove: () => removes++,
              ),
            ),
          ),
        );
      }

      await show(false, 'mac', false);
      expect(find.byTooltip('移除设备'), findsNothing);
      await show(true, 'phone', false);
      expect(find.byTooltip('移除设备'), findsNothing);
      await show(true, 'mac', true);
      await tester.tap(find.byTooltip('移除设备'));
      expect(removes, 0);
      await show(true, 'mac', false);
      expect(find.textContaining('离线'), findsOneWidget);
      await tester.tap(find.byTooltip('移除设备'));
      expect(removes, 1);
    },
  );
  testWidgets(
    'long device names remain usable on narrow screens with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                RelayGroupMemberTile(
                  member: const {
                    'device': 'test-phone-with-long-id',
                    'name': '测试手机测试手机测试手机测试手机',
                    'manager': true,
                  },
                  self: 'mac',
                  online: true,
                  canManage: true,
                  busy: false,
                  zh: true,
                  onRemove: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('移除设备'), findsOneWidget);
    },
  );
}
