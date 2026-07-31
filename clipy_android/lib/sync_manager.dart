import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'clipboard_manager.dart';
import 'database/notification_repository.dart';
import 'database/pending_text_sync_repository.dart';
import 'log_manager.dart';
import 'notification_manager.dart';

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

class FileProgress {
  final String fileId;
  final String fileName;
  final double progress;
  final int receivedBytes;
  final int totalBytes;
  final bool isCompleted;
  final bool isFailed;

  FileProgress({
    required this.fileId,
    required this.fileName,
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    this.isCompleted = false,
    this.isFailed = false,
  });
}

class DiscoveredPeer {
  final String peerId;
  final String displayName;
  final String host;
  final int port;

  const DiscoveredPeer({
    required this.peerId,
    required this.displayName,
    required this.host,
    required this.port,
  });
}

// ---------------------------------------------------------------------------
// Protocol v2
// ---------------------------------------------------------------------------

class _SyncEnvelope {
  static const int version = 2;

  final int v;
  final String type;
  final String msgId;
  final String peerId;
  final String? name;
  final int? port;
  final double ts;
  final String? hash;
  final String? payload;

  _SyncEnvelope({
    required this.v,
    required this.type,
    required this.msgId,
    required this.peerId,
    this.name,
    this.port,
    required this.ts,
    this.hash,
    this.payload,
  });

  factory _SyncEnvelope.make({
    required String type,
    required String peerId,
    String? name,
    int? port,
    String? hash,
    String? payload,
  }) {
    return _SyncEnvelope(
      v: version,
      type: type,
      msgId: const Uuid().v4(),
      peerId: peerId,
      name: name,
      port: port,
      ts: DateTime.now().millisecondsSinceEpoch / 1000.0,
      hash: hash,
      payload: payload,
    );
  }

  factory _SyncEnvelope.fromJson(Map<String, dynamic> json) {
    return _SyncEnvelope(
      v: json['v'] as int? ?? 0,
      type: json['type'] as String? ?? '',
      msgId: json['msgId'] as String? ?? '',
      peerId: json['peerId'] as String? ?? '',
      name: json['name'] as String?,
      port: json['port'] as int?,
      ts: (json['ts'] as num?)?.toDouble() ?? 0,
      hash: json['hash'] as String?,
      payload: json['payload'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': v,
        'type': type,
        'msgId': msgId,
        'peerId': peerId,
        if (name != null) 'name': name,
        if (port != null) 'port': port,
        'ts': ts,
        if (hash != null) 'hash': hash,
        if (payload != null) 'payload': payload,
      };
}

class _SyncType {
  static const hello = 'hello';
  static const welcome = 'welcome';
  static const history = 'history';
  static const notifPost = 'notif.post';
  static const notifDismiss = 'notif.dismiss';
  static const notifClear = 'notif.clear';
  static const notifAck = 'notif.ack';
  static const notifConfig = 'notif.config';
  static const ping = 'ping';
  static const pong = 'pong';
  static const ack = 'ack';
}

class _PendingFrame {
  final String peerId;
  final List<int> data;
  final String type;
  final String? hash;
  final DateTime enqueueAt;

  _PendingFrame({
    required this.peerId,
    required this.data,
    required this.type,
    this.hash,
    required this.enqueueAt,
  });
}

class _Session {
  final String peerId;
  final String host;
  final int port;
  final Socket socket;
  final BytesBuilder buffer = BytesBuilder(copy: false);
  DateTime lastPong = DateTime.now();
  StreamSubscription<List<int>>? subscription;

  _Session({
    required this.peerId,
    required this.host,
    required this.port,
    required this.socket,
  });
}

// ---------------------------------------------------------------------------
// SyncManager
// ---------------------------------------------------------------------------

class SyncManager with WidgetsBindingObserver {
  static final SyncManager instance = SyncManager._();
  SyncManager._();

  static const MethodChannel _fgsChannel =
      MethodChannel('com.clipyclone.clipy_android/sync_service');

  static const int _maxFrameLength = 2 * 1024 * 1024;
  static const String _hardcodedSecret = 'ClipySyncSecret2026';
  static const String _endpointCacheKey = 'clipy.peerEndpoints.v2';
  static const Duration _endpointCacheTtl = Duration(hours: 24);
  static const Duration _discoveryDebounce = Duration(milliseconds: 600);
  static const Duration _handshakeTimeout = Duration(seconds: 2);
  static const Duration _connectTimeout = Duration(seconds: 3);
  static const Duration _scanConnectTimeout = Duration(milliseconds: 350);
  static const Duration _pingInterval = Duration(seconds: 30);
  static const Duration _pendingTtl = Duration(hours: 24);
  static const int _pendingMax = 80;
  static const int _scanConcurrency = 48;
  static const Duration _dialDedupTtl = Duration(seconds: 4);

  final Map<String, DiscoveredPeer> _discoveredPeers = {};
  final _devicesChangedController = StreamController<List<String>>.broadcast();
  final _peersChangedController =
      StreamController<List<DiscoveredPeer>>.broadcast();
  final _fileReceivedController = StreamController<String>.broadcast();
  final _fileProgressController = StreamController<FileProgress>.broadcast();

  Stream<List<String>> get onDevicesChanged => _devicesChangedController.stream;
  Stream<List<DiscoveredPeer>> get onPeersChanged =>
      _peersChangedController.stream;
  Stream<String> get onFileReceived => _fileReceivedController.stream;
  Stream<FileProgress> get onFileProgress => _fileProgressController.stream;

  ServerSocket? _server;
  final Map<String, _Session> _sessions = {};
  final List<_PendingFrame> _pendingQueue = [];
  final Map<String, double> _reconnectBackoffSec = {};
  final Map<String, Timer> _reconnectTimers = {};
  final Map<String, DateTime> _lastDialAt = {};

  Timer? _scanDebounceTimer;
  Timer? _pingTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isRefreshingDiscovery = false;
  bool _discoveryRunning = false;

  bool isEnabled = false;
  int port = 5566;
  List<String> clipboardSyncPeerIds = [];
  List<String> notificationSyncPeerIds = [];
  String peerId = '';
  String displayName = 'Android';

  /// Union of clipboard + notification outbound targets.
  List<String> get authorizedPeerIds =>
      {...clipboardSyncPeerIds, ...notificationSyncPeerIds}.toList()..sort();

  List<DiscoveredPeer> get availablePeers {
    final list = _discoveredPeers.values.toList()
      ..sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return list;
  }

  List<String> get availableDeviceNames =>
      availablePeers.map((p) => p.displayName).toList();

  // -----------------------------------------------------------------------
  // Init / lifecycle
  // -----------------------------------------------------------------------

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('syncEnabled') ?? false;
    port = prefs.getInt('syncPort') ?? 5566;
    peerId = prefs.getString('peerId') ?? '';
    if (peerId.isEmpty) {
      peerId = const Uuid().v4();
      await prefs.setString('peerId', peerId);
    }
    displayName = prefs.getString('deviceName') ??
        (Platform.isAndroid ? 'Android' : 'Device');
    await _migrateAuthorizedPeerIds(prefs);
    await _migrateDualSyncAuth(prefs);
    clipboardSyncPeerIds =
        prefs.getStringList('clipboardSyncPeerIds') ?? [];
    notificationSyncPeerIds =
        prefs.getStringList('notificationSyncPeerIds') ?? [];
    WidgetsBinding.instance.addObserver(this);
    if (isEnabled) {
      await start();
    }
  }

  Future<void> _migrateAuthorizedPeerIds(SharedPreferences prefs) async {
    if (prefs.getBool('authorizedPeerIdsMigrated') ?? false) return;
    final legacy = prefs.getStringList('authorizedDevices') ?? [];
    if (legacy.isEmpty) {
      await prefs.setBool('authorizedPeerIdsMigrated', true);
      return;
    }
    final peerIds = {...(prefs.getStringList('authorizedPeerIds') ?? [])};
    for (final name in legacy) {
      final match = availablePeers.where((p) => p.displayName == name);
      if (match.isNotEmpty) peerIds.add(match.first.peerId);
    }
    final sorted = peerIds.toList()..sort();
    await prefs.setStringList('authorizedPeerIds', sorted);
    await prefs.setBool('authorizedPeerIdsMigrated', true);
  }

  /// One-shot: copy legacy authorizedPeerIds into both capability lists.
  Future<void> _migrateDualSyncAuth(SharedPreferences prefs) async {
    if (prefs.getBool('dualSyncAuthMigrated') ?? false) return;
    final legacy = prefs.getStringList('authorizedPeerIds') ?? [];
    if (prefs.getStringList('clipboardSyncPeerIds') == null) {
      await prefs.setStringList('clipboardSyncPeerIds', legacy);
    }
    if (prefs.getStringList('notificationSyncPeerIds') == null) {
      await prefs.setStringList('notificationSyncPeerIds', legacy);
    }
    await prefs.setBool('dualSyncAuthMigrated', true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isEnabled) {
      triggerCrossBandDiscovery();
    }
  }

  Future<void> start() async {
    appLog('SyncManager v2 starting...');
    unawaited(PendingTextSyncRepository.instance.cleanOld());
    unawaited(NotificationRepository.instance.cleanOldPendingSync());
    final ok = await _startServer();
    if (!ok) {
      appLog('Server failed to start', level: 'error');
      return;
    }
    _startConnectivityMonitoring();
    await _startForegroundService();
    _startPingTimer();
    await _loadEndpointCache();
    triggerCrossBandDiscovery();
  }

  Future<void> stop() async {
    appLog('SyncManager v2 stopping...');
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _scanDebounceTimer?.cancel();
    _scanDebounceTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _reconnectBackoffSec.clear();
    for (final s in _sessions.values) {
      await s.subscription?.cancel();
      try {
        await s.socket.close();
      } catch (_) {}
    }
    _sessions.clear();
    _pendingQueue.clear();
    await _server?.close();
    _server = null;
    await _stopForegroundService();
    _discoveredPeers.clear();
    _emitPeers();
  }

  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _fgsChannel.invokeMethod<bool>('startForegroundSync');
    } catch (e) {
      appLog('startForegroundSync failed: $e', level: 'warning');
    }
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _fgsChannel.invokeMethod<bool>('stopForegroundSync');
    } catch (e) {
      appLog('stopForegroundSync failed: $e', level: 'warning');
    }
  }

  void _startConnectivityMonitoring() {
    _connectivitySub?.cancel();
    var wasOffline = false;
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      if (offline) {
        wasOffline = true;
        return;
      }
      if (wasOffline && isEnabled) {
        wasOffline = false;
        appLog('Network restored; rediscovering');
        unawaited(refreshDiscovery());
      }
    });
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPings());
  }

  Future<void> _sendPings() async {
    final env = _SyncEnvelope.make(type: _SyncType.ping, peerId: peerId);
    final data = _encodeFrame(env);
    if (data == null) return;
    final stale = DateTime.now().subtract(_pingInterval * 3);
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      final session = _sessions[id];
      if (session == null) continue;
      if (session.lastPong.isBefore(stale)) {
        await _closeSession(id, scheduleReconnect: true);
        continue;
      }
      try {
        session.socket.add(data);
      } catch (_) {
        await _closeSession(id, scheduleReconnect: true);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Server
  // -----------------------------------------------------------------------

  Future<bool> _startServer() async {
    try {
      await _server?.close();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      appLog('Listening on 0.0.0.0:$port');
      _server!.listen(_onInbound, onError: (e) {
        appLog('Server error: $e', level: 'error');
      });
      return true;
    } catch (e) {
      appLog('Failed to bind :$port — $e', level: 'error');
      return false;
    }
  }

  void _onInbound(Socket socket) {
    final host = socket.remoteAddress.address;
    appLog('Inbound from $host');
    unawaited(_performHandshake(socket, host: host, inbound: true));
  }

  // -----------------------------------------------------------------------
  // Discovery
  // -----------------------------------------------------------------------

  Future<void> refreshDiscovery() async {
    if (!isEnabled) return;
    if (_isRefreshingDiscovery) return;
    _isRefreshingDiscovery = true;
    // Keep peers that still have a live session. Clearing them would hide
    // connected devices forever: rediscovery skips already-connected hosts,
    // so _recordPeer is never called again for those sessions.
    final cache = await _readEndpointCache();
    final cacheById = <String, Map<String, dynamic>>{
      for (final e in cache)
        if (e['peerId'] is String) e['peerId'] as String: e,
    };
    final kept = <String, DiscoveredPeer>{};
    for (final entry in _sessions.entries) {
      final id = entry.key;
      final session = entry.value;
      final existing = _discoveredPeers[id];
      if (existing != null) {
        kept[id] = existing;
      } else {
        final name = (cacheById[id]?['name'] as String?) ?? id;
        kept[id] = DiscoveredPeer(
          peerId: id,
          displayName: name,
          host: session.host,
          port: session.port,
        );
      }
    }
    _discoveredPeers
      ..clear()
      ..addAll(kept);
    _emitPeers();
    triggerCrossBandDiscovery();
    _isRefreshingDiscovery = false;
  }

  void triggerCrossBandDiscovery() {
    if (!isEnabled) return;
    _scanDebounceTimer?.cancel();
    _scanDebounceTimer = Timer(_discoveryDebounce, () {
      unawaited(_runDiscovery());
    });
  }

  Future<void> _runDiscovery() async {
    if (!isEnabled || _discoveryRunning) return;
    _discoveryRunning = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final manual = prefs.getStringList('manualSyncPeers') ?? [];
      for (final entry in manual) {
        final parts = entry.split(':');
        if (parts.isEmpty || parts.first.isEmpty) continue;
        final host = parts.first;
        final p = parts.length >= 2 ? int.tryParse(parts[1]) ?? port : port;
        unawaited(_dial(host, p, reason: 'manual'));
      }

      final cached = await _readEndpointCache();
      for (final e in cached) {
        if (e['peerId'] == peerId) continue;
        final host = e['host'] as String?;
        final p = e['port'] as int?;
        if (host == null || p == null) continue;
        unawaited(_dial(host, p, reason: 'cache'));
      }

      final myIPs = await _enumerateLocalIPv4s();
      final connectedHosts = _sessions.values.map((s) => s.host).toSet();
      final candidates = <String>{};
      for (final ip in myIPs) {
        final parts = ip.split('.');
        if (parts.length != 4) continue;
        final a = int.tryParse(parts[0]);
        final b = int.tryParse(parts[1]);
        final c = int.tryParse(parts[2]);
        if (a == null || b == null || c == null) continue;
        if (!_isLanIPv4(a, b)) continue;
        for (var d = 1; d <= 254; d++) {
          final candidate = '$a.$b.$c.$d';
          if (myIPs.contains(candidate)) continue;
          if (connectedHosts.contains(candidate)) continue;
          candidates.add(candidate);
        }
      }

      final list = candidates.toList()..sort();
      appLog('Subnet scan: ${list.length} hosts on :$port');
      var index = 0;
      Future<void> worker() async {
        while (true) {
          if (index >= list.length) return;
          final host = list[index++];
          await _dial(host, port,
              reason: 'scan', timeout: _scanConnectTimeout);
        }
      }

      await Future.wait(
          List.generate(_scanConcurrency, (_) => worker()));
      appLog('Subnet scan finished');
    } finally {
      _discoveryRunning = false;
    }
  }

  Future<List<String>> _enumerateLocalIPv4s() async {
    final result = <String>[];
    try {
      for (final iface in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          final parts = ip.split('.').map(int.tryParse).toList();
          if (parts.length != 4 || parts.any((p) => p == null)) continue;
          if (!_isLanIPv4(parts[0]!, parts[1]!)) continue;
          result.add(ip);
        }
      }
    } catch (e) {
      appLog('enumerate IPv4 failed: $e', level: 'warning');
    }
    return result.toSet().toList()..sort();
  }

  Future<List<String>> localIPv4Addresses() => _enumerateLocalIPv4s();

  bool _isLanIPv4(int a, int b) {
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  // -----------------------------------------------------------------------
  // Dial / handshake / session
  // -----------------------------------------------------------------------

  Future<void> _dial(String host, int peerPort,
      {required String reason, Duration? timeout}) async {
    final key = '$host:$peerPort';
    final now = DateTime.now();
    final last = _lastDialAt[key];
    if (last != null &&
        now.difference(last) < _dialDedupTtl &&
        reason == 'scan') {
      return;
    }
    _lastDialAt[key] = now;

    if (_sessions.values.any((s) => s.host == host)) return;

    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        peerPort,
        timeout: timeout ?? _connectTimeout,
      );
    } catch (_) {
      return;
    }
    await _performHandshake(socket, host: host, inbound: false);
  }

  Future<void> _performHandshake(Socket socket,
      {required String host, required bool inbound}) async {
    final hello = _SyncEnvelope.make(
      type: _SyncType.hello,
      peerId: peerId,
      name: displayName,
      port: port,
    );
    final helloData = _encodeFrame(hello);
    if (helloData == null) {
      await socket.close();
      return;
    }

    // Socket is single-subscription: attach one listener for handshake + session.
    final buffer = BytesBuilder(copy: false);
    final firstFrame = Completer<List<int>?>();
    var handshakeDone = false;
    String? adoptedPeerId;

    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        if (!handshakeDone) {
          buffer.add(chunk);
          final frame = _tryTakeFrame(buffer);
          if (frame != null && !firstFrame.isCompleted) {
            firstFrame.complete(frame);
          }
          return;
        }
        final id = adoptedPeerId;
        if (id == null) return;
        final session = _sessions[id];
        if (session == null) return;
        session.buffer.add(chunk);
        _drainBuffer(id);
      },
      onError: (_) {
        if (!firstFrame.isCompleted) firstFrame.complete(null);
        final id = adoptedPeerId;
        if (id != null) {
          unawaited(_closeSession(id, scheduleReconnect: true));
        }
      },
      onDone: () {
        if (!firstFrame.isCompleted) firstFrame.complete(null);
        final id = adoptedPeerId;
        if (id != null) {
          unawaited(_closeSession(id, scheduleReconnect: false));
        }
      },
      cancelOnError: true,
    );

    try {
      socket.add(helloData);
      await socket.flush();
    } catch (_) {
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    final frame = await firstFrame.future.timeout(
      _handshakeTimeout,
      onTimeout: () => null,
    );
    if (frame == null) {
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    final env = _decodeEnvelope(frame);
    if (env == null ||
        env.v != _SyncEnvelope.version ||
        (env.type != _SyncType.hello && env.type != _SyncType.welcome) ||
        env.peerId.isEmpty ||
        env.peerId == peerId) {
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    if (env.type == _SyncType.hello) {
      final welcome = _SyncEnvelope.make(
        type: _SyncType.welcome,
        peerId: peerId,
        name: displayName,
        port: port,
      );
      final data = _encodeFrame(welcome);
      if (data != null) {
        try {
          socket.add(data);
          await socket.flush();
        } catch (_) {}
      }
    }

    final existing = _sessions[env.peerId];
    if (existing != null) {
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      _recordPeer(env.peerId, env.name ?? env.peerId, existing.host, existing.port);
      return;
    }

    final name = env.name ?? env.peerId;
    final peerPort = env.port ?? port;
    final session = _Session(
      peerId: env.peerId,
      host: host,
      port: peerPort,
      socket: socket,
    );
    session.subscription = subscription;
    // Any leftover bytes after the handshake frame belong to the session.
    if (buffer.length > 0) {
      session.buffer.add(buffer.takeBytes());
    }
    _sessions[env.peerId] = session;
    adoptedPeerId = env.peerId;
    handshakeDone = true;

    _reconnectBackoffSec[env.peerId] = 1;
    _reconnectTimers.remove(env.peerId)?.cancel();
    _recordPeer(env.peerId, name, host, peerPort);
    await _persistEndpoint(env.peerId, name, host, peerPort);
    if (session.buffer.length > 0) {
      _drainBuffer(env.peerId);
    }
    await _flushPending(env.peerId);
    appLog(
        'Session up with $name (${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}) @ $host:$peerPort');
  }

  List<int>? _tryTakeFrame(BytesBuilder buffer) {
    final bytes = buffer.toBytes();
    if (bytes.length < 4) {
      buffer.clear();
      buffer.add(bytes);
      return null;
    }
    final length = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4)))
        .getUint32(0, Endian.big);
    if (length <= 0 || length > _maxFrameLength) {
      buffer.clear();
      return null;
    }
    if (bytes.length < 4 + length) {
      buffer.clear();
      buffer.add(bytes);
      return null;
    }
    final frame = bytes.sublist(4, 4 + length);
    final rest = bytes.sublist(4 + length);
    buffer.clear();
    if (rest.isNotEmpty) buffer.add(rest);
    return frame;
  }

  void _recordPeer(String id, String name, String host, int peerPort) {
    _discoveredPeers[id] = DiscoveredPeer(
      peerId: id,
      displayName: name,
      host: host,
      port: peerPort,
    );
    _emitPeers();
  }

  void _emitPeers() {
    _devicesChangedController.add(availableDeviceNames);
    _peersChangedController.add(availablePeers);
  }

  void _drainBuffer(String peerId) {
    final session = _sessions[peerId];
    if (session == null) return;
    final bytes = session.buffer.takeBytes();
    var offset = 0;
    final remaining = BytesBuilder(copy: false);

    while (true) {
      if (bytes.length - offset < 4) {
        remaining.add(bytes.sublist(offset));
        break;
      }
      final length = ByteData.sublistView(
              Uint8List.fromList(bytes.sublist(offset, offset + 4)))
          .getUint32(0, Endian.big);
      if (length <= 0 || length > _maxFrameLength) {
        unawaited(_closeSession(peerId, scheduleReconnect: true));
        return;
      }
      if (bytes.length - offset < 4 + length) {
        remaining.add(bytes.sublist(offset));
        break;
      }
      final frame = bytes.sublist(offset + 4, offset + 4 + length);
      offset += 4 + length;
      _handleFrame(frame, from: peerId, host: session.host);
    }
    if (remaining.length > 0) {
      session.buffer.add(remaining.takeBytes());
    }
  }

  void _handleFrame(List<int> data,
      {required String from, required String host}) {
    final env = _decodeEnvelope(data);
    if (env == null || env.v != _SyncEnvelope.version) return;

    switch (env.type) {
      case _SyncType.ping:
        final pong =
            _SyncEnvelope.make(type: _SyncType.pong, peerId: peerId);
        final d = _encodeFrame(pong);
        final session = _sessions[from];
        if (d != null && session != null) {
          try {
            session.socket.add(d);
          } catch (_) {}
        }
        break;
      case _SyncType.pong:
        final session = _sessions[from];
        if (session != null) session.lastPong = DateTime.now();
        break;
      case _SyncType.ack:
        if (env.hash != null) _handleAck(env.hash!);
        break;
      case _SyncType.history:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decrypt(payload);
        if (text == null) return;
        unawaited(
            ClipboardManager.instance.handleRemoteSync(text, env.hash ?? ''));
        _replyAck(from, env.hash);
        break;
      case _SyncType.notifPost:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decrypt(payload);
        if (text == null) return;
        NotificationManager.instance
            .handleRemoteNotification(text, env.peerId);
        break;
      case _SyncType.notifDismiss:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decrypt(payload);
        if (text == null) return;
        NotificationManager.instance.handleRemoteDismiss(text);
        break;
      case _SyncType.notifClear:
        NotificationManager.instance.clearAll();
        break;
      case _SyncType.notifAck:
        if (env.hash != null) {
          _handleAck(env.hash!);
          NotificationManager.instance.handleAck(env.hash!);
        }
        break;
      case _SyncType.notifConfig:
        appLog('Ignored remote notification config', level: 'warning');
        break;
      case _SyncType.hello:
      case _SyncType.welcome:
        if (env.name != null && env.port != null) {
          _recordPeer(env.peerId, env.name!, host, env.port!);
        }
        break;
    }
  }

  void _replyAck(String peerId, String? hash) {
    if (hash == null || hash.isEmpty) return;
    final env =
        _SyncEnvelope.make(type: _SyncType.ack, peerId: this.peerId, hash: hash);
    final data = _encodeFrame(env);
    final session = _sessions[peerId];
    if (data == null || session == null) return;
    try {
      session.socket.add(data);
    } catch (_) {}
  }

  Future<void> _closeSession(String peerId,
      {required bool scheduleReconnect}) async {
    final session = _sessions.remove(peerId);
    if (session == null) return;
    await session.subscription?.cancel();
    try {
      await session.socket.close();
    } catch (_) {}
    appLog('Session closed with ${peerId.substring(0, peerId.length.clamp(0, 8))}');
    if (scheduleReconnect) _scheduleReconnect(peerId);
  }

  void _scheduleReconnect(String peerId) {
    if (!isEnabled) return;
    if (_reconnectTimers.containsKey(peerId)) return;
    final delay = _reconnectBackoffSec[peerId] ?? 1.0;
    _reconnectBackoffSec[peerId] =
        (delay * 2).clamp(1, 30).toDouble();
    _reconnectTimers[peerId] = Timer(Duration(seconds: delay.round()), () {
      _reconnectTimers.remove(peerId);
      if (_sessions.containsKey(peerId)) return;
      final peer = _discoveredPeers[peerId];
      if (peer != null) {
        unawaited(_dial(peer.host, peer.port, reason: 'reconnect'));
      } else {
        triggerCrossBandDiscovery();
      }
    });
  }

  // -----------------------------------------------------------------------
  // Broadcast APIs
  // -----------------------------------------------------------------------

  Future<void> broadcastSync(String content, String hash) async {
    if (!isEnabled) return;
    final payload = _encrypt(content);
    if (payload == null) return;
    final env = _SyncEnvelope.make(
      type: _SyncType.history,
      peerId: peerId,
      name: displayName,
      hash: hash,
      payload: payload,
    );
    await _fanout(env, requireAuth: true);
    for (final id in clipboardSyncPeerIds) {
      unawaited(PendingTextSyncRepository.instance.insert(
        hash: hash,
        data: content,
        type: _SyncType.history,
        targetPeerId: id,
      ));
    }
  }

  Future<void> broadcastNotificationMessage({
    required String type,
    required String content,
    required String hash,
  }) async {
    final wire = _mapNotificationType(type) ?? type;
    final payload = _encrypt(content);
    if (payload == null &&
        wire != _SyncType.notifAck &&
        wire != _SyncType.notifClear) {
      return;
    }
    final env = _SyncEnvelope.make(
      type: wire,
      peerId: peerId,
      name: displayName,
      hash: hash.isEmpty ? null : hash,
      payload: payload,
    );
    // notif.ack does not require auth; other notif frames use notification list.
    final requireAuth = wire != _SyncType.notifAck;
    await _fanout(env, requireAuth: requireAuth);
  }

  String? _mapNotificationType(String apiType) {
    switch (apiType) {
      case 'notification/post':
        return _SyncType.notifPost;
      case 'notification/dismiss':
        return _SyncType.notifDismiss;
      case 'notification/clear_all':
        return _SyncType.notifClear;
      case 'notification/ack':
        return _SyncType.notifAck;
      case 'notification/config':
        return _SyncType.notifConfig;
      default:
        return null;
    }
  }

  List<String> _authIdsForType(String type) {
    switch (type) {
      case _SyncType.history:
        return clipboardSyncPeerIds;
      case _SyncType.notifPost:
      case _SyncType.notifDismiss:
      case _SyncType.notifClear:
      case _SyncType.notifConfig:
        return notificationSyncPeerIds;
      default:
        return authorizedPeerIds;
    }
  }

  Future<void> _fanout(_SyncEnvelope env, {required bool requireAuth}) async {
    final data = _encodeFrame(env);
    if (data == null) return;
    final auth = _authIdsForType(env.type);
    final targets = requireAuth
        ? availablePeers
            .where((p) => auth.contains(p.peerId))
            .map((p) => p.peerId)
            .toList()
        : _discoveredPeers.keys.toList();

    if (targets.isEmpty) {
      if (env.type == _SyncType.history || env.type == _SyncType.notifPost) {
        for (final id in auth) {
          _enqueuePending(data, env.type, id, env.hash);
        }
      }
      triggerCrossBandDiscovery();
      return;
    }

    for (final id in targets) {
      await _deliver(data, type: env.type, peerId: id, hash: env.hash);
    }
  }

  Future<bool> _deliver(List<int> data,
      {required String type,
      required String peerId,
      String? hash}) async {
    final session = _sessions[peerId];
    if (session != null) {
      try {
        session.socket.add(data);
        await session.socket.flush();
        return true;
      } catch (_) {
        await _closeSession(peerId, scheduleReconnect: true);
      }
    }
    _enqueuePending(data, type, peerId, hash);
    final peer = _discoveredPeers[peerId];
    if (peer != null) {
      unawaited(_dial(peer.host, peer.port, reason: 'deliver'));
    } else {
      triggerCrossBandDiscovery();
    }
    _scheduleReconnect(peerId);
    return false;
  }

  void _enqueuePending(
      List<int> data, String type, String peerId, String? hash) {
    final cutoff = DateTime.now().subtract(_pendingTtl);
    _pendingQueue.removeWhere((f) => f.enqueueAt.isBefore(cutoff));
    if (hash != null && hash.isNotEmpty) {
      _pendingQueue.removeWhere((f) => f.peerId == peerId && f.hash == hash);
    }
    final perPeer = _pendingQueue.where((f) => f.peerId == peerId).length;
    if (perPeer >= _pendingMax) return;
    _pendingQueue.add(_PendingFrame(
      peerId: peerId,
      data: data,
      type: type,
      hash: hash,
      enqueueAt: DateTime.now(),
    ));
  }

  Future<void> _flushPending(String peerId) async {
    final session = _sessions[peerId];
    if (session == null) return;

    final allowClipboard = clipboardSyncPeerIds.contains(peerId);
    final allowNotification = notificationSyncPeerIds.contains(peerId);

    final cutoff = DateTime.now().subtract(_pendingTtl);
    final due = _pendingQueue
        .where((f) => f.peerId == peerId && !f.enqueueAt.isBefore(cutoff))
        .where((f) {
          if (f.type == _SyncType.history) return allowClipboard;
          if (f.type == _SyncType.notifPost ||
              f.type == _SyncType.notifDismiss ||
              f.type == _SyncType.notifClear ||
              f.type == _SyncType.notifConfig) {
            return allowNotification;
          }
          return true;
        })
        .toList();
    if (due.isNotEmpty) {
      appLog('Flushing ${due.length} pending frame(s) to $peerId');
      for (final frame in due) {
        try {
          session.socket.add(frame.data);
          if (frame.type != _SyncType.history &&
              frame.type != _SyncType.notifPost) {
            _pendingQueue.remove(frame);
          }
        } catch (_) {
          return;
        }
      }
    }

    // Persisted text frames (SQLite) — clipboard auth only
    if (allowClipboard) {
      final persisted =
          await PendingTextSyncRepository.instance.fetchByPeer(peerId);
      for (final entry in persisted) {
        final payload = _encrypt(entry.data);
        if (payload == null) continue;
        final env = _SyncEnvelope.make(
          type: _SyncType.history,
          peerId: this.peerId,
          name: displayName,
          hash: entry.hash,
          payload: payload,
        );
        final data = _encodeFrame(env);
        if (data == null) continue;
        try {
          session.socket.add(data);
        } catch (_) {
          return;
        }
      }
    }

    // Persisted notification posts (SQLite offline queue) — notification auth only
    if (!allowNotification) return;
    final notifPending =
        await NotificationRepository.instance.fetchAllPendingSync();
    if (notifPending.isNotEmpty) {
      appLog(
          'Flushing ${notifPending.length} pending notification(s) to $peerId');
    }
    for (final row in notifPending) {
      final content = row['content'] as String? ?? '';
      final hash = (row['hash'] as String?) ??
          (row['notification_id'] as String?) ??
          '';
      if (content.isEmpty || hash.isEmpty) continue;
      final payload = _encrypt(content);
      if (payload == null) continue;
      final env = _SyncEnvelope.make(
        type: _SyncType.notifPost,
        peerId: this.peerId,
        name: displayName,
        hash: hash,
        payload: payload,
      );
      final data = _encodeFrame(env);
      if (data == null) continue;
      try {
        session.socket.add(data);
      } catch (_) {
        return;
      }
    }
  }

  void _handleAck(String hash) {
    if (hash.isEmpty) return;
    final before = _pendingQueue.length;
    _pendingQueue.removeWhere((f) => f.hash == hash);
    if (_pendingQueue.length != before) {
      appLog('ACK cleared pending for hash ${hash.substring(0, hash.length.clamp(0, 8))}');
    }
    unawaited(PendingTextSyncRepository.instance.removeByHash(hash));
  }

  Future<bool> sendTextToPeer(String content, {required String peerId}) async {
    if (!isEnabled) return false;
    final hash = sha256.convert(utf8.encode(content)).toString();
    final payload = _encrypt(content);
    if (payload == null) return false;
    final env = _SyncEnvelope.make(
      type: _SyncType.history,
      peerId: this.peerId,
      name: displayName,
      hash: hash,
      payload: payload,
    );
    final data = _encodeFrame(env);
    if (data == null) return false;
    return _deliver(data, type: env.type, peerId: peerId, hash: hash);
  }

  Future<bool> sendFileToPeer(File file, {required String peerId}) async {
    appLog('sendFileToPeer stubbed in sync v2', level: 'warning');
    return false;
  }

  Future<void> setClipboardSyncTarget(String peerId,
      {required bool enabled}) async {
    final updated = List<String>.from(clipboardSyncPeerIds);
    if (enabled) {
      if (!updated.contains(peerId)) updated.add(peerId);
    } else {
      updated.remove(peerId);
    }
    clipboardSyncPeerIds = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('clipboardSyncPeerIds', clipboardSyncPeerIds);
    await prefs.setStringList('authorizedPeerIds', authorizedPeerIds);
    triggerCrossBandDiscovery();
    if (enabled && _sessions.containsKey(peerId)) {
      unawaited(_flushPending(peerId));
    }
  }

  Future<void> setNotificationSyncTarget(String peerId,
      {required bool enabled}) async {
    final updated = List<String>.from(notificationSyncPeerIds);
    if (enabled) {
      if (!updated.contains(peerId)) updated.add(peerId);
    } else {
      updated.remove(peerId);
    }
    notificationSyncPeerIds = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'notificationSyncPeerIds', notificationSyncPeerIds);
    await prefs.setStringList('authorizedPeerIds', authorizedPeerIds);
    triggerCrossBandDiscovery();
    if (enabled && _sessions.containsKey(peerId)) {
      unawaited(_flushPending(peerId));
    }
  }

  /// Legacy: toggles both clipboard and notification for [peerId].
  Future<void> setSyncTarget(String peerId, {required bool enabled}) async {
    await setClipboardSyncTarget(peerId, enabled: enabled);
    await setNotificationSyncTarget(peerId, enabled: enabled);
  }

  Future<void> removeAuthorizedPeer(String peerId) async {
    clipboardSyncPeerIds =
        List<String>.from(clipboardSyncPeerIds)..remove(peerId);
    notificationSyncPeerIds =
        List<String>.from(notificationSyncPeerIds)..remove(peerId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('clipboardSyncPeerIds', clipboardSyncPeerIds);
    await prefs.setStringList(
        'notificationSyncPeerIds', notificationSyncPeerIds);
    await prefs.setStringList('authorizedPeerIds', authorizedPeerIds);
  }

  Future<void> updateDeviceName(String name) async {
    final newName = name.trim();
    if (newName.isEmpty || newName == displayName) return;
    displayName = newName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceName', newName);
    if (isEnabled) {
      await stop();
      await Future.delayed(const Duration(seconds: 1));
      await start();
    }
  }

  // -----------------------------------------------------------------------
  // Codec / crypto
  // -----------------------------------------------------------------------

  List<int>? _encodeFrame(_SyncEnvelope env) {
    try {
      final jsonBytes = utf8.encode(jsonEncode(env.toJson()));
      final header = ByteData(4)..setUint32(0, jsonBytes.length, Endian.big);
      return [...header.buffer.asUint8List(), ...jsonBytes];
    } catch (_) {
      return null;
    }
  }

  _SyncEnvelope? _decodeEnvelope(List<int> data) {
    try {
      final map = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      return _SyncEnvelope.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  static encrypt.Key _key() {
    final hash = sha256.convert(utf8.encode(_hardcodedSecret));
    return encrypt.Key(Uint8List.fromList(hash.bytes));
  }

  String? _encrypt(String text) {
    try {
      final key = _key();
      final iv = encrypt.IV.fromLength(12);
      final encrypter =
          encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
      final encrypted = encrypter.encrypt(text, iv: iv);
      final combined = Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
      return base64Encode(combined);
    } catch (_) {
      return null;
    }
  }

  String? _decrypt(String base64String) {
    try {
      final key = _key();
      final data = base64Decode(base64String);
      if (data.length <= 28) return null;
      final iv = encrypt.IV(data.sublist(0, 12));
      final encryptedBytes = data.sublist(12);
      final encrypter =
          encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
      return encrypter.decrypt(encrypt.Encrypted(encryptedBytes), iv: iv);
    } catch (_) {
      return null;
    }
  }

  // Kept for any external callers that used the old static helpers.
  static String? encryptStatic(String text) => instance._encrypt(text);
  static String? decryptStatic(String text) => instance._decrypt(text);

  // -----------------------------------------------------------------------
  // Endpoint cache
  // -----------------------------------------------------------------------

  Future<void> _persistEndpoint(
      String peerId, String name, String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _readEndpointCache();
    list.removeWhere((e) => e['peerId'] == peerId);
    list.add({
      'peerId': peerId,
      'name': name,
      'host': host,
      'port': port,
      'ts': DateTime.now().millisecondsSinceEpoch / 1000.0,
    });
    await prefs.setString(_endpointCacheKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> _readEndpointCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_endpointCacheKey);
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final cutoff = DateTime.now()
          .subtract(_endpointCacheTtl)
          .millisecondsSinceEpoch /
          1000.0;
      return list.where((e) => ((e['ts'] as num?)?.toDouble() ?? 0) >= cutoff).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _loadEndpointCache() async {
    for (final e in await _readEndpointCache()) {
      final id = e['peerId'] as String?;
      final name = e['name'] as String?;
      final host = e['host'] as String?;
      final p = e['port'] as int?;
      if (id == null || name == null || host == null || p == null) continue;
      if (id == peerId) continue;
      _recordPeer(id, name, host, p);
      unawaited(_dial(host, p, reason: 'cache'));
    }
  }
}
