import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clipy_android/sync/crypto.dart';

void main() {
  final crypto = SyncCrypto()..pairingSecret = '';

  // Legacy empty-secret key matches SHA256(legacySharedSecret).
  test('round-trips a payload', () {
    const plaintext = '{"type":"history","value":"hello 世界"}';
    final enc = crypto.encryptText(plaintext);
    expect(enc, isNotNull);
    expect(crypto.decryptText(enc!), plaintext);
  });

  test('uses a fresh nonce per message', () {
    const plaintext = 'same input twice';
    final first = base64Decode(crypto.encryptText(plaintext)!).sublist(0, 12);
    final second = base64Decode(crypto.encryptText(plaintext)!).sublist(0, 12);
    expect(first, isNot(equals(second)));
  });

  test('rejects a payload encrypted under a different secret', () {
    final other = SyncCrypto()..pairingSecret = 'other-pairing-secret';
    final payload = other.encryptText('secret')!;
    expect(crypto.decryptText(payload), isNull);
  });

  test('rejects a tampered ciphertext', () {
    final raw = base64Decode(crypto.encryptText('secret')!);
    raw[raw.length - 1] ^= 0xFF;
    expect(crypto.decryptText(base64Encode(raw)), isNull);
  });

  test('rejects a truncated payload', () {
    expect(crypto.decryptText(base64Encode(Uint8List(8))), isNull);
  });
}
