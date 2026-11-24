part of '../sync_manager.dart';

extension SyncNetworkRecoveryMethods on SyncManager {
  void _probeNetworkSessions({String trigger = 'unspecified'}) {
    // Repeated Scan taps share one deadline instead of postponing recovery.
    if (_networkProbeTimer != null || !_runLifecycle.isActive) return;
    final now = DateTime.now();
    final fromRelayPeer = trigger == 'relayPeerAvailable';
    if (fromRelayPeer) {
      if (!shouldStartRelayPeerProbe(_lastRelayPeerProbe, now)) return;
      _lastRelayPeerProbe = now;
    }
    final epoch = _runLifecycle.epoch;
    final captured = Map.of(_sessions);
    final delay = networkProbeDelay(
      hasRelaySession: captured.values.any((s) => s.host.startsWith('relay:')),
    );
    String secs(DateTime t) =>
        (now.difference(t).inMilliseconds / 1000).toStringAsFixed(1);
    appLog(
      'Probe start (trigger=$trigger): [${captured.entries.map((e) => '${e.key.substring(0, e.key.length.clamp(0, 8))}@${e.value.host.startsWith('relay:') ? 'relay' : e.value.host} age=${secs(e.value.createdAt)}s pong=${secs(e.value.lastPong)}s').join(', ')}]',
      console: true,
    );
    final pongs = {for (final e in captured.entries) e.key: e.value.lastPong};
    final inbound = {
      for (final e in captured.entries) e.key: e.value.lastInbound,
    };
    unawaited(_sendPings());
    _networkProbeTimer = Timer(delay, () {
      _networkProbeTimer = null;
      if (!_isRunCurrent(epoch)) return;
      for (final e in captured.entries) {
        final current = _sessions[e.key];
        if (current != null &&
            shouldExpireNetworkProbe(
              capturedConnection: e.value,
              currentConnection: current,
              previousPong: pongs[e.key]!,
              currentPong: current.lastPong,
              previousInbound: inbound[e.key]!,
              currentInbound: current.lastInbound,
            )) {
          final at = DateTime.now();
          String ago(DateTime t) =>
              (at.difference(t).inMilliseconds / 1000).toStringAsFixed(1);
          unawaited(
            _closeSession(
              e.key,
              scheduleReconnect: true,
              reason:
                  'probeNoResponse(trigger=$trigger, lastPong=${ago(current.lastPong)}s, lastInbound=${ago(current.lastInbound)}s)',
            ),
          );
        }
      }
      // Refreshing here would re-announce peers and re-trigger this probe.
      if (!fromRelayPeer) _relay?.refreshPeers();
    });
  }

  void _startConnectivityMonitoring() {
    _connectivitySub?.cancel();
    final epoch = _runLifecycle.epoch;
    String? previous;
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!_isRunCurrent(epoch)) return;
      final signature = (results.map((r) => r.name).toSet().toList()..sort())
          .join(',');
      final changed = previous != null && previous != signature;
      previous = signature;
      if (!changed ||
          results.every((r) => r == ConnectivityResult.none) ||
          !isEnabled) {
        return;
      }
      _probeNetworkSessions(trigger: 'connectivityChanged');
      _relay?.networkChanged();
      unawaited(_recoverAfterNetworkRestore(epoch));
    });
  }

  /// Authorized cache dials only — full /24 scan is user refresh.
  Future<void> _recoverAfterNetworkRestore(int epoch) async {
    if (!_isRunCurrent(epoch)) return;
    await _loadEndpointCache();
    if (!_isRunCurrent(epoch)) return;
    final missing = authorizedPeerIds
        .where((id) => !_sessions.containsKey(id))
        .toList();
    if (missing.isEmpty) {
      appLog('Network restored; sessions intact, skip discovery');
      return;
    }
    var cacheDialCount = 0;
    final disk = await _readEndpointCache();
    if (!_isRunCurrent(epoch)) return;
    final byId = {
      for (final e in disk)
        if (e['peerId'] is String) e['peerId'] as String: e,
    };
    for (final id in missing) {
      if (!_isRunCurrent(epoch)) return;
      final mem = _discoveredPeers[id];
      if (mem != null) {
        cacheDialCount++;
        unawaited(
          _dial(
            mem.host,
            mem.port,
            reason: 'cache_dial',
            peerId: id,
            runEpoch: epoch,
          ),
        );
        continue;
      }
      final e = byId[id];
      final host = e?['host'] as String?;
      final p = e?['port'] as int?;
      if (host != null && p != null) {
        cacheDialCount++;
        unawaited(
          _dial(host, p, reason: 'cache_dial', peerId: id, runEpoch: epoch),
        );
      }
    }
    appLog('Network restored; authorized cache_dial count=$cacheDialCount');
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(SyncManager._pingInterval, (_) => _sendPings());
  }

  Future<void> _sendPings() async {
    final env = SyncEnvelope.make(type: SyncType.ping, peerId: peerId);
    final data = syncEncodeFrame(env);
    if (data == null) return;
    final stale = DateTime.now().subtract(SyncManager._pingInterval * 3);
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      final session = _sessions[id];
      if (session == null) continue;
      if (session.lastPong.isBefore(stale)) {
        await _closeSession(
          id,
          scheduleReconnect: true,
          keepaliveDriven: true,
          reason: 'keepaliveTimeout',
        );
        continue;
      }
      try {
        session.socket.add(data);
      } catch (e) {
        appLog(
          'ping send failed to ${id.substring(0, id.length.clamp(0, 8))}: $e',
          level: 'warning',
        );
        await _closeSession(
          id,
          scheduleReconnect: true,
          keepaliveDriven: true,
          reason: 'pingSendFailed',
        );
        continue;
      }
      unawaited(_retryStalePendingHistory(id));
    }
  }
}
