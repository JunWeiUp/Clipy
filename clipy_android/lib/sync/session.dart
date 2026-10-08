part of '../sync_manager.dart';

extension SyncSessionMethods on SyncManager {
  // -----------------------------------------------------------------------
  // Server
  // -----------------------------------------------------------------------

  Future<bool> _startServer(int epoch) async {
    if (!_isRunCurrent(epoch)) return false;
    try {
      final previous = _server;
      await previous?.close();
      if (!_isRunCurrent(epoch)) return false;
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      if (!_isRunCurrent(epoch)) {
        await server.close();
        return false;
      }
      _server = server;
      appLog('Listening on 0.0.0.0:$port');
      // `onDone` must null out `_server` — otherwise the field stays non-null
      // after the listening stream closes, and `onSyncTick` would skip the
      // rebind, leaving :5566 refusing connections with the FGS alive.
      server.listen(
        (socket) => _onInbound(socket, epoch),
        onError: (e) {
          appLog('Server error: $e', level: 'error');
          if (identical(_server, server)) _server = null;
        },
        onDone: () {
          appLog('Server socket closed (onDone)', level: 'warning');
          if (identical(_server, server)) _server = null;
        },
      );
      return true;
    } catch (e) {
      if (_isRunCurrent(epoch)) {
        _server = null;
        appLog('Failed to bind :$port — $e', level: 'error');
      }
      return false;
    }
  }

  void _onInbound(Socket socket, int epoch) {
    if (!_isRunCurrent(epoch)) {
      unawaited(socket.close());
      return;
    }
    final host = socket.remoteAddress.address;
    appLog('Inbound from $host');
    unawaited(
      _performHandshake(
        socket,
        host: host,
        inbound: true,
        runEpoch: epoch,
        onHandshakeFailure: (f) {
          appLog('Inbound handshake failed from $host: $f', level: 'warning');
        },
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Dial / handshake / session
  // -----------------------------------------------------------------------

  /// Maps a SocketException's osError (errno) to a coarse failure label for
  /// diagnostics. Mirrors the Mac side's ConnectFailure. `timeout` covers VPN
  /// route hijack and firewall — when it dominates the scan summary, that's the
  /// VPN tell-tale.
  String _classifyConnectError(Object e) {
    if (e is SocketException) {
      final code = e.osError?.errorCode;
      if (code == null) return 'other';
      // ECONNREFUSED (111), ECONNRESET (104)
      if (code == 111 || code == 104) return 'refused';
      // EHOSTUNREACH (113), ENETUNREACH (101)
      if (code == 113 || code == 101) return 'unreachable';
      return 'other';
    }
    return 'other';
  }

  String? _resolvePeerId(String host, int peerPort) {
    for (final e in _sessions.entries) {
      if (e.value.host == host) return e.key;
    }
    for (final p in _discoveredPeers.values) {
      if (p.host == host && p.port == peerPort) return p.peerId;
    }
    return null;
  }

  bool _allowsProactiveDial(String reason, String? peerId) {
    if (reason == 'scan' || reason == 'direct') return true;
    if (peerId == null || peerId.isEmpty) return false;
    return authorizedPeerIds.contains(peerId);
  }

  Future<void> _dial(
    String host,
    int peerPort, {
    required String reason,
    String? peerId,
    Duration? timeout,
    void Function(String connectFailure)? onConnectFailure,
    void Function(String hsFailure)? onHandshakeFailure,
    int? runEpoch,
    bool bypassScanCooldown = false,
  }) async {
    final epoch = runEpoch ?? _runLifecycle.epoch;
    if (!_isRunCurrent(epoch)) return;
    final resolved =
        peerId ?? (reason == 'scan' ? null : _resolvePeerId(host, peerPort));
    if (!_allowsProactiveDial(reason, resolved)) return;

    final key = '$host:$peerPort';
    final now = DateTime.now();
    final last = _lastDialAt[key];
    if (last != null &&
        now.difference(last) < SyncManager._dialDedupTtl &&
        reason == 'scan' &&
        !bypassScanCooldown) {
      return;
    }
    _lastDialAt[key] = now;

    if (_sessions.values.any((s) => s.host == host)) return;

    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        peerPort,
        timeout: timeout ?? SyncManager._connectTimeout,
      );
    } catch (e) {
      if (!_isRunCurrent(epoch)) return;
      // SocketException with null osError + message "Connection timed out" or
      // "Connecting timed out" is the Dart-side timeout path (scanConnectTimeout).
      final isTimeout =
          (e is SocketException) &&
          (e.osError == null) &&
          (e.message.toLowerCase().contains('timed out'));
      final label = isTimeout ? 'timeout' : _classifyConnectError(e);
      if (reason == 'scan') {
        onConnectFailure?.call(label);
      } else {
        appLog(
          'Dial $reason $host:$peerPort failed: connect($label)',
          level: 'warning',
        );
        // A dead authorized endpoint is the auto-rediscover signal; scan/
        // direct dials have no stable peer identity to count against.
        if (resolved != null && authorizedPeerIds.contains(resolved)) {
          noteAuthorizedDialFailure();
        }
        if (resolved != null) {
          diagnostics.noteError(resolved, 'connect($label)', host: host);
        }
      }
      return;
    }
    if (!_isRunCurrent(epoch)) {
      await socket.close();
      return;
    }
    await _performHandshake(
      socket,
      host: host,
      inbound: false,
      runEpoch: epoch,
      onHandshakeFailure: reason == 'scan'
          ? onHandshakeFailure
          : (f) {
              appLog(
                'Dial $reason $host:$peerPort failed: handshake($f)',
                level: 'warning',
              );
              if (resolved != null) {
                diagnostics.noteError(resolved, 'handshake($f)', host: host);
              }
            },
    );
  }

  Future<void> _performHandshake(
    Socket socket, {
    required String host,
    required bool inbound,
    required int runEpoch,
    void Function(String failure)? onHandshakeFailure,
  }) async {
    if (!_isRunCurrent(runEpoch)) {
      await socket.close();
      return;
    }
    _handshakeSockets.add(socket);
    unawaited(
      socket.done.then<void>(
        (_) => _handshakeSockets.remove(socket),
        onError: (Object _) => _handshakeSockets.remove(socket),
      ),
    );
    final hello = SyncEnvelope.make(
      type: SyncType.hello,
      sessionPolicy: syncSessionPolicy,
      peerId: peerId,
      name: displayName,
      port: port,
    );
    final helloData = syncEncodeFrame(hello);
    if (helloData == null) {
      onHandshakeFailure?.call('writeFail');
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
          final frame = syncTryTakeFrame(buffer);
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
      onError: (e) {
        if (!firstFrame.isCompleted) firstFrame.complete(null);
        final id = adoptedPeerId;
        if (id != null && identical(_sessions[id]?.socket, socket)) {
          appLog(
            'Socket error from ${id.substring(0, id.length.clamp(0, 8))}: $e',
            level: 'warning',
          );
          diagnostics.noteError(id, 'socketError');
          unawaited(
            _closeSession(id, scheduleReconnect: true, keepaliveDriven: true),
          );
        }
      },
      onDone: () {
        if (!firstFrame.isCompleted) firstFrame.complete(null);
        final id = adoptedPeerId;
        if (id != null && identical(_sessions[id]?.socket, socket)) {
          appLog(
            'Socket closed by peer ${id.substring(0, id.length.clamp(0, 8))}',
          );
          unawaited(_closeSession(id, scheduleReconnect: false));
        }
      },
      cancelOnError: true,
    );

    Future<bool> abandonIfStopped() async {
      if (_isRunCurrent(runEpoch)) return false;
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return true;
    }

    try {
      socket.add(helloData);
      await socket.flush();
    } catch (_) {
      onHandshakeFailure?.call('writeFail');
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }
    if (await abandonIfStopped()) return;

    final frame = await firstFrame.future.timeout(
      SyncManager._handshakeTimeout,
      onTimeout: () => null,
    );
    if (await abandonIfStopped()) return;
    if (frame == null) {
      onHandshakeFailure?.call('readTimeout');
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    final env = syncDecodeEnvelope(frame);
    if (env == null) {
      onHandshakeFailure?.call('readTimeout');
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }
    if (env.v != SyncEnvelope.version) {
      onHandshakeFailure?.call('versionMismatch');
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }
    if (env.type != SyncType.hello && env.type != SyncType.welcome) {
      onHandshakeFailure?.call('badType');
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }
    if (env.peerId.isEmpty || env.peerId == peerId) {
      onHandshakeFailure?.call('selfHandshake');
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    if (env.type == SyncType.hello) {
      final welcome = SyncEnvelope.make(
        type: SyncType.welcome,
        sessionPolicy: syncSessionPolicy,
        peerId: peerId,
        name: displayName,
        port: port,
      );
      final data = syncEncodeFrame(welcome);
      if (data != null) {
        try {
          socket.add(data);
          await socket.flush();
        } catch (e) {
          appLog(
            'welcome send failed to ${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}: $e',
            level: 'warning',
          );
        }
      }
    }

    if (await abandonIfStopped()) return;

    final existing = _sessions[env.peerId];
    if (existing != null) {
      // Simultaneous refresh creates two crossed sockets. Both peers must
      // select the SAME connection: the smaller peer ID owns the outgoing one.
      if (!shouldReplaceSyncSession(
        remotePolicy: env.sessionPolicy,
        localId: peerId,
        remoteId: env.peerId,
        existingInbound: existing.inbound,
        incomingInbound: inbound,
      )) {
        await subscription.cancel();
        socket.destroy();
        return;
      }
      appLog(
        'Duplicate session for ${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}, replacing existing @ ${existing.host}',
        level: 'warning',
      );
      // No await between arbitration and adoption: another handshake must
      // never observe a transient empty slot and choose the crossed socket.
      unawaited(existing.subscription?.cancel());
      existing.fileReceiveFlow?.close();
      existing.socket.destroy();
      _sessions.remove(env.peerId);
    }

    final name = env.name ?? env.peerId;
    final peerPort = env.port ?? port;
    // 4 MiB send buffer: a whole 1.4 MiB chunk frame always fits, so a burst
    // of pipelined chunks never stalls behind a small kernel buffer.
    _bumpSocketBuffers(socket);
    final session = _Session(
      peerId: env.peerId,
      host: host,
      port: peerPort,
      socket: socket,
      isClient: peerId.compareTo(env.peerId) < 0,
      inbound: inbound,
    );
    session.subscription = subscription;
    session.fileReceiveFlow = FileReceiveFlowControl(
      pause: subscription.pause,
      drain: () {
        if (identical(_sessions[env.peerId], session)) _drainBuffer(env.peerId);
      },
      resume: () {
        if (identical(_sessions[env.peerId], session)) subscription.resume();
      },
    );
    // Any leftover bytes after the handshake frame belong to the session.
    if (buffer.length > 0) {
      session.buffer.add(buffer.takeBytes());
    }
    _sessions[env.peerId] = session;
    _handshakeSockets.remove(socket);
    adoptedPeerId = env.peerId;
    handshakeDone = true;

    _reconnectBackoffSec[env.peerId] = 1;
    _reconnectTimers.remove(env.peerId)?.cancel();
    noteSessionEstablished();
    _recordPeer(env.peerId, name, host, peerPort);
    await _persistEndpoint(env.peerId, name, host, peerPort);
    if (!_isRunCurrent(runEpoch)) return;
    if (session.buffer.length > 0) {
      _drainBuffer(env.peerId);
    }
    await _flushPending(env.peerId);
    if (clipboardSyncPeerIds.contains(env.peerId)) {
      unawaited(_requestHistoryFromPeer(env.peerId));
    }
    diagnostics.noteSessionUp(env.peerId, name: name, host: host);
    appLog(
      'Session up with $name (${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}) @ $host:$peerPort',
    );
  }

  /// Best-effort SO_SNDBUF/SO_RCVBUF bump (Linux: SOL_SOCKET=1, SNDBUF=7,
  /// RCVBUF=8). Dart sets a small default; file transfers want room for a few
  /// pipelined chunk frames.
  void _bumpSocketBuffers(Socket socket) {
    try {
      final snd = ByteData(4)..setInt32(0, 4 * 1024 * 1024, Endian.little);
      socket.setRawOption(RawSocketOption(1, 7, snd.buffer.asUint8List()));
      final rcv = ByteData(4)..setInt32(0, 4 * 1024 * 1024, Endian.little);
      socket.setRawOption(RawSocketOption(1, 8, rcv.buffer.asUint8List()));
    } catch (_) {
      // Non-Linux or unsupported — kernel defaults still work.
    }
  }

  Future<void> _requestHistoryFromPeer(String id) async {
    final session = _sessions[id];
    if (session == null) return;
    final last = _lastHistoryFetchAt[id];
    final now = DateTime.now();
    if (last != null &&
        now.difference(last) < SyncManager._historyFetchThrottle) {
      return;
    }
    _lastHistoryFetchAt[id] = now;
    final env = SyncEnvelope.make(type: SyncType.historyFetch, peerId: peerId);
    final data = syncEncodeFrame(env);
    if (data == null) return;
    try {
      session.socket.add(data);
      await session.socket.flush();
      _beginHistoryFetchCatchUp(id);
      appLog(
        'sync.session history.fetch → ${id.substring(0, id.length.clamp(0, 8))}',
      );
    } catch (e) {
      appLog('history.fetch send failed: $e', level: 'warning');
    }
  }

  List<int>? syncTryTakeFrame(BytesBuilder buffer) {
    final bytes = buffer.toBytes();
    if (bytes.length < 4) {
      buffer.clear();
      buffer.add(bytes);
      return null;
    }
    final length = ByteData.sublistView(
      Uint8List.fromList(bytes.sublist(0, 4)),
    ).getUint32(0, Endian.big);
    if (length <= 0 || length > syncMaxFrameLength) {
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
    if (session.fileReceiveFlow?.isAtCapacity == true) return;
    final bytes = session.buffer.takeBytes();
    var offset = 0;
    final remaining = BytesBuilder(copy: false);

    while (true) {
      if (bytes.length - offset < 4) {
        remaining.add(bytes.sublist(offset));
        break;
      }
      final length = ByteData.sublistView(
        Uint8List.fromList(bytes.sublist(offset, offset + 4)),
      ).getUint32(0, Endian.big);
      if (length <= 0 || length > syncMaxFrameLength) {
        diagnostics.noteError(peerId, 'badFrameLength($length)');
        unawaited(
          _closeSession(peerId, scheduleReconnect: true, keepaliveDriven: true),
        );
        return;
      }
      if (bytes.length - offset < 4 + length) {
        remaining.add(bytes.sublist(offset));
        break;
      }
      final frame = bytes.sublist(offset + 4, offset + 4 + length);
      offset += 4 + length;
      _handleFrame(frame, from: peerId, host: session.host);
      if (session.fileReceiveFlow?.isAtCapacity == true) {
        remaining.add(bytes.sublist(offset));
        break;
      }
    }
    if (remaining.length > 0) {
      session.buffer.add(remaining.takeBytes());
    }
  }

  Future<void> _closeSession(
    String peerId, {
    required bool scheduleReconnect,
    bool keepaliveDriven = false,
  }) async {
    final session = _sessions.remove(peerId);
    if (session == null) return;
    session.fileReceiveFlow?.close();
    await session.subscription?.cancel();
    try {
      await session.socket.close();
    } catch (_) {}
    // Drop the in-flight marks for this peer: the session is gone, so ACKs for
    // anything sent on it will never return. Clearing allows a reconnect to
    // legitimately redeliver still-pending items.
    _inFlightHashes.remove(peerId);
    // Mid-transfer file chunks will never arrive on this socket again; drop
    // the partial receive so the idle timer doesn't hold stale state.
    _discardIncomingFilesFrom(peerId);
    // Persist any buffered fetch catch-up before the socket is gone (ACKs may
    // fail; store still runs).
    await _flushHistoryFetchCatchUp(peerId);
    diagnostics.noteSessionDown(peerId);
    appLog(
      'Session closed with ${peerId.substring(0, peerId.length.clamp(0, 8))}',
    );
    if (!scheduleReconnect) return;
    // Keepalive-driven close (pong timeout / socket error / frame corruption):
    // only the client role redials, so both sides don't reconnect each other.
    // Data-driven close (deliver write fail) bypasses this — both roles may
    // reconnect, throttled by _scheduleReconnect's debounce.
    if (keepaliveDriven && !session.isClient) return;
    _scheduleReconnect(peerId);
  }

  void _scheduleReconnect(String peerId) {
    if (!_runLifecycle.isActive || !isEnabled) return;
    final epoch = _runLifecycle.epoch;
    if (_reconnectTimers.containsKey(peerId)) return;
    // Debounce: don't fire another reconnect attempt within the min interval.
    // This caps data-driven reconnects (deliver write failures) so they can't
    // pile on top of the client's keepalive reconnect.
    final now = DateTime.now();
    final last = _lastReconnectAttempt[peerId];
    if (last != null &&
        now.difference(last) < SyncManager._minReconnectInterval) {
      return;
    }
    _lastReconnectAttempt[peerId] = now;
    final delay = _reconnectBackoffSec[peerId] ?? 1.0;
    _reconnectBackoffSec[peerId] = (delay * 2).clamp(1, 30).toDouble();
    appLog(
      'Reconnect scheduled for ${peerId.substring(0, peerId.length.clamp(0, 8))} in ${delay.round()}s',
    );
    _reconnectTimers[peerId] = Timer(Duration(seconds: delay.round()), () {
      _reconnectTimers.remove(peerId);
      if (!_isRunCurrent(epoch)) return;
      if (_sessions.containsKey(peerId)) return;
      unawaited(() async {
        final reason = await _hasDirectPending(peerId) ? 'direct' : 'reconnect';
        if (!_isRunCurrent(epoch)) return;
        final peer = _discoveredPeers[peerId];
        if (peer != null) {
          await _dial(
            peer.host,
            peer.port,
            reason: reason,
            peerId: peerId,
            runEpoch: epoch,
          );
          return;
        }
        for (final e in await _readEndpointCache()) {
          if (!_isRunCurrent(epoch)) return;
          if (e['peerId'] != peerId) continue;
          final host = e['host'] as String?;
          final p = e['port'] as int?;
          if (host == null || p == null) return;
          await _dial(host, p, reason: reason, peerId: peerId, runEpoch: epoch);
          return;
        }
        triggerCrossBandDiscovery(scanFullSubnet: false);
      }());
    });
  }
}
