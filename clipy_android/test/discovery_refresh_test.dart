import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/sync/discovery_refresh.dart';

void main() {
  test('share open reuses live peers and tries cache before subnet', () async {
    final coordinator = DiscoveryRefreshCoordinator();
    var connected = true;
    final scans = <bool>[];
    Future<void> refresh() => coordinator.refresh(
      automatic: true,
      hasPeers: () => connected,
      scan: (full) async {
        scans.add(full);
        connected = true;
      },
    );
    await refresh();
    expect(scans, isEmpty);
    connected = false;
    await refresh();
    expect(scans, [false]);
  });

  test(
    'empty cache falls back once; repeated opens and taps are bounded',
    () async {
      var now = DateTime(2020);
      final coordinator = DiscoveryRefreshCoordinator(now: () => now);
      final scans = <bool>[];
      Future<void> refresh(bool automatic) => coordinator.refresh(
        automatic: automatic,
        hasPeers: () => false,
        scan: (full) async => scans.add(full),
      );
      await refresh(true);
      expect(scans, [false, true]);
      for (var i = 0; i < 20; i++) {
        await refresh(true);
        await refresh(false);
      }
      expect(scans, [false, true]);
      now = now.add(const Duration(seconds: 3));
      await refresh(false);
      expect(scans, [false, true, true]);
      now = now.add(const Duration(seconds: 29));
      await refresh(true);
      expect(scans.length, 3);
      now = now.add(const Duration(seconds: 1));
      await refresh(true);
      expect(scans, [false, true, true, false, true]);
    },
  );

  test(
    'manual refresh upgrades a pending cache probe and all callers wait',
    () async {
      final coordinator = DiscoveryRefreshCoordinator();
      final cached = Completer<void>();
      final full = Completer<void>();
      final scans = <bool>[];
      var connected = false;
      Future<void> request(bool automatic) => coordinator.refresh(
        automatic: automatic,
        hasPeers: () => connected,
        scan: (subnet) {
          scans.add(subnet);
          return subnet ? full.future : cached.future;
        },
      );
      final first = request(true);
      await Future<void>.delayed(Duration.zero);
      final second = request(false);
      expect(identical(first, second), isTrue);
      connected = true;
      cached.complete();
      await Future<void>.delayed(Duration.zero);
      expect(scans, [false, true]);
      var completed = false;
      unawaited(second.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      full.complete();
      await Future.wait([first, second]);
      expect(completed, isTrue);
    },
  );

  test(
    'stop prevents stale cache completion from starting a subnet scan',
    () async {
      final coordinator = DiscoveryRefreshCoordinator();
      final cache = Completer<void>();
      final scans = <bool>[];
      final first = coordinator.refresh(
        automatic: true,
        hasPeers: () => false,
        scan: (full) {
          scans.add(full);
          return cache.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      coordinator.reset();
      await coordinator.refresh(
        automatic: false,
        hasPeers: () => false,
        scan: (full) async => scans.add(full),
      );
      cache.complete();
      await first;
      expect(scans, [false, true]);
    },
  );

  test('failed discovery releases the shared job and can be retried', () async {
    var now = DateTime(2020);
    final coordinator = DiscoveryRefreshCoordinator(now: () => now);
    await expectLater(
      coordinator.refresh(
        automatic: false,
        hasPeers: () => false,
        scan: (_) async => throw StateError('listener unavailable'),
      ),
      throwsStateError,
    );
    now = now.add(const Duration(seconds: 3));
    var retried = false;
    await coordinator.refresh(
      automatic: false,
      hasPeers: () => false,
      scan: (_) async {
        retried = true;
      },
    );
    expect(retried, isTrue);
  });
}
