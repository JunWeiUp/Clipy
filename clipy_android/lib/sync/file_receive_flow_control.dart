/// Pauses socket reads while native decrypt/disk writes catch up. Keep at most
/// two decoded file envelopes queued; TCP supplies backpressure to the sender.
class FileReceiveFlowControl {
  FileReceiveFlowControl({
    required this.pause,
    required this.drain,
    required this.resume,
  });
  final void Function() pause;
  final void Function() drain;
  final void Function() resume;
  int _pending = 0;
  bool _paused = false;
  bool _closed = false;
  bool get isPaused => _paused;
  bool get isAtCapacity => _pending >= 2;

  void enqueue() {
    if (_closed) return;
    _pending++;
    if (_pending >= 2 && !_paused) {
      _paused = true;
      pause();
    }
  }

  void complete() {
    if (_closed) return;
    if (_pending > 0) _pending--;
    if (!_paused) return;
    drain();
    if (_pending < 2) {
      _paused = false;
      resume();
    }
  }

  void close() => _closed = true;
}
