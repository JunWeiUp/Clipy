import 'dart:math';

import 'package:clipy_android/sync/pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated codes are 20 Crockford symbols in groups of four', () {
    final code = SyncPairing.generateCode(Random(1));
    expect(
      code,
      matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){4}[0-9A-HJKMNP-TV-Z]{4}$')),
    );
    expect(SyncPairing.generateCode(), isNot(SyncPairing.generateCode()));
  });

  test('parses the Mac pairing link', () {
    final link = SyncPairing.parse(
      'clipy://pair?code=ABCD-EFGH&port=5566&host=192.168.1.8&name=My%20Mac',
    )!;
    expect(link.code, 'ABCD-EFGH');
    expect(link.port, 5566);
    expect(link.host, '192.168.1.8');
    expect(link.name, 'My Mac');
  });

  test('rejects foreign or code-less links and bad ports', () {
    expect(SyncPairing.parse('https://pair?code=X'), isNull);
    expect(SyncPairing.parse('clipy://other?code=X'), isNull);
    expect(SyncPairing.parse('clipy://pair?port=5566'), isNull);
    final link = SyncPairing.parse('clipy://pair?code=X&port=70000')!;
    expect(link.port, isNull);
    expect(link.host, isNull);
  });
}
