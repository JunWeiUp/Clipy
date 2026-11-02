import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../sync_manager.dart';

enum WindowsTransferStatus { sending, completed, failed, cancelled }

class WindowsTransfer {
  WindowsTransfer({
    required this.id,
    required this.peerId,
    required this.name,
    this.path,
    this.outgoing = true,
  });
  final String id;
  final String peerId;
  final String name;
  final String? path;
  final bool outgoing;
  final stopwatch = Stopwatch()..start();
  WindowsTransferStatus status = WindowsTransferStatus.sending;
  int bytes = 0;
  int total = 0;
  double get fraction => total == 0 ? 0 : (bytes / total).clamp(0, 1);
  double get bytesPerSecond => stopwatch.elapsedMicroseconds == 0
      ? 0
      : bytes * 1000000 / stopwatch.elapsedMicroseconds;
}

/// Windows-only, lazy application session journal. At most four sends and 100
/// rows; stream-driven, no timer or file contents retained. Keeps in-flight
/// operations visible when switching away and back. dispose releases listeners.
class WindowsTransferController extends ChangeNotifier {
  WindowsTransferController({
    required Stream<FileProgress> progress,
    required Future<bool> Function(File file, String peerId, String id) send,
    required void Function(String id) cancel,
  }) : _send = send,
       _cancel = cancel {
    _subscription = progress.listen(_onProgress);
  }

  static final instance = WindowsTransferController(
    progress: SyncManager.instance.onFileProgress,
    send: (file, peer, id) =>
        SyncManager.instance.sendFileToPeer(file, peerId: peer, fileId: id),
    cancel: SyncManager.instance.cancelFileTransfer,
  );
  final Future<bool> Function(File, String, String) _send;
  final void Function(String) _cancel;
  late final StreamSubscription<FileProgress> _subscription;
  final List<WindowsTransfer> _rows = [];
  bool _disposed = false;
  final Set<String> _activePeers = {};
  bool canSendTo(String peerId) => canSend && !_activePeers.contains(peerId);
  List<WindowsTransfer> get rows => List.unmodifiable(_rows);
  bool get canSend => _activePeers.length < 4;

  void _publish() {
    while (_rows.length > 100) {
      final index = _rows.lastIndexWhere(
        (r) => r.status != WindowsTransferStatus.sending,
      );
      if (index < 0) break;
      _rows.removeAt(index);
    }
    if (!_disposed) notifyListeners();
  }

  void _onProgress(FileProgress event) {
    var matches = _rows.where((r) => r.id == event.fileId);
    if (matches.isEmpty) {
      if (event.peerId == null ||
          _rows
                  .where((r) => r.status == WindowsTransferStatus.sending)
                  .length >=
              32) {
        return;
      }
      _rows.insert(
        0,
        WindowsTransfer(
          id: event.fileId,
          peerId: event.peerId!,
          name: event.fileName,
          outgoing: event.isOutgoing,
        ),
      );
      matches = _rows.where((r) => r.id == event.fileId);
    }
    final row = matches.first;
    if (row.status != WindowsTransferStatus.sending) return;
    // Error events must not turn the last real byte count into a fictitious 100%.
    if (!event.isFailed && !event.isCancelled) row.bytes = event.receivedBytes;
    row.total = event.totalBytes;
    if (event.isCompleted) row.status = WindowsTransferStatus.completed;
    if (event.isFailed) row.status = WindowsTransferStatus.failed;
    if (event.isCancelled) row.status = WindowsTransferStatus.cancelled;
    if (row.status != WindowsTransferStatus.sending) row.stopwatch.stop();
    _publish();
  }

  Future<void> sendPath(String path, String peerId) async {
    if (!canSendTo(peerId) || _disposed) return;
    _activePeers.add(peerId);
    final file = File(path);
    final row = WindowsTransfer(
      id: const Uuid().v4(),
      peerId: peerId,
      name: file.uri.pathSegments.last,
      path: path,
    );
    _rows.insert(0, row);
    _publish();
    try {
      final ok = await _send(file, peerId, row.id);
      if (row.status == WindowsTransferStatus.sending) {
        row.status = ok
            ? WindowsTransferStatus.completed
            : WindowsTransferStatus.failed;
      }
    } catch (_) {
      if (row.status == WindowsTransferStatus.sending) {
        row.status = WindowsTransferStatus.failed;
      }
    } finally {
      _activePeers.remove(peerId);
      row.stopwatch.stop();
      _publish();
    }
  }

  void cancel(WindowsTransfer row) {
    if (!row.outgoing ||
        row.path == null ||
        row.status != WindowsTransferStatus.sending) {
      return;
    }
    _cancel(row.id);
    row.status = WindowsTransferStatus.cancelled;
    row.stopwatch.stop();
    _publish();
  }

  Future<void> retry(WindowsTransfer row) async {
    if (row.path == null ||
        !canSend ||
        row.status == WindowsTransferStatus.sending ||
        row.status == WindowsTransferStatus.completed) {
      return;
    }
    await sendPath(row.path!, row.peerId);
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    super.dispose();
  }
}
