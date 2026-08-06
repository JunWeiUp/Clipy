import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';

/// Mirror of SyncManager's transport crypto (kept in step by these tests).
/// The nonce is prepended to the ciphertext rather than being fixed, which is
/// what makes GCM safe here — a reused nonce under a fixed key leaks the
/// authentication subkey.
encrypt.Key keyFor(String secret) => encrypt.Key(
    Uint8List.fromList(sha256.convert(utf8.encode(secret)).bytes));

String encryptText(String plaintext, encrypt.Key key) {
  final rng = Random.secure();
  final iv = encrypt.IV(
      Uint8List.fromList(List<int>.generate(12, (_) => rng.nextInt(256))));
  final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
  final encrypted = encrypter.encrypt(plaintext, iv: iv);
  return base64Encode(Uint8List.fromList([...iv.bytes, ...encrypted.bytes]));
}

String? decryptText(String payload, encrypt.Key key) {
  try {
    final raw = base64Decode(payload);
    if (raw.length <= 12) return null;
    final iv = encrypt.IV(Uint8List.fromList(raw.sublist(0, 12)));
    final encrypter =
        encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
    return encrypter.decrypt(encrypt.Encrypted(raw.sublist(12)), iv: iv);
  } catch (_) {
    return null;
  }
}

void main() {
  final key = keyFor('ClipySyncSecret2026');

  test('round-trips a payload', () {
    const plaintext = '{"type":"history","value":"hello 世界"}';
    expect(decryptText(encryptText(plaintext, key), key), plaintext);
  });

  test('uses a fresh nonce per message', () {
    const plaintext = 'same input twice';
    final first = base64Decode(encryptText(plaintext, key)).sublist(0, 12);
    final second = base64Decode(encryptText(plaintext, key)).sublist(0, 12);
    expect(first, isNot(equals(second)));
  });

  test('rejects a payload encrypted under a different secret', () {
    final payload = encryptText('secret', keyFor('other-pairing-secret'));
    expect(decryptText(payload, key), isNull);
  });

  test('rejects a tampered ciphertext', () {
    final raw = base64Decode(encryptText('secret', key));
    raw[raw.length - 1] ^= 0xFF;
    expect(decryptText(base64Encode(raw), key), isNull);
  });

  test('rejects a truncated payload', () {
    expect(decryptText(base64Encode(Uint8List(8)), key), isNull);
  });
}
