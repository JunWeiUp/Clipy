part of '../sync_manager.dart';

extension SyncFrameDispatchMethods on SyncManager {
  /// Hard char cap for one catch-up window. The peer may stream up to 200
  /// frames within the 8s window; without a cap the batch (plus the copies
  /// handleRemoteSyncBatch makes) grows without bound. Over-cap frames are
  /// dropped WITHOUT acking, so the sender's pending queue re-delivers them.
  static const _historyFetchCatchUpMaxChars = 8 * 1024 * 1024;

  void _handleFrame(
    List<int> data, {
    required String from,
    required String host,
  }) {
    final env = syncDecodeEnvelope(data);
    if (env == null || env.v != SyncEnvelope.version) {
      diagnostics.noteError(from, 'badEnvelope');
      return;
    }
    if (env.type != SyncType.ping && env.type != SyncType.pong) {
      diagnostics.noteReceived(from);
    }

    switch (env.type) {
      case 'screen.state':
      case 'screen.result':
        _handleScreenFrame(env, from);
        break;
      case SyncType.ping:
        final pong = SyncEnvelope.make(type: SyncType.pong, peerId: peerId);
        final d = syncEncodeFrame(pong);
        final session = _sessions[from];
        if (d != null && session != null) {
          try {
            session.socket.add(d);
          } catch (e) {
            appLog(
              'pong send failed to ${from.substring(0, from.length.clamp(0, 8))}: $e',
              level: 'warning',
            );
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
        final text = _decryptFrom(payload, from, env.type);
        if (text == null) return;
        final hash = env.hash ?? '';
        if (_bufferHistoryFetchCatchUp(from, text, hash)) {
          break;
        }
        unawaited(() async {
          final ok = await ClipboardManager.instance.handleRemoteSync(
            text,
            hash,
          );
          if (ok) {
            _replyAck(from, hash.isEmpty ? null : hash);
          } else {
            appLog(
              'history persist failed; withholding ACK hash=${hash.substring(0, hash.length.clamp(0, 8))}',
              level: 'warning',
            );
          }
        }());
        break;
      case SyncType.notifPost:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decryptFrom(payload, from, env.type);
        if (text == null) return;
        unawaited(
          NotificationManager.instance.handleRemoteNotification(text, from),
        );
        break;
      case SyncType.notifDismiss:
        final payload = env.payload;
        if (payload == null) return;
        final text = _decryptFrom(payload, from, env.type);
        if (text == null) return;
        unawaited(NotificationManager.instance.handleRemoteDismiss(text));
        break;
      case SyncType.notifClear:
        unawaited(NotificationManager.instance.clearAll());
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
    buf.maxWait = Timer(SyncManager._historyFetchCatchUpMaxWait, () {
      unawaited(_flushHistoryFetchCatchUp(peerId));
    });
  }

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
    buf.debounce = Timer(SyncManager._historyFetchCatchUpDebounce, () {
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
    String peerId,
    List<({String text, String hash})> items,
  ) async {
    appLog(
      'history.fetch catch-up flush ${peerId.substring(0, peerId.length.clamp(0, 8))}: ${items.length} frames',
    );
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
        level: 'warning',
      );
      return;
    }
    final last = _lastHistoryFetchResponse[remotePeerId];
    final now = DateTime.now();
    if (last != null &&
        now.difference(last) < SyncManager._historyFetchRespondThrottle) {
      return;
    }
    _lastHistoryFetchResponse[remotePeerId] = now;
    final session = _sessions[remotePeerId];
    if (session == null) return;
    final recent = await ClipboardRepository.instance.fetchRecentTexts(
      limit: SyncManager._historyFetchRespondLimit,
    );
    appLog(
      'sync.ack history.fetch from ${remotePeerId.substring(0, remotePeerId.length.clamp(0, 8))}: pushing ${recent.length} text entries',
    );
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
    final env = SyncEnvelope.make(
      type: SyncType.ack,
      peerId: this.peerId,
      hash: hash,
    );
    final data = syncEncodeFrame(env);
    final session = _sessions[peerId];
    if (data == null || session == null) return;
    try {
      session.socket.add(data);
    } catch (e) {
      appLog(
        'ack send failed to ${peerId.substring(0, peerId.length.clamp(0, 8))}: $e',
        level: 'warning',
      );
    }
  }

  /// A notification ACK belongs only to its sender. Do not fan it out to all
  /// discovered peers, since each peer maintains its own pending queue.
  void sendNotificationAck(String hash, {required String toPeerId}) {
    if (hash.isEmpty || toPeerId.isEmpty) return;
    final session = _sessions[toPeerId];
    if (session == null) return;
    final data = syncEncodeFrame(
      SyncEnvelope.make(type: SyncType.notifAck, peerId: peerId, hash: hash),
    );
    if (data == null) return;
    try {
      session.socket.add(data);
    } catch (e) {
      appLog('notification ACK send failed to $toPeerId: $e', level: 'warning');
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
}
