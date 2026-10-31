import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/relay_configuration.dart';

void main() {
  final original = {
    'app': 'clipy',
    'group': 'personal',
    'device': 'phone_old',
    'token': 'a' * 32,
    'public_key': '01' * 32,
    'secret_key': '02' * 32,
    'trusted_peers': {'mac': '03' * 32},
    'sync_key': '04' * 32,
  };
  final raw = jsonEncode(original);
  test(
    'rotating only a key preserves device, private key and trusted peers',
    () {
      final updated = RelayConfiguration.update(
        existing: raw,
        device: 'phone_old',
        accessKey: 'b' * 32,
      );
      expect(updated, {...original, 'token': 'b' * 32});
    },
  );
  test(
    'custom relay ID is independent; blank key retains saved credentials',
    () {
      expect(RelayConfiguration.update(existing: raw, device: 'phone_new'), {
        ...original,
        'device': 'phone_new',
      });
      expect(
        RelayConfiguration.update(existing: raw, device: 'phone_old'),
        original,
      );
    },
  );
  test('invalid edits and mismatched enrollment cannot overwrite identity', () {
    expect(
      () => RelayConfiguration.update(existing: raw, device: 'bad id'),
      throwsFormatException,
    );
    expect(
      () => RelayConfiguration.update(
        existing: raw,
        device: 'phone_old',
        accessKey: 'short',
      ),
      throwsFormatException,
    );
    expect(
      () => RelayConfiguration.update(
        existing: raw,
        device: 'other',
        enrollment: raw,
      ),
      throwsFormatException,
    );
    expect(
      () => RelayConfiguration.update(
        existing: '',
        device: 'new',
        accessKey: 'a' * 32,
      ),
      throwsFormatException,
    );
  });
  test(
    'custom relay aliases map to stable LAN identities; old UUIDs still work',
    () {
      const lan = '12345678-1234-1234-1234-123456789abc';
      expect(RelayConfiguration.lanPeer('phone_new', {'peerId': lan}), lan);
      expect(RelayConfiguration.lanPeer(lan, {}), lan);
      expect(RelayConfiguration.lanPeer('phone_new', {}), isNull);
      expect(RelayConfiguration.lanPeer('phone_new', {'peerId': 7}), isNull);
    },
  );
}
