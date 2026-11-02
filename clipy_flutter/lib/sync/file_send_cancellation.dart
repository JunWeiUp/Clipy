import 'dart:async';

/// One send owns one token. Cancellation interrupts awaits and is checked again
/// before writing a frame; it never closes a session shared by other transfers.
class FileSendCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const FileSendCancelled();
  }

  Future<T> wait<T>(Future<T> work) {
    check();
    return Future.any([
      work,
      _cancelled.future.then<T>((_) => throw const FileSendCancelled()),
    ]);
  }
}

class FileSendCancelled implements Exception {
  const FileSendCancelled();
}
