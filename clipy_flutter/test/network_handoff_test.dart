import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/network_handoff.dart';

void main() {
  test('probe expires only unchanged connection without a fresh pong', () {
    final old = Object(), replacement = Object(), pong = DateTime(2020);
    bool expires(Object? current, DateTime latest) => shouldExpireNetworkProbe(
      capturedConnection: old,
      currentConnection: current,
      previousPong: pong,
      currentPong: latest,
    );
    expect(expires(old, pong), true);
    expect(expires(old, pong.add(const Duration(milliseconds: 1))), false);
    expect(expires(replacement, pong), false);
    expect(expires(null, pong), false);
  });
}
