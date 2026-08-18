import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'clipboard_manager.dart';
import 'database/clipboard_repository.dart';
import 'database/file_transfer_repository.dart';
import 'database/notification_repository.dart';
import 'database/pending_sync_repository.dart';
import 'database/pending_text_sync_repository.dart';
import 'log_manager.dart';
import 'notification_manager.dart';
import 'storage_paths.dart';
import 'sync/crypto.dart';
import 'sync/protocol.dart';

export 'sync/protocol.dart' show SyncEnvelope, SyncType;

part 'sync/discovery.dart';
part 'sync/file_transfer.dart';
part 'sync/session.dart';
part 'sync/reliability.dart';


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
  /// True while this device is the sender (outbound transfer progress).
  final bool isOutgoing;

  FileProgress({
    required this.fileId,
    required this.fileName,
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    this.isCompleted = false,
    this.isFailed = false,
    this.isOutgoing = false,
  });
}

/// Inbound chunked-file transfer state (see sync/file_transfer.dart).
class _IncomingFileTransfer {
  final String peerId;
  final String senderName;
  final String fileId;
  final String fileName;
  final int fileSize;
  final int chunkSize;
  final int chunkCount;
  final String sha256Hex;
  final File partFile;
  final Set<int> received = {};
  Timer? idleTimer;

  _IncomingFileTransfer({
    required this.peerId,
    required this.senderName,
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.chunkSize,
    required this.chunkCount,
    required this.sha256Hex,
    required this.partFile,
  });
}

class _DigestCollector implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
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
  final bool isClient;

  _Session({
    required this.peerId,
    required this.host,
    required this.port,
    required this.socket,
    required this.isClient,
  });
}

/// Buffers `history` frames after we send `history.fetch`, so catch-up can
/// ingest via [ClipboardManager.handleRemoteSyncBatch] instead of N clipboard writes.
class _HistoryFetchCatchUp {
  final List<({String text, String hash})> items = [];
  Timer? debounce;
  Timer? maxWait;
  int totalChars = 0;
}

// ---------------------------------------------------------------------------
// SyncManager
// ---------------------------------------------------------------------------

class SyncManager with WidgetsBindingObserver {
  static final SyncManager instance = SyncManager._();
  SyncManager._();

  static const MethodChannel _fgsChannel =
      MethodChannel('com.clipyclone.clipy_android/sync_service');

  static const String _pairingSecretKey = 'clipy.sync.pairingSecret';
  static const String _endpointCacheKey = 'clipy.peerEndpoints.v2';
  static const Duration _endpointCacheTtl = Duration(hours: 24);
  static const Duration _discoveryDebounce = Duration(milliseconds: 600);
  static const Duration _handshakeTimeout = Duration(seconds: 2);
  static const Duration _connectTimeout = Duration(seconds: 3);
  static const Duration _scanConnectTimeout = Duration(milliseconds: 350);
  static const Duration _pingInterval = Duration(seconds: 30);
  static const Duration _pendingTtl = Duration(hours: 24);
  static const int _pendingMax = 80;
  static const int _scanConcurrency = 24;
  static const Duration _dialDedupTtl = Duration(seconds: 4);
  static const Duration _minReconnectInterval = Duration(seconds: 2);
  static const int _syncTickBusyMs = 30000;
  static const int _syncTickIdleMs = 90000;

  // File transfer (see sync/file_transfer.dart).
  static const int fileChunkSize = 512 * 1024;
  static const int fileMaxBytes = 512 * 1024 * 1024;
  static const Duration _fileIncomingIdleTimeout = Duration(minutes: 2);
  final Map<String, _IncomingFileTransfer> _incomingFiles = {};
  final Map<String, Completer<bool>> _fileAckWaiters = {};
  /// Cached at init so file.meta handlers can resolve the receive directory
  /// synchronously (StoragePaths goes through a MethodChannel).
  String? _receiveDirPath;

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
  final Map<String, Set<String>> _inFlightHashes = {};
  final Map<String, DateTime> _lastReconnectAttempt = {};

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
  final SyncCrypto _crypto = SyncCrypto();
  String get pairingSecret => _crypto.pairingSecret;
  set pairingSecret(String v) => _crypto.pairingSecret = v;

  final _lastHistoryFetchAt = <String, DateTime>{};
  /// Catch-up only — must not match FGS syncTick (30s) or Mac will replay
  /// ~200 history frames every tick.
  static const _historyFetchThrottle = Duration(minutes: 15);
  static const _pendingAckRetryAge = Duration(seconds: 45);
  final _lastHistoryFetchResponse = <String, DateTime>{};
  static const _historyFetchRespondThrottle = Duration(seconds: 30);
  static const _historyFetchRespondLimit = 200;

  /// Per-peer coalesce after we send `history.fetch` (silence debounce + hard max).
  final Map<String, _HistoryFetchCatchUp> _historyFetchCatchUp = {};
  static const _historyFetchCatchUpDebounce = Duration(seconds: 2);
  static const _historyFetchCatchUpMaxWait = Duration(seconds: 8);

  DateTime? _lastSyncTickDiscovery;
  static const _syncTickDiscoveryMinGap = Duration(minutes: 5);

  List<String> get authorizedPeerIds =>
      {...clipboardSyncPeerIds, ...notificationSyncPeerIds}.toList()..sort();

  /// A full /24 scan writes a dial-dedup entry per host (~254 keys). They are
  /// only meaningful for seconds; drop the stale ones after each scan instead
  /// of letting the per-'ip:port' timestamp maps grow forever.
  void _pruneStaleTimestampMaps() {
    final now = DateTime.now();
    _lastDialAt.removeWhere(
        (_, t) => now.difference(t) > const Duration(minutes: 1));
    _lastReconnectAttempt.removeWhere(
        (_, t) => now.difference(t) > const Duration(minutes: 1));
    _lastHistoryFetchResponse.removeWhere(
        (_, t) => now.difference(t) > const Duration(minutes: 5));
  }

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
    // Regenerate if empty OR not a canonical UUID. Protocol-v1 stored peerId as
    // "Android-<8hex>" / "iOS-<8hex>"; those legacy values revive verbatim and
    // corrupt session identity (adoptSession dedup, role arbitration, auth lists).
    if (peerId.isEmpty || !_isValidUuid(peerId)) {
      if (peerId.isNotEmpty) {
        appLog('peerId invalid format, regenerating: $peerId', level: 'warning');
        await _pruneLegacyAuthorizedPeerIds(prefs, oldPeerId: peerId);
      }
      peerId = const Uuid().v4();
      await prefs.setString('peerId', peerId);
    }
    displayName = prefs.getString('deviceName') ??
        (Platform.isAndroid ? 'Android' : 'Device');
    pairingSecret = prefs.getString(_pairingSecretKey) ?? '';
    _receiveDirPath = (await StoragePaths.appStorageDirectory()).path;
    await _migrateAuthorizedPeerIds(prefs);
    await _migrateDualSyncAuth(prefs);
    clipboardSyncPeerIds =
        prefs.getStringList('clipboardSyncPeerIds') ?? [];
    notificationSyncPeerIds =
        prefs.getStringList('notificationSyncPeerIds') ?? [];
    await _pruneLegacyAuthorizedPeerIds(prefs);
    WidgetsBinding.instance.addObserver(this);
    if (isEnabled) {
      await start();
    }
  }

  /// Canonical UUID v4 format: 8-4-4-4-12 hex digits with hyphens.
  static final _uuidRegex =
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static bool _isValidUuid(String id) => _uuidRegex.hasMatch(id);

  /// Remove legacy non-UUID entries (e.g. "Android-066f3806", raw display names)
  /// from all three auth lists. These point at identities that no longer exist
  /// after peerId regeneration or protocol-v1→v2 upgrade, and would silently
  /// block fanout to the real peer (which now has a proper UUID).
  Future<void> _pruneLegacyAuthorizedPeerIds(SharedPreferences prefs,
      {String? oldPeerId}) async {
    bool prune(List<String> list, String key) {
      final before = list.length;
      final kept = list.where(_isValidUuid).toList();
      if (oldPeerId != null) kept.remove(oldPeerId);
      if (kept.length == before) return false;
      prefs.setStringList(key, kept);
      return true;
    }

    final clip = prefs.getStringList('clipboardSyncPeerIds') ?? [];
    final notif = prefs.getStringList('notificationSyncPeerIds') ?? [];
    final union = prefs.getStringList('authorizedPeerIds') ?? [];
    var changed = false;
    changed = prune(clip, 'clipboardSyncPeerIds') || changed;
    changed = prune(notif, 'notificationSyncPeerIds') || changed;
    changed = prune(union, 'authorizedPeerIds') || changed;
    // Legacy v1 list stored display names, never valid peerIds — clear once.
    if (prefs.getStringList('authorizedDevices') != null) {
      await prefs.remove('authorizedDevices');
      changed = true;
    }
    if (changed) {
      clipboardSyncPeerIds = prefs.getStringList('clipboardSyncPeerIds') ?? [];
      notificationSyncPeerIds =
          prefs.getStringList('notificationSyncPeerIds') ?? [];
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


  /// Called from FGS / Application after process rebuild. Idempotent.
  Future<void> ensureStartedIfEnabled() async {
    if (!isEnabled) return;
    if (_server != null) return;
    await start();
  }

  /// FGS tick: reconnect missing peers and flush pending. Does **not**
  /// send history.fetch (that caused Mac to push 200 entries every 30s).
  ///
  /// Returns next delay in ms: busy 30s or idle 90s.
  Future<int> onSyncTick() async {
    if (!isEnabled) return _syncTickIdleMs;
    // Zombie-socket guard: `_startServer`'s `onDone`/`onError` null out
    // `_server` when the listening stream closes, so a null check here is a
    // reliable liveness signal and triggers a rebind without platform re-entry.
    if (_server == null) {
      await _rebindServer();
      return _syncTickBusyMs;
    }
    var busy = false;
    var needDiscovery = false;
    final authorized = authorizedPeerIds;
    for (final id in authorized) {
      if (_sessions.containsKey(id)) {
        final pending = await PendingSyncRepository.instance.pendingHashes(id);
        if (pending.isNotEmpty ||
            (_inFlightHashes[id]?.isNotEmpty ?? false)) {
          busy = true;
        }
        unawaited(_flushPending(id));
      } else {
        busy = true;
        needDiscovery = true;
        final cached = _discoveredPeers[id];
        if (cached != null) {
          unawaited(_dial(cached.host, cached.port,
              reason: 'syncTick', peerId: id));
        }
      }
    }
    if (needDiscovery) {
      final now = DateTime.now();
      final last = _lastSyncTickDiscovery;
      if (last == null || now.difference(last) >= _syncTickDiscoveryMinGap) {
        _lastSyncTickDiscovery = now;
        // Authorized cache dial only — full /24 is user refresh.
        appLog('syncTick authorized cache dial (peers missing session)');
        triggerCrossBandDiscovery(scanFullSubnet: false);
      }
    }
    final next = busy ? _syncTickBusyMs : _syncTickIdleMs;
    return next;
  }

  Future<void> start() async {
    appLog('SyncManager v2 starting...');
    unawaited(PendingSyncRepository.instance.cleanOld());
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

  /// Re-bind the listening socket and auxiliary loops WITHOUT calling back
  /// into the platform (i.e. no `_startForegroundService()`). Safe to call
  /// from within an inbound `syncTick` MethodChannel handler — `start()`
  /// would otherwise re-enter Kotlin (`startForegroundSync`) while the outer
  /// `syncTick` Result is still pending, risking a deadlocked tick loop.
  /// `start()` is still used for user/init paths where FGS may not be up yet.
  Future<void> _rebindServer() async {
    appLog('Rebinding ServerSocket (no platform re-entry)...');
    final ok = await _startServer();
    if (!ok) {
      appLog('Server failed to rebind', level: 'error');
      return;
    }
    _startConnectivityMonitoring();
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
    for (final e in _historyFetchCatchUp.entries) {
      e.value.debounce?.cancel();
      e.value.maxWait?.cancel();
      if (e.value.items.isNotEmpty) {
        unawaited(_ingestHistoryFetchCatchUp(e.key, List.of(e.value.items)));
      }
    }
    _historyFetchCatchUp.clear();
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
        unawaited(_recoverAfterNetworkRestore());
      }
    });
  }

  /// Authorized cache dials only — full /24 scan is user refresh.
  Future<void> _recoverAfterNetworkRestore() async {
    await _loadEndpointCache();
    final missing =
        authorizedPeerIds.where((id) => !_sessions.containsKey(id)).toList();
    if (missing.isEmpty) {
      appLog('Network restored; sessions intact, skip discovery');
      return;
    }
    var cacheDialCount = 0;
    final disk = await _readEndpointCache();
    final byId = {
      for (final e in disk)
        if (e['peerId'] is String) e['peerId'] as String: e,
    };
    for (final id in missing) {
      final mem = _discoveredPeers[id];
      if (mem != null) {
        cacheDialCount++;
        unawaited(
            _dial(mem.host, mem.port, reason: 'cache_dial', peerId: id));
        continue;
      }
      final e = byId[id];
      final host = e?['host'] as String?;
      final p = e?['port'] as int?;
      if (host != null && p != null) {
        cacheDialCount++;
        unawaited(_dial(host, p, reason: 'cache_dial', peerId: id));
      }
    }
    appLog('Network restored; authorized cache_dial count=$cacheDialCount');
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPings());
  }

  Future<void> _sendPings() async {
    final env = SyncEnvelope.make(type: SyncType.ping, peerId: peerId);
    final data = syncEncodeFrame(env);
    if (data == null) return;
    final stale = DateTime.now().subtract(_pingInterval * 3);
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      final session = _sessions[id];
      if (session == null) continue;
      if (session.lastPong.isBefore(stale)) {
        await _closeSession(id, scheduleReconnect: true, keepaliveDriven: true);
        continue;
      }
      try {
        session.socket.add(data);
      } catch (e) {
        appLog('ping send failed to ${id.substring(0, id.length.clamp(0, 8))}: $e',
            level: 'warning');
        await _closeSession(id, scheduleReconnect: true, keepaliveDriven: true);
        continue;
      }
      unawaited(_retryStalePendingHistory(id));
    }
  }

  void _handleFrame(List<int> data,
      {required String from, required String host}) {
    final env = syncDecodeEnvelope(data);
    if (env == null || env.v != SyncEnvelope.version) return;

    switch (env.type) {
      case SyncType.ping:
        final pong =
            SyncEnvelope.make(type: SyncType.pong, peerId: peerId);
        final d = syncEncodeFrame(pong);
        final session = _sessions[from];
        if (d != null && session != null) {
          try {
            session.socket.add(d);
          } catch (e) {
            appLog('pong send failed to ${from.substring(0, from.length.clamp(0, 8))}: $e',
                level: 'warning');
          }
        }
        break;
      case SyncType.pong:
        final session = _sessions[from];
        if (session != null) session.lastPong = DateTime.now();
        break;
      case SyncType.ack:
        if (env.hash != null) _handleAck(env.hash!, from: from);
        break;
      case SyncType.history:
      case SyncType.historyDirect:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decrypt(payload);
        if (text == null) {
          appLog('history decrypt failed from ${from.substring(0, from.length.clamp(0, 8))}',
              level: 'warning');
          return;
        }
        final hash = env.hash ?? '';
        if (_bufferHistoryFetchCatchUp(from, text, hash)) {
          break;
        }
        unawaited(() async {
          final ok = await ClipboardManager.instance
              .handleRemoteSync(text, hash);
          if (ok) {
            _replyAck(from, hash.isEmpty ? null : hash);
          } else {
            appLog(
                'history persist failed; withholding ACK hash=${hash.substring(0, hash.length.clamp(0, 8))}',
                level: 'warning');
          }
        }());
        break;
      case SyncType.notifPost:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decrypt(payload);
        if (text == null) return;
        NotificationManager.instance
            .handleRemoteNotification(text, env.peerId);
        break;
      case SyncType.notifDismiss:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decrypt(payload);
        if (text == null) return;
        NotificationManager.instance.handleRemoteDismiss(text);
        break;
      case SyncType.notifClear:
        NotificationManager.instance.clearAll();
        break;
      case SyncType.notifAck:
        if (env.hash != null) {
          _handleAck(env.hash!, from: from);
          NotificationManager.instance.handleAck(env.hash!);
        }
        break;
      case SyncType.notifConfig:
        appLog('Ignored remote notification config', level: 'warning');
        break;
      case SyncType.historyFetch:
        unawaited(_respondToHistoryFetch(from));
        break;
      case SyncType.fileMeta:
        _handleFileMetaFrame(env, from: from);
        break;
      case SyncType.fileChunk:
        _handleFileChunkFrame(env, from: from);
        break;
      case SyncType.fileAck:
        _handleFileAckFrame(env, from: from);
        break;
      case SyncType.hello:
      case SyncType.welcome:
        if (env.name != null && env.port != null) {
          _recordPeer(env.peerId, env.name!, host, env.port!);
        }
        break;
    }
  }

  /// Open a short coalesce window for [peerId] after we send `history.fetch`.
  void _beginHistoryFetchCatchUp(String peerId) {
    final prev = _historyFetchCatchUp.remove(peerId);
    prev?.debounce?.cancel();
    prev?.maxWait?.cancel();
    if (prev != null && prev.items.isNotEmpty) {
      unawaited(_ingestHistoryFetchCatchUp(peerId, prev.items));
    }
    final buf = _HistoryFetchCatchUp();
    _historyFetchCatchUp[peerId] = buf;
    buf.maxWait = Timer(_historyFetchCatchUpMaxWait, () {
      unawaited(_flushHistoryFetchCatchUp(peerId));
    });
  }

  /// Hard char cap for one catch-up window. The peer may stream up to 200
  /// frames within the 8s window; without a cap the batch (plus the copies
  /// handleRemoteSyncBatch makes) grows without bound. Over-cap frames are
  /// dropped WITHOUT acking, so the sender's pending queue re-delivers them.
  static const _historyFetchCatchUpMaxChars = 8 * 1024 * 1024;

  /// Returns true when the frame was buffered for catch-up (caller must not
  /// also run the live single-item path).
  bool _bufferHistoryFetchCatchUp(String peerId, String text, String hash) {
    final buf = _historyFetchCatchUp[peerId];
    if (buf == null) return false;
    if (buf.totalChars < _historyFetchCatchUpMaxChars) {
      buf.items.add((text: text, hash: hash));
      buf.totalChars += text.length;
    }
    buf.debounce?.cancel();
    buf.debounce = Timer(_historyFetchCatchUpDebounce, () {
      unawaited(_flushHistoryFetchCatchUp(peerId));
    });
    return true;
  }

  Future<void> _flushHistoryFetchCatchUp(String peerId) async {
    final buf = _historyFetchCatchUp.remove(peerId);
    if (buf == null) return;
    buf.debounce?.cancel();
    buf.maxWait?.cancel();
    if (buf.items.isEmpty) return;
    await _ingestHistoryFetchCatchUp(peerId, buf.items);
  }

  Future<void> _ingestHistoryFetchCatchUp(
      String peerId, List<({String text, String hash})> items) async {
    appLog(
        'history.fetch catch-up flush ${peerId.substring(0, peerId.length.clamp(0, 8))}: ${items.length} frames');
    try {
      await ClipboardManager.instance.handleRemoteSyncBatch(items);
      for (final item in items) {
        if (item.hash.isNotEmpty) _replyAck(peerId, item.hash);
      }
    } catch (e) {
      appLog('history.fetch catch-up flush failed: $e', level: 'error');
      // Withhold ACKs so sender can retry via pending / next fetch.
    }
  }

  /// Replay recent text history to a peer that just (re)appeared (mirrors Mac).
  Future<void> _respondToHistoryFetch(String remotePeerId) async {
    if (!clipboardSyncPeerIds.contains(remotePeerId)) {
      appLog(
          'history.fetch from unauthorized ${remotePeerId.substring(0, remotePeerId.length.clamp(0, 8))}; ignoring',
          level: 'warning');
      return;
    }
    final last = _lastHistoryFetchResponse[remotePeerId];
    final now = DateTime.now();
    if (last != null && now.difference(last) < _historyFetchRespondThrottle) {
      return;
    }
    _lastHistoryFetchResponse[remotePeerId] = now;
    final session = _sessions[remotePeerId];
    if (session == null) return;
    final recent = await ClipboardRepository.instance
        .fetchRecentTexts(limit: _historyFetchRespondLimit);
    appLog(
        'sync.ack history.fetch from ${remotePeerId.substring(0, remotePeerId.length.clamp(0, 8))}: pushing ${recent.length} text entries');
    // Oldest first so the peer's list ends with the newest on top after ingest.
    var batchCount = 0;
    for (final entry in recent.reversed) {
      final payload = _encrypt(entry.text);
      if (payload == null) continue;
      final env = SyncEnvelope.make(
        type: SyncType.history,
        peerId: peerId,
        name: displayName,
        hash: entry.hash,
        payload: payload,
      );
      final data = syncEncodeFrame(env);
      if (data == null) continue;
      try {
        session.socket.add(data);
        // Drain as we go: queueing all 200 encoded frames before one flush
        // used to spike memory by the entire response size.
        if (++batchCount % 25 == 0) {
          try {
            await session.socket.flush();
          } catch (_) {}
        }
      } catch (e) {
        appLog('history.fetch push failed: $e', level: 'warning');
        return;
      }
    }
    try {
      await session.socket.flush();
    } catch (_) {}
  }

  void _replyAck(String peerId, String? hash) {
    if (hash == null || hash.isEmpty) return;
    final env =
        SyncEnvelope.make(type: SyncType.ack, peerId: this.peerId, hash: hash);
    final data = syncEncodeFrame(env);
    final session = _sessions[peerId];
    if (data == null || session == null) return;
    try {
      session.socket.add(data);
    } catch (e) {
      appLog('ack send failed to ${peerId.substring(0, peerId.length.clamp(0, 8))}: $e',
          level: 'warning');
    }
  }

  Future<void> broadcastSync(String content, String hash) async {
    if (!isEnabled) return;
    final payload = _encrypt(content);
    if (payload == null) return;
    final env = SyncEnvelope.make(
      type: SyncType.history,
      peerId: peerId,
      name: displayName,
      hash: hash,
      payload: payload,
    );
    await _fanout(env, requireAuth: true);
  }

  Future<void> broadcastNotificationMessage({
    required String type,
    required String content,
    required String hash,
  }) async {
    final wire = _mapNotificationType(type) ?? type;
    final payload = _encrypt(content);
    if (payload == null &&
        wire != SyncType.notifAck &&
        wire != SyncType.notifClear) {
      return;
    }
    final env = SyncEnvelope.make(
      type: wire,
      peerId: peerId,
      name: displayName,
      hash: hash.isEmpty ? null : hash,
      payload: payload,
    );
    // notif.ack does not require auth; other notif frames use notification list.
    final requireAuth = wire != SyncType.notifAck;
    await _fanout(env, requireAuth: requireAuth);
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


  String? _encrypt(String text) => _crypto.encryptText(text);
  String? _decrypt(String text) => _crypto.decryptText(text);

  Future<void> updatePairingSecret(String secret) async {
    final next = secret.trim();
    if (next == pairingSecret) return;
    pairingSecret = next;
    _crypto.clearKeyCache();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pairingSecretKey, next);
    if (isEnabled) {
      await stop();
      await Future.delayed(const Duration(seconds: 1));
      await start();
    }
  }

  static String? encryptStatic(String text) => instance._encrypt(text);
  static String? decryptStatic(String text) => instance._decrypt(text);

}
