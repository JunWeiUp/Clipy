import 'dart:async';

/// Only a matching receiver ACK confirms delivery, not socket.add/flush.
/// At most 32 user sends wait for 12 seconds; ACK/timeout/stop releases timers.
/// Durable retry remains owned by pending_sync after a UI wait times out.
class TextDeliveryReceipts {
  TextDeliveryReceipts({this.timeout = const Duration(seconds: 12)});
  final Duration timeout;
  final _pending = <(String, String), Completer<bool>>{};
  final _timers = <(String, String), Timer>{};

  Future<bool> send({
    required String peerId,
    required String hash,
    required Future<void> Function() dispatch,
  }) {
    final key = (peerId, hash);
    final existing = _pending[key];
    if (existing != null) return existing.future;
    if (_pending.length >= 32) return Future.value(false);
    final receipt = Completer<bool>();
    _pending[key] = receipt;
    void finish(bool received) {
      if (!identical(_pending[key], receipt)) return;
      _pending.remove(key);
      _timers.remove(key)?.cancel();
      receipt.complete(received);
    }

    _timers[key] = Timer(timeout, () => finish(false));
    unawaited(
      Future<void>.sync(dispatch).catchError((Object _) {
        finish(false);
      }),
    );
    return receipt.future;
  }

  void acknowledge({required String peerId, required String hash}) {
    final key = (peerId, hash);
    _timers.remove(key)?.cancel();
    _pending.remove(key)?.complete(true);
  }

  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final receipt in _pending.values) {
      receipt.complete(false);
    }
    _pending.clear();
  }
}
