/// One foreground discovery job shared by all callers. No timers or polling.
/// Opening a share tries remembered endpoints first; manual refresh can upgrade
/// that same job to a full scan. Successful connections avoid the fallback scan.
class DiscoveryRefreshCoordinator {
  DiscoveryRefreshCoordinator({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Future<void>? _active;
  DateTime? _lastFinished;
  bool _fullRequested = false;
  int _generation = 0;

  Future<void> refresh({
    required bool automatic,
    required bool Function() hasPeers,
    required Future<void> Function(bool full) scan,
  }) {
    final active = _active;
    if (active != null) {
      if (!automatic) _fullRequested = true;
      return active;
    }
    if (automatic && hasPeers()) return Future.value();
    final last = _lastFinished;
    final gap = Duration(seconds: automatic ? 30 : 3);
    if (last != null && _now().difference(last) < gap) return Future.value();
    final generation = _generation;
    _fullRequested = !automatic;
    // Schedule after publishing _active so synchronous/reentrant requests join.
    final task = Future<void>.microtask(() async {
      if (generation != _generation) return;
      if (!_fullRequested) await scan(false);
      if (generation != _generation) return;
      if (_fullRequested || !hasPeers()) await scan(true);
    });
    late final Future<void> tracked;
    tracked = task.whenComplete(() {
      if (generation == _generation && identical(_active, tracked)) {
        _lastFinished = _now();
        _active = null;
      }
    });
    _active = tracked;
    return tracked;
  }

  void reset() {
    _generation++;
    _active = null;
    _lastFinished = null;
    _fullRequested = false;
  }
}
