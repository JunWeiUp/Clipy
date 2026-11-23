import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/network_handoff.dart';

void main() {
  test('probe expires only unchanged silent connection', () {
    final old = Object(), replacement = Object(), t = DateTime(2020);
    const later = Duration(milliseconds: 1);
    bool expires(Object? current, {DateTime? pong, DateTime? inbound}) =>
        shouldExpireNetworkProbe(
          capturedConnection: old,
          currentConnection: current,
          previousPong: t,
          currentPong: pong ?? t,
          previousInbound: t,
          currentInbound: inbound ?? t,
        );
    expect(expires(old), true);
    expect(expires(old, pong: t.add(later)), false);
    // A backlog flush may delay the pong; any inbound bytes prove liveness.
    expect(expires(old, inbound: t.add(later)), false);
    expect(expires(replacement), false);
    expect(expires(null), false);
  });

  test('relay peer-available probes are throttled', () {
    final t = DateTime(2020);
    expect(shouldStartRelayPeerProbe(null, t), true);
    expect(
      shouldStartRelayPeerProbe(t, t.add(const Duration(seconds: 3))),
      false,
    );
    expect(shouldStartRelayPeerProbe(t, t.add(relayPeerProbeCooldown)), true);
  });

  test('relay sessions get a longer probe window', () {
    expect(networkProbeDelay(hasRelaySession: false), lanProbeDelay);
    expect(networkProbeDelay(hasRelaySession: true), relayProbeDelay);
    expect(relayProbeDelay > lanProbeDelay, true);
  });
}
