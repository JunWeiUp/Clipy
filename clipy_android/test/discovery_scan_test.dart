import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/sync/discovery_scan.dart';
import 'package:clipy_android/sync/session_policy.dart';

void main() {
  test(
    'bounded workers report completion and await the slowest probe',
    () async {
      final gates = List.generate(5, (_) => Completer<void>());
      final started = <String>[];
      final progress = <int>[];
      var finished = false;
      final scan = runDiscoveryScan(
        ['0', '1', '2', '3', '4'],
        concurrency: 2,
        isCurrent: () => true,
        probe: (host) {
          started.add(host);
          return gates[int.parse(host)].future;
        },
        onProgress: (done, total) {
          expect(total, 5);
          progress.add(done);
        },
      ).then((_) => finished = true);
      expect(started, ['0', '1']);
      expect(progress, [0]);
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, ['0', '1', '2']);
      for (var i = 2; i < 5; i++) {
        gates[i].complete();
        await Future<void>.delayed(Duration.zero);
      }
      expect(progress.last, 4);
      expect(finished, isFalse);
      gates[0].complete();
      await scan;
      expect(progress, [0, 1, 2, 3, 4, 5]);
    },
  );

  test('stop suppresses late progress and unscheduled probes', () async {
    final gate = Completer<void>();
    var current = true;
    final visited = <String>[];
    final progress = <int>[];
    final scan = runDiscoveryScan(
      ['a', 'b', 'c'],
      concurrency: 1,
      isCurrent: () => current,
      probe: (host) {
        visited.add(host);
        return gate.future;
      },
      onProgress: (done, _) => progress.add(done),
    );
    current = false;
    gate.complete();
    await scan;
    expect(visited, ['a']);
    expect(progress, [0]);
  });

  test('empty network finishes without scheduling a probe', () async {
    await runDiscoveryScan(
      [],
      concurrency: 64,
      isCurrent: () => true,
      probe: (_) async => fail('unexpected probe'),
      onProgress: (done, total) {
        expect(done, 0);
        expect(total, 0);
      },
    );
  });

  test('legacy and unknown policies preserve replacement behavior', () {
    for (final policy in [null, 'unknown']) {
      expect(
        shouldReplaceSyncSession(
          remotePolicy: policy,
          localId: 'a',
          remoteId: 'b',
          existingInbound: false,
          incomingInbound: true,
        ),
        true,
      );
    }
  });

  test('crossed handshakes converge for every arrival order at both peers', () {
    for (final firstAtA in [false, true]) {
      for (final firstAtB in [false, true]) {
        bool retained(String local, String remote, bool first) {
          return shouldReplaceSyncSession(
                remotePolicy: syncSessionPolicy,
                localId: local,
                remoteId: remote,
                existingInbound: first,
                incomingInbound: !first,
              )
              ? !first
              : first;
        }

        // A's outgoing socket is exactly B's incoming socket.
        expect(retained('a', 'b', firstAtA), false);
        expect(retained('b', 'a', firstAtB), true);
      }
    }
    for (final inbound in [false, true]) {
      expect(
        shouldReplaceSyncSession(
          remotePolicy: syncSessionPolicy,
          localId: 'a',
          remoteId: 'b',
          existingInbound: inbound,
          incomingInbound: inbound,
        ),
        true,
      );
    }
  });
}
