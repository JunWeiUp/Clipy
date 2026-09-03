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

  // Binary file-chunk path (file.transfer). Wire form must stay
  // base64(nonce12 ‖ ciphertext ‖ tag) to match the Swift implementation.
  test('round-trips binary chunk payload', () async {
    final header = ByteData(4)..setUint32(0, 42, Endian.big);
    final chunk = Uint8List.fromList(
      List<int>.generate(70000, (i) => i & 0xFF),
    );
    final builder = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(chunk);
    final plain = builder.toBytes();
    final enc = await crypto.encryptBytes(plain);
    expect(enc, isNotNull);
    final raw = base64Decode(enc!);
    expect(raw.length, 12 + plain.length + 16);
    final dec = await crypto.decryptToBytes(enc);
    expect(dec, isNotNull);
    expect(ByteData.sublistView(dec!).getUint32(0, Endian.big), 42);
    expect(dec.sublist(4), chunk);
  });

  test('rejects a tampered binary chunk', () async {
    final enc = await crypto.encryptBytes(
      Uint8List.fromList(List<int>.filled(1024, 7)),
    );
    expect(enc, isNotNull);
    final raw = base64Decode(enc!);
    raw[raw.length - 1] ^= 0xFF;
    expect(await crypto.decryptToBytes(base64Encode(raw)), isNull);
  });
}
