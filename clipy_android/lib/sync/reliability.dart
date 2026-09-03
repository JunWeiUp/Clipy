part of '../sync_manager.dart';

extension SyncReliabilityMethods on SyncManager {
  String? _mapNotificationType(String apiType) {
    switch (apiType) {
      case 'notification/post':
        return SyncType.notifPost;
      case 'notification/dismiss':
        return SyncType.notifDismiss;
      case 'notification/clear_all':
        return SyncType.notifClear;
      case 'notification/ack':
        return SyncType.notifAck;
      case 'notification/config':
        return SyncType.notifConfig;
      default:
        return null;
    }
  }

  List<String> _authIdsForType(String type) {
    switch (type) {
      case SyncType.history:
        return clipboardSyncPeerIds;
      case SyncType.notifPost:
      case SyncType.notifDismiss:
      case SyncType.notifClear:
      case SyncType.notifConfig:
        return notificationSyncPeerIds;
      default:
        return authorizedPeerIds;
    }
  }

  bool _isQueueable(String type) =>
      type == SyncType.history ||
      type == SyncType.historyDirect ||
      type == SyncType.notifPost;

  Future<void> _fanout(SyncEnvelope env, {required bool requireAuth}) async {
    final data = syncEncodeFrame(env);
    if (data == null) return;
    final auth = _authIdsForType(env.type);
    final targets = requireAuth
        ? availablePeers
              .where((p) => auth.contains(p.peerId))
              .map((p) => p.peerId)
              .toList()
        : _discoveredPeers.keys.toList();

    if (targets.isEmpty) {
      if (_isQueueable(env.type) && env.hash != null) {
        for (final id in auth) {
          await _enqueuePending(data, env.type, id, env.hash);
        }
      }
      triggerCrossBandDiscovery();
      return;
    }

    for (final id in targets) {
      final delivered = await _deliver(
        data,
        type: env.type,
        peerId: id,
        hash: env.hash,
      );
      appLog(
        'fanout ${env.type} to ${id.substring(0, id.length.clamp(0, 8))}: '
        'session deliver=$delivered',
      );
      // Mirror Mac: keep encoded frame until ACK after a successful send.
      if (_isQueueable(env.type) && delivered) {
        await _enqueuePending(data, env.type, id, env.hash);
      }
    }
  }

  Future<bool> _deliver(
    List<int> data, {
    required String type,
    required String peerId,
    String? hash,
    String dialReason = 'deliver',
  }) async {
    final session = _sessions[peerId];
    if (session != null) {
      try {
        session.socket.add(data);
        await session.socket.flush();
        if (_isQueueable(type) && hash != null && hash.isNotEmpty) {
          _inFlightHashes.putIfAbsent(peerId, () => <String>{}).add(hash);
        }
        return true;
      } catch (_) {
        await _closeSession(peerId, scheduleReconnect: true);
      }
    }
    if (_isQueueable(type)) {
      await _enqueuePending(data, type, peerId, hash);
    }
    final reason = type == SyncType.historyDirect ? 'direct' : dialReason;
    final peer = _discoveredPeers[peerId];
    if (peer != null) {
      unawaited(_dial(peer.host, peer.port, reason: reason, peerId: peerId));
    } else {
      unawaited(() async {
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
    }
    _scheduleReconnect(peerId);
    return false;
  }

  Future<void> _enqueuePending(
    List<int> data,
    String type,
    String peerId,
    String? hash,
  ) async {
    if (hash == null || hash.isEmpty) return;
    // Keep a small in-memory mirror for same-process flush before SQLite returns.
    final cutoff = DateTime.now().subtract(SyncManager._pendingTtl);
    _pendingQueue.removeWhere((f) => f.enqueueAt.isBefore(cutoff));
    _pendingQueue.removeWhere((f) => f.peerId == peerId && f.hash == hash);
    final perPeer = _pendingQueue.where((f) => f.peerId == peerId).length;
    if (perPeer < SyncManager._pendingMax) {
      _pendingQueue.add(
        _PendingFrame(
          peerId: peerId,
          data: data,
          type: type,
          hash: hash,
          enqueueAt: DateTime.now(),
        ),
      );
    }
    await PendingSyncRepository.instance.enqueue(
      peerId: peerId,
      hash: hash,
      type: type,
      data: data,
      ttl: SyncManager._pendingTtl,
      maxPerPeer: PendingSyncRepository.maxPerPeer,
    );
  }

  Future<void> _flushPending(String peerId) async {
    final session = _sessions[peerId];
    if (session == null) return;

    final allowClipboard = clipboardSyncPeerIds.contains(peerId);
    final allowNotification = notificationSyncPeerIds.contains(peerId);

    // Fast path: this runs on every syncTick (30-90s). When nothing is
    // pending anywhere, skip materializing up to 500 BLOB frames + the
    // legacy queue + 500 notification rows just to find them all empty.
    if (!await PendingSyncRepository.instance.hasPending(peerId) &&
        (!allowClipboard ||
            !await PendingTextSyncRepository.instance.hasAny()) &&
        (!allowNotification ||
            !await NotificationRepository.instance.hasPendingSync())) {
      return;
    }

    final due = await PendingSyncRepository.instance.fetchDue(
      peerId: peerId,
      ttl: SyncManager._pendingTtl,
    );
    final filtered = due.where((f) {
      if (f.type == SyncType.history) return allowClipboard;
      if (f.type == SyncType.historyDirect) return true;
      if (f.type == SyncType.notifPost ||
          f.type == SyncType.notifDismiss ||
          f.type == SyncType.notifClear ||
          f.type == SyncType.notifConfig) {
        return allowNotification;
      }
      return true;
    }).toList();

    if (filtered.isNotEmpty) {
      final skipped = filtered
          .where(
            (f) =>
                _isQueueable(f.type) &&
                (_inFlightHashes[peerId]?.contains(f.hash) ?? false),
          )
          .length;
      appLog(
        'Flushing ${filtered.length} pending frame(s) to $peerId'
        '${skipped > 0 ? ' (skipped $skipped in-flight)' : ''}',
      );
      for (final frame in filtered) {
        if (_isQueueable(frame.type) &&
            (_inFlightHashes[peerId]?.contains(frame.hash) ?? false)) {
          continue;
        }
        try {
          session.socket.add(frame.data);
          if (_isQueueable(frame.type)) {
            _inFlightHashes
                .putIfAbsent(peerId, () => <String>{})
                .add(frame.hash);
          } else {
            await PendingSyncRepository.instance.remove(
              peerId: peerId,
              hash: frame.hash,
            );
            _pendingQueue.removeWhere(
              (f) => f.peerId == peerId && f.hash == frame.hash,
            );
          }
        } catch (e) {
          appLog(
            'flushPending ${frame.type} send failed to ${peerId.substring(0, peerId.length.clamp(0, 8))}: $e',
            level: 'warning',
          );
          return;
        }
      }
      try {
        await session.socket.flush();
      } catch (_) {}
    }

    // Legacy plaintext queue (pre-pending_sync) — re-encode once then drop.
    if (allowClipboard) {
      final persisted = await PendingTextSyncRepository.instance.fetchByPeer(
        peerId,
      );
      for (final entry in persisted) {
        if (_inFlightHashes[peerId]?.contains(entry.hash) ?? false) continue;
        final payload = _encrypt(entry.data);
        if (payload == null) continue;
        final env = SyncEnvelope.make(
          type: SyncType.history,
          peerId: this.peerId,
          name: displayName,
          hash: entry.hash,
          payload: payload,
        );
        final data = syncEncodeFrame(env);
        if (data == null) continue;
        try {
          session.socket.add(data);
          _inFlightHashes.putIfAbsent(peerId, () => <String>{}).add(entry.hash);
          await PendingSyncRepository.instance.enqueue(
            peerId: peerId,
            hash: entry.hash,
            type: SyncType.history,
            data: data,
          );
          await PendingTextSyncRepository.instance.removeByHash(entry.hash);
        } catch (e) {
          appLog(
            'flushPending history(legacy) send failed to ${peerId.substring(0, peerId.length.clamp(0, 8))}: $e',
            level: 'warning',
          );
          return;
        }
      }
    }

    // NotificationManager's own offline queue (content JSON) — keep for now.
    if (!allowNotification) return;
    final notifPending = await NotificationRepository.instance
        .fetchAllPendingSync();
    if (notifPending.isNotEmpty) {
      appLog(
        'Flushing ${notifPending.length} pending notification(s) to $peerId',
      );
    }
    for (final row in notifPending) {
      final content = row['content'] as String? ?? '';
      final hash =
          (row['hash'] as String?) ?? (row['notification_id'] as String?) ?? '';
      if (content.isEmpty || hash.isEmpty) continue;
      if (_inFlightHashes[peerId]?.contains(hash) ?? false) continue;
      final payload = _encrypt(content);
      if (payload == null) continue;
      final env = SyncEnvelope.make(
        type: SyncType.notifPost,
        peerId: this.peerId,
        name: displayName,
        hash: hash,
        payload: payload,
      );
      final data = syncEncodeFrame(env);
      if (data == null) continue;
      try {
        session.socket.add(data);
        _inFlightHashes.putIfAbsent(peerId, () => <String>{}).add(hash);
        await PendingSyncRepository.instance.enqueue(
          peerId: peerId,
          hash: hash,
          type: SyncType.notifPost,
          data: data,
        );
      } catch (e) {
        appLog(
          'flushPending notif.post send failed to ${peerId.substring(0, peerId.length.clamp(0, 8))}: $e',
          level: 'warning',
        );
        return;
      }
    }
  }

  void _handleAck(String hash, {required String from}) {
    if (hash.isEmpty) return;
    final before = _pendingQueue.length;
    _pendingQueue.removeWhere((f) => f.peerId == from && f.hash == hash);
    if (_pendingQueue.length != before) {
      appLog(
        'ACK from ${from.substring(0, from.length.clamp(0, 8))} cleared pending for hash ${hash.substring(0, hash.length.clamp(0, 8))}',
      );
    }
    _inFlightHashes[from]?.remove(hash);
    unawaited(PendingSyncRepository.instance.remove(peerId: from, hash: hash));
    unawaited(PendingTextSyncRepository.instance.removeByHash(hash));
  }

  /// Clear in-flight marks for history frames with no ACK ≥45s, then re-flush.
  Future<void> _retryStalePendingHistory(String peerId) async {
    final due = await PendingSyncRepository.instance.fetchDue(
      peerId: peerId,
      ttl: SyncManager._pendingTtl,
    );
    final cutoff = DateTime.now().subtract(SyncManager._pendingAckRetryAge);
    final stale = due
        .where(
          (f) =>
              (f.type == SyncType.history ||
                  f.type == SyncType.historyDirect) &&
              !f.enqueueAt.isAfter(cutoff),
        )
        .toList();
    if (stale.isEmpty) return;
    for (final frame in stale) {
      _inFlightHashes[peerId]?.remove(frame.hash);
    }
    appLog(
      'sync.pending Retrying ${stale.length} stale pending history frame(s) to '
      '${peerId.substring(0, peerId.length.clamp(0, 8))} '
      '(no ACK ≥${SyncManager._pendingAckRetryAge.inSeconds}s)',
    );
    await _flushPending(peerId);
  }

  Future<bool> _hasDirectPending(String peerId) async {
    final due = await PendingSyncRepository.instance.fetchDue(
      peerId: peerId,
      ttl: SyncManager._pendingTtl,
    );
    return due.any((f) => f.type == SyncType.historyDirect);
  }

  Future<bool> sendTextToPeer(String content, {required String peerId}) async {
    if (!isEnabled) return false;
    final hash = sha256.convert(utf8.encode(content)).toString();
    final payload = _encrypt(content);
    if (payload == null) return false;
    final env = SyncEnvelope.make(
      type: SyncType.historyDirect,
      peerId: this.peerId,
      name: displayName,
      hash: hash,
      payload: payload,
    );
    final data = syncEncodeFrame(env);
    if (data == null) return false;
    final delivered = await _deliver(
      data,
      type: env.type,
      peerId: peerId,
      hash: hash,
      dialReason: 'direct',
    );
    if (delivered) {
      await _enqueuePending(data, env.type, peerId, hash);
    }
    return delivered;
  }

  Future<bool> sendFileToPeer(File file, {required String peerId}) =>
      sendFileToPeerImpl(file, peerId: peerId);
}
