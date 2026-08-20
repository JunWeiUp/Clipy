part of '../sync_manager.dart';

extension SyncSessionMethods on SyncManager {
  // -----------------------------------------------------------------------
  // Server
  // -----------------------------------------------------------------------

  Future<bool> _startServer() async {
    try {
      await _server?.close();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      appLog('Listening on 0.0.0.0:$port');
      // `onDone` must null out `_server` — otherwise the field stays non-null
      // after the listening stream closes, and `onSyncTick` would skip the
      // rebind, leaving :5566 refusing connections with the FGS alive.
      _server!.listen(
        _onInbound,
        onError: (e) {
          appLog('Server error: $e', level: 'error');
          _server = null;
        },
        onDone: () {
          appLog('Server socket closed (onDone)', level: 'warning');
          _server = null;
        },
      );
      return true;
    } catch (e) {
      _server = null;
      appLog('Failed to bind :$port — $e', level: 'error');
      return false;
    }
  }

  void _onInbound(Socket socket) {
    final host = socket.remoteAddress.address;
    appLog('Inbound from $host');
    unawaited(_performHandshake(socket, host: host, inbound: true,
        onHandshakeFailure: (f) {
      appLog('Inbound handshake failed from $host: $f', level: 'warning');
    }));
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

  Future<void> _dial(String host, int peerPort,
      {required String reason,
      String? peerId,
      Duration? timeout,
      void Function(String connectFailure)? onConnectFailure,
      void Function(String hsFailure)? onHandshakeFailure}) async {
    final resolved =
        peerId ?? (reason == 'scan' ? null : _resolvePeerId(host, peerPort));
    if (!_allowsProactiveDial(reason, resolved)) return;

    final key = '$host:$peerPort';
    final now = DateTime.now();
    final last = _lastDialAt[key];
    if (last != null &&
        now.difference(last) < SyncManager._dialDedupTtl &&
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
        timeout: timeout ?? SyncManager._connectTimeout,
      );
    } catch (e) {
      // SocketException with null osError + message "Connection timed out" or
      // "Connecting timed out" is the Dart-side timeout path (scanConnectTimeout).
      final isTimeout = (e is SocketException) &&
          (e.osError == null) &&
          (e.message.toLowerCase().contains('timed out'));
      final label = isTimeout ? 'timeout' : _classifyConnectError(e);
      if (reason == 'scan') {
        onConnectFailure?.call(label);
      } else {
        appLog('Dial $reason $host:$peerPort failed: connect($label)',
            level: 'warning');
      }
      return;
    }
    await _performHandshake(socket, host: host, inbound: false,
        onHandshakeFailure: reason == 'scan'
            ? onHandshakeFailure
            : (f) {
                appLog('Dial $reason $host:$peerPort failed: handshake($f)',
                    level: 'warning');
              });
  }

  Future<void> _performHandshake(Socket socket,
      {required String host,
      required bool inbound,
      void Function(String failure)? onHandshakeFailure}) async {
    final hello = SyncEnvelope.make(
      type: SyncType.hello,
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
        if (id != null) {
          appLog('Socket error from ${id.substring(0, id.length.clamp(0, 8))}: $e',
              level: 'warning');
          unawaited(
              _closeSession(id, scheduleReconnect: true, keepaliveDriven: true));
        }
      },
      onDone: () {
        if (!firstFrame.isCompleted) firstFrame.complete(null);
        final id = adoptedPeerId;
        if (id != null) {
          appLog('Socket closed by peer ${id.substring(0, id.length.clamp(0, 8))}');
          unawaited(_closeSession(id, scheduleReconnect: false));
        }
      },
      cancelOnError: true,
    );

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

    final frame = await firstFrame.future.timeout(
      SyncManager._handshakeTimeout,
      onTimeout: () => null,
    );
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
          appLog('welcome send failed to ${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}: $e',
              level: 'warning');
        }
      }
    }

    final existing = _sessions[env.peerId];
    if (existing != null) {
      // Align with Mac: replace the old socket. Dropping the new fd while the
      // peer keeps dialing causes Replacing/errno=54 storms and lost flushes.
      appLog(
          'Duplicate session for ${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}, replacing existing @ ${existing.host}',
          level: 'warning');
      await existing.subscription?.cancel();
      try {
        await existing.socket.close();
      } catch (_) {}
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
    if (clipboardSyncPeerIds.contains(env.peerId)) {
      unawaited(_requestHistoryFromPeer(env.peerId));
    }
    appLog(
        'Session up with $name (${env.peerId.substring(0, env.peerId.length.clamp(0, 8))}) @ $host:$peerPort');
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
    if (last != null && now.difference(last) < SyncManager._historyFetchThrottle) return;
    _lastHistoryFetchAt[id] = now;
    final env = SyncEnvelope.make(type: SyncType.historyFetch, peerId: peerId);
    final data = syncEncodeFrame(env);
    if (data == null) return;
    try {
      session.socket.add(data);
      await session.socket.flush();
      _beginHistoryFetchCatchUp(id);
      appLog(
          'sync.session history.fetch → ${id.substring(0, id.length.clamp(0, 8))}');
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
    final length = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4)))
        .getUint32(0, Endian.big);
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
      if (length <= 0 || length > syncMaxFrameLength) {
        unawaited(_closeSession(peerId, scheduleReconnect: true, keepaliveDriven: true));
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

  Future<void> _closeSession(String peerId,
      {required bool scheduleReconnect, bool keepaliveDriven = false}) async {
    final session = _sessions.remove(peerId);
    if (session == null) return;
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
    appLog('Session closed with ${peerId.substring(0, peerId.length.clamp(0, 8))}');
    if (!scheduleReconnect) return;
    // Keepalive-driven close (pong timeout / socket error / frame corruption):
    // only the client role redials, so both sides don't reconnect each other.
    // Data-driven close (deliver write fail) bypasses this — both roles may
    // reconnect, throttled by _scheduleReconnect's debounce.
    if (keepaliveDriven && !session.isClient) return;
    _scheduleReconnect(peerId);
  }

  void _scheduleReconnect(String peerId) {
    if (!isEnabled) return;
    if (_reconnectTimers.containsKey(peerId)) return;
    // Debounce: don't fire another reconnect attempt within the min interval.
    // This caps data-driven reconnects (deliver write failures) so they can't
    // pile on top of the client's keepalive reconnect.
    final now = DateTime.now();
    final last = _lastReconnectAttempt[peerId];
    if (last != null && now.difference(last) < SyncManager._minReconnectInterval) return;
    _lastReconnectAttempt[peerId] = now;
    final delay = _reconnectBackoffSec[peerId] ?? 1.0;
    _reconnectBackoffSec[peerId] =
        (delay * 2).clamp(1, 30).toDouble();
    appLog('Reconnect scheduled for ${peerId.substring(0, peerId.length.clamp(0, 8))} in ${delay.round()}s');
    _reconnectTimers[peerId] = Timer(Duration(seconds: delay.round()), () {
      _reconnectTimers.remove(peerId);
      if (_sessions.containsKey(peerId)) return;
      unawaited(() async {
        final reason = await _hasDirectPending(peerId) ? 'direct' : 'reconnect';
        final peer = _discoveredPeers[peerId];
        if (peer != null) {
          await _dial(peer.host, peer.port, reason: reason, peerId: peerId);
          return;
        }
        for (final e in await _readEndpointCache()) {
          if (e['peerId'] != peerId) continue;
          final host = e['host'] as String?;
          final p = e['port'] as int?;
          if (host == null || p == null) return;
          await _dial(host, p, reason: reason, peerId: peerId);
          return;
        }
        triggerCrossBandDiscovery(scanFullSubnet: false);
      }());
    });
  }



}
