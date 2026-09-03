import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:clipy_android/sync/crypto.dart';

void main() {
  test('HKDF-SHA256 matches CryptoKit HKDF<SHA256>.deriveKey', () {
    final key = SyncCrypto.hkdfSha256(
      ikm: utf8.encode('hunter2'),
      salt: utf8.encode(SyncCrypto.keyDerivationSalt),
      info: utf8.encode(SyncCrypto.keyDerivationInfo),
      length: 32,
    );
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(
      hex,
      'd164fcd218e08daf93e80254c79b3c3e80d1f2d6bc18d5e06541d9bc604a3fa1',
    );
  });
}
