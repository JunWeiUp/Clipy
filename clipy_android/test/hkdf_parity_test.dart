import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirror of SyncManager._hkdfSha256 (kept in sync by this test).
Uint8List hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) {
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  final out = <int>[];
  var block = <int>[];
  var counter = 1;
  while (out.length < length) {
    block = Hmac(sha256, prk).convert([...block, ...info, counter]).bytes;
    out.addAll(block);
    counter++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

void main() {
  test('HKDF-SHA256 matches CryptoKit HKDF<SHA256>.deriveKey', () {
    final key = hkdfSha256(
      ikm: utf8.encode('hunter2'),
      salt: utf8.encode('clipy.sync.v2.hkdf'),
      info: utf8.encode('aes-256-gcm'),
      length: 32,
    );
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(hex,
        'd164fcd218e08daf93e80254c79b3c3e80d1f2d6bc18d5e06541d9bc604a3fa1');
  });
}
