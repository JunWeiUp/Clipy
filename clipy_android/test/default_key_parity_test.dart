import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/sync/crypto.dart';

void main() {
  test('default transport key matches the Swift SHA-256 fixture', () {
    final hex = SyncCrypto()
        .key()
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(
      hex,
      '30f891b68d235b41eb215ffe624c29d3782f27efc26c8f00e80e10ef9daa8304',
    );
  });
}
