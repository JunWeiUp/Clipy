/// Invalidates asynchronous socket and discovery work when sync stops.
///
/// A new run receives a different epoch even when stop and restart happen
/// before an in-flight connection attempt finishes.
class SyncRunLifecycle {
  int _epoch = 0;
  bool _active = false;

  int get epoch => _epoch;
  bool get isActive => _active;

  int begin() {
    _active = true;
    return ++_epoch;
  }

  void stop() {
    _active = false;
    _epoch++;
  }

  bool isCurrent(int epoch) => _active && _epoch == epoch;
}
