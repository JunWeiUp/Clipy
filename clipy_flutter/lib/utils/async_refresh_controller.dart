import 'dart:async';

/// Coalesces refreshes into one running load and one latest rerun. Disposed or
/// superseded loads must not publish their result (including after an await).
class AsyncRefreshController {
  int _revision = 0;
  bool _disposed = false;
  Future<void>? _running;

  Future<void> refresh(Future<void> Function(bool Function() isCurrent) load) {
    if (_disposed) return Future.value();
    _revision++;
    if (_running != null) return _running!;
    final completion = Completer<void>();
    _running = completion.future;
    unawaited(_drain(load, completion));
    return completion.future;
  }

  Future<void> _drain(
    Future<void> Function(bool Function() isCurrent) load,
    Completer<void> completion,
  ) async {
    try {
      int revision;
      do {
        revision = _revision;
        await load(() => !_disposed && revision == _revision);
      } while (!_disposed && revision != _revision);
      _running = null;
      completion.complete();
    } catch (error, stack) {
      _running = null;
      completion.completeError(error, stack);
    }
  }

  void dispose() {
    _disposed = true;
    _revision++;
  }
}
