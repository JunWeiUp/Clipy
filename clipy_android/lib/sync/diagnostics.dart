import 'package:flutter/foundation.dart';

/// Per-peer sync health for the diagnostics page (mirrors macOS
/// `SyncDiagnostics`). Everything runs on the main isolate, so a plain map
/// plus [ChangeNotifier] is enough.
class SyncPeerDiagnostics {
  SyncPeerDiagnostics(this.peerId);

  final String peerId;
  String? name;
  String? host;
  DateTime? sessionUpAt;
  DateTime? sessionDownAt;
  DateTime? lastSentAt;
  DateTime? lastAckAt;
  DateTime? lastReceivedAt;
  String? lastError;
  DateTime? lastErrorAt;
}

class SyncDiagnostics extends ChangeNotifier {
  final Map<String, SyncPeerDiagnostics> _records = {};

  Map<String, SyncPeerDiagnostics> get records => Map.unmodifiable(_records);

  void _update(String peerId, void Function(SyncPeerDiagnostics r) body) {
    if (peerId.isEmpty) return;
    body(_records.putIfAbsent(peerId, () => SyncPeerDiagnostics(peerId)));
    notifyListeners();
  }

  void noteSessionUp(String peerId, {required String name, required String host}) =>
      _update(peerId, (r) {
        r
          ..name = name
          ..host = host
          ..sessionUpAt = DateTime.now()
          ..lastError = null
          ..lastErrorAt = null;
      });

  void noteSessionDown(String peerId) =>
      _update(peerId, (r) => r.sessionDownAt = DateTime.now());

  void noteSent(String peerId) =>
      _update(peerId, (r) => r.lastSentAt = DateTime.now());

  void noteAck(String peerId) =>
      _update(peerId, (r) => r.lastAckAt = DateTime.now());

  void noteReceived(String peerId) =>
      _update(peerId, (r) => r.lastReceivedAt = DateTime.now());

  void noteError(String peerId, String message, {String? name, String? host}) =>
      _update(peerId, (r) {
        if (name != null) r.name = name;
        if (host != null) r.host = host;
        r
          ..lastError = message
          ..lastErrorAt = DateTime.now();
      });

  void reset() {
    if (_records.isEmpty) return;
    _records.clear();
    notifyListeners();
  }
}
