part of '../sync_manager.dart';

/// Chunked file transfer over the v2 session protocol.
///
/// Wire format (see docs/PROTOCOL.md):
/// - `file.meta`  sender → receiver, encrypted JSON metadata, `hash` = sha256.
/// - `file.chunk` sender → receiver, encrypted `u32 BE index ‖ bytes`.
/// - `file.ack`   receiver → sender, encrypted JSON `{fileId, ok, error?}`.
///
/// Transfers are interactive one-shots: nothing is enqueued into
/// `pending_sync`; if the session drops mid-transfer both sides discard state
/// and the user can simply retry.
extension SyncFileTransferMethods on SyncManager {
  // -----------------------------------------------------------------------
  // Outbound
  // -----------------------------------------------------------------------

  Future<bool> sendFileToPeerImpl(File file, {required String peerId}) async {
    if (!isEnabled) return false;
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length > SyncManager.fileMaxBytes) {
      appLog('sendFile: ${file.path} exceeds '
          '${SyncManager.fileMaxBytes} bytes', level: 'warning');
      return false;
    }

    final session = await _waitForSession(peerId, const Duration(seconds: 8));
    if (session == null) {
      appLog('sendFile: no session with ${peerId.substring(0, peerId.length.clamp(0, 8))}',
          level: 'warning');
      return false;
    }

    final fileId = const Uuid().v4();
    final fileName = file.path.split(Platform.pathSeparator).last;
    final chunkSize = SyncManager.fileChunkSize;
    final chunkCount = length == 0 ? 0 : ((length + chunkSize - 1) ~/ chunkSize);

    void emit(double progress, {bool completed = false, bool failed = false}) {
      _fileProgressController.add(FileProgress(
        fileId: fileId,
        fileName: fileName,
        progress: progress,
        receivedBytes: (length * progress).round(),
        totalBytes: length,
        isCompleted: completed,
        isFailed: failed,
        isOutgoing: true,
      ));
    }

    emit(0);
    try {
      final sha256Hex = await _hashFile(file);
      final waiter = Completer<bool>();
      _fileAckWaiters[fileId] = waiter;

      final meta = jsonEncode({
        'fileId': fileId,
        'name': fileName,
        'size': length,
        'chunkSize': chunkSize,
        'chunks': chunkCount,
        'sha256': sha256Hex,
      });
      final metaPayload = _encrypt(meta);
      if (metaPayload == null) {
        _fileAckWaiters.remove(fileId);
        emit(0, failed: true);
        return false;
      }
      final metaFrame = syncEncodeFrame(SyncEnvelope.make(
        type: SyncType.fileMeta,
        peerId: peerId,
        name: displayName,
        hash: sha256Hex,
        payload: metaPayload,
      ));
      if (metaFrame == null) {
        _fileAckWaiters.remove(fileId);
        emit(0, failed: true);
        return false;
      }
      session.socket.add(metaFrame);
      await session.socket.flush();

      final raf = await file.open();
      try {
        final header = ByteData(4);
        var sentChunks = 0;
        for (var index = 0; index < chunkCount; index++) {
          // The receiver may reject (oversize / disk full) mid-stream; stop
          // burning bandwidth once it has answered.
          if (waiter.isCompleted) break;
          final data = await raf.read(chunkSize);
          if (data.isEmpty) break;
          header.setUint32(0, index, Endian.big);
          final plain = BytesBuilder(copy: false)
            ..add(header.buffer.asUint8List())
            ..add(data);
          final payload = _crypto.encryptBytes(plain.toBytes());
          if (payload == null) {
            _fileAckWaiters.remove(fileId);
            emit(0, failed: true);
            return false;
          }
          final frame = syncEncodeFrame(SyncEnvelope(
            v: SyncEnvelope.version,
            type: SyncType.fileChunk,
            // Deterministic msgId = fileId so the receiver can route chunks
            // even with concurrent transfers from the same peer.
            msgId: fileId,
            peerId: peerId,
            name: displayName,
            ts: DateTime.now().millisecondsSinceEpoch / 1000.0,
            payload: payload,
          ));
          if (frame == null) {
            _fileAckWaiters.remove(fileId);
            emit(0, failed: true);
            return false;
          }
          session.socket.add(frame);
          // Await backpressure instead of buffering the whole file in memory.
          await session.socket.flush();
          sentChunks++;
          emit((sentChunks * chunkSize).clamp(0, length) / length);
        }
      } finally {
        await raf.close();
      }
      if (waiter.isCompleted && !await waiter.future) {
        emit(1, failed: true);
        return false;
      }
      if (waiter.isCompleted) {
        emit(1, completed: true);
        return true;
      }

      final timeout = Duration(
        seconds: (45 + length ~/ (200 * 1024)).clamp(45, 600),
      );
      final ok = await waiter.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      emit(1, completed: ok, failed: !ok);
      return ok;
    } on SocketException catch (e) {
      appLog('sendFile socket error: $e', level: 'warning');
      await _closeSession(peerId, scheduleReconnect: true);
      emit(1, failed: true);
      return false;
    } catch (e) {
      appLog('sendFile failed: $e', level: 'warning');
      emit(1, failed: true);
      return false;
    } finally {
      _fileAckWaiters.remove(fileId);
    }
  }

  /// Dial `direct` (no auth, like the text send) and poll for the session.
  Future<_Session?> _waitForSession(String peerId, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    var dialed = false;
    while (DateTime.now().isBefore(deadline)) {
      final session = _sessions[peerId];
      if (session != null) return session;
      if (!dialed) {
        dialed = true;
        final peer = _discoveredPeers[peerId];
        if (peer != null) {
          unawaited(_dial(peer.host, peer.port, reason: 'direct', peerId: peerId));
        } else {
          unawaited(() async {
            for (final e in await _readEndpointCache()) {
              if (e['peerId'] != peerId) continue;
              final host = e['host'] as String?;
              final p = e['port'] as int?;
              if (host == null || p == null) return;
              await _dial(host, p, reason: 'direct', peerId: peerId);
              return;
            }
          }());
        }
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return _sessions[peerId];
  }

  Future<String> _hashFile(File file) async {
    final collector = _DigestCollector();
    final input = sha256.startChunkedConversion(collector);
    await for (final data in file.openRead()) {
      input.add(data);
    }
    input.close();
    return collector.digest?.toString() ?? '';
  }

  // -----------------------------------------------------------------------
  // Inbound
  // -----------------------------------------------------------------------

  void _handleFileMetaFrame(SyncEnvelope env, {required String from}) {
    final payload = env.payload;
    if (payload == null) return;
    final plain = _decrypt(payload);
    if (plain == null) {
      appLog('file.meta decrypt failed from ${from.substring(0, from.length.clamp(0, 8))}',
          level: 'warning');
      return;
    }
    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(plain) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final fileId = meta['fileId'] as String? ?? '';
    final name = meta['name'] as String? ?? '';
    final size = meta['size'] as int? ?? -1;
    final chunkSize = meta['chunkSize'] as int? ?? 0;
    final chunks = meta['chunks'] as int? ?? 0;
    final sha256Hex = meta['sha256'] as String? ?? '';
    if (fileId.isEmpty || name.isEmpty || size < 0 || chunkSize <= 0) return;
    if (size > SyncManager.fileMaxBytes) {
      appLog('file.meta rejected (too large): $name ($size bytes)', level: 'warning');
      _sendFileAck(from, fileId: fileId, ok: false, error: 'tooLarge');
      return;
    }
    if (sha256Hex.isEmpty) return;
    final receiveDir = _syncReceiveDirectory();
    if (receiveDir == null) {
      appLog('file.meta receive dir unavailable', level: 'error');
      _sendFileAck(from, fileId: fileId, ok: false, error: 'ioError');
      return;
    }

    // Register state synchronously — meta and the first chunk usually arrive
    // back-to-back, and an async gap here would drop the chunk.
    _discardIncomingFile(fileId);
    final incoming = _IncomingFileTransfer(
      peerId: from,
      senderName: env.name ?? from.substring(0, from.length.clamp(0, 8)),
      fileId: fileId,
      fileName: _sanitizeFileName(name),
      fileSize: size,
      chunkSize: chunkSize,
      chunkCount: chunks,
      sha256Hex: sha256Hex,
      partFile: File('${receiveDir.path}/.incoming-$fileId.part'),
    );
    _incomingFiles[fileId] = incoming;
    _armIncomingIdleTimer(fileId);
    _fileProgressController.add(FileProgress(
      fileId: fileId,
      fileName: incoming.fileName,
      progress: 0,
      receivedBytes: 0,
      totalBytes: size,
    ));
    // Zero-byte files carry no chunks; finish immediately.
    if (incoming.chunkCount == 0) {
      _incomingFiles.remove(fileId);
      incoming.idleTimer?.cancel();
      unawaited(_completeIncomingFile(incoming));
    }
  }

  /// Synchronous receive directory, cached at init ([SyncManager.init]).
  /// Returns null only when sync never initialized — callers then reject the
  /// transfer with `file.ack ioError`.
  Directory? _syncReceiveDirectory() {
    final path = _receiveDirPath;
    if (path == null) return null;
    try {
      final dir = Directory('$path/Clipy');
      dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  void _handleFileChunkFrame(SyncEnvelope env, {required String from}) {
    // Chunks carry msgId = fileId (see the send loop above).
    final incoming = _incomingFiles[env.msgId];
    if (incoming == null || incoming.peerId != from) return;
    final payload = env.payload;
    if (payload == null) return;
    final plain = _crypto.decryptToBytes(payload);
    if (plain == null || plain.length < 4) return;
    final index = ByteData.sublistView(plain).getUint32(0, Endian.big);
    if (index >= incoming.chunkCount) return;
    final data = plain.sublist(4);
    try {
      // FileMode.append always writes at EOF regardless of positioning —
      // exactly what an in-order TCP stream needs, and a restart always
      // begins with a fresh fileId (fresh part file).
      final raf = incoming.partFile.openSync(mode: FileMode.append);
      try {
        raf.writeFromSync(data);
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      appLog('file.chunk write failed: $e', level: 'error');
      _discardIncomingFile(incoming.fileId);
      _sendFileAck(from, fileId: incoming.fileId, ok: false, error: 'ioError');
      _emitIncomingFailed(incoming);
      return;
    }
    incoming.received.add(index);
    _armIncomingIdleTimer(incoming.fileId);
    final received = incoming.received.length;
    _fileProgressController.add(FileProgress(
      fileId: incoming.fileId,
      fileName: incoming.fileName,
      progress: (received / incoming.chunkCount).clamp(0.0, 1.0),
      receivedBytes: (received * incoming.chunkSize).clamp(0, incoming.fileSize),
      totalBytes: incoming.fileSize,
    ));
    if (received >= incoming.chunkCount) {
      unawaited(_completeIncomingFile(incoming));
    }
  }

  void _handleFileAckFrame(SyncEnvelope env, {required String from}) {
    final payload = env.payload;
    if (payload == null) return;
    final plain = _decrypt(payload);
    if (plain == null) return;
    final Map<String, dynamic> ack;
    try {
      ack = jsonDecode(plain) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final fileId = ack['fileId'] as String? ?? '';
    final ok = ack['ok'] as bool? ?? false;
    final error = ack['error'] as String?;
    if (fileId.isEmpty) return;
    final waiter = _fileAckWaiters.remove(fileId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(ok);
    }
    if (!ok) {
      appLog('file.ack rejected ($error) for file ${fileId.substring(0, fileId.length.clamp(0, 8))}',
          level: 'warning');
    }
  }

  Future<void> _completeIncomingFile(_IncomingFileTransfer incoming) async {
    // Remove from the map first so duplicate completion can't race.
    if (_incomingFiles.remove(incoming.fileId) == null) return;
    incoming.idleTimer?.cancel();
    try {
      final actual = await _hashFile(incoming.partFile);
      if (actual != incoming.sha256Hex) {
        appLog(
            'file transfer hash mismatch for ${incoming.fileName}: '
            'expected ${incoming.sha256Hex.substring(0, 8)} got ${actual.substring(0, 8)}',
            level: 'warning');
        _discardIncomingFile(incoming.fileId, removeState: false);
        _sendFileAck(incoming.peerId,
            fileId: incoming.fileId, ok: false, error: 'hashMismatch');
        _emitIncomingFailed(incoming);
        return;
      }
      // The part file already lives in the managed Clipy/ receive dir.
      final dir = incoming.partFile.parent;
      final target = await _dedupeDestination(dir, incoming.fileName);
      await incoming.partFile.rename(target.path);
      await FileTransferRepository.instance.insert(
        fileName: incoming.fileName,
        filePath: target.path,
        fileSize: incoming.fileSize,
        senderName: incoming.senderName,
      );
      _sendFileAck(incoming.peerId, fileId: incoming.fileId, ok: true);
      _fileProgressController.add(FileProgress(
        fileId: incoming.fileId,
        fileName: incoming.fileName,
        progress: 1,
        receivedBytes: incoming.fileSize,
        totalBytes: incoming.fileSize,
        isCompleted: true,
      ));
      _fileReceivedController.add(incoming.fileName);
      appLog('Received file ${incoming.fileName} (${incoming.fileSize} bytes) '
          'from ${incoming.senderName}');
    } catch (e) {
      appLog('file complete failed: $e', level: 'error');
      _discardIncomingFile(incoming.fileId, removeState: false);
      _sendFileAck(incoming.peerId,
          fileId: incoming.fileId, ok: false, error: 'ioError');
      _emitIncomingFailed(incoming);
    }
  }

  void _emitIncomingFailed(_IncomingFileTransfer incoming) {
    _fileProgressController.add(FileProgress(
      fileId: incoming.fileId,
      fileName: incoming.fileName,
      progress: 0,
      receivedBytes: 0,
      totalBytes: incoming.fileSize,
      isFailed: true,
    ));
  }

  void _sendFileAck(String peerId,
      {required String fileId, required bool ok, String? error}) {
    final session = _sessions[peerId];
    if (session == null) return;
    final payload = _encrypt(jsonEncode({
      'fileId': fileId,
      'ok': ok,
      if (error != null) 'error': error,
    }));
    if (payload == null) return;
    final data = syncEncodeFrame(SyncEnvelope.make(
      type: SyncType.fileAck,
      peerId: peerId,
      payload: payload,
    ));
    if (data == null) return;
    try {
      session.socket.add(data);
    } catch (e) {
      appLog('file.ack send failed: $e', level: 'warning');
    }
  }

  void _armIncomingIdleTimer(String fileId) {
    final incoming = _incomingFiles[fileId];
    if (incoming == null) return;
    incoming.idleTimer?.cancel();
    incoming.idleTimer =
        Timer(SyncManager._fileIncomingIdleTimeout, () {
      final entry = _incomingFiles.remove(fileId);
      if (entry == null) return;
      appLog('Incoming file ${entry.fileName} timed out; discarded', level: 'warning');
      unawaited(_deleteQuietly(entry.partFile));
      _emitIncomingFailed(entry);
    });
  }

  /// Drop an incoming transfer (state + part file). Session close and
  /// duplicate meta both funnel through here.
  void _discardIncomingFile(String fileId, {bool removeState = true}) {
    final incoming =
        removeState ? _incomingFiles.remove(fileId) : _incomingFiles[fileId];
    if (incoming == null) return;
    incoming.idleTimer?.cancel();
    unawaited(_deleteQuietly(incoming.partFile));
  }

  void _discardIncomingFilesFrom(String peerId) {
    final ids = _incomingFiles.values
        .where((f) => f.peerId == peerId)
        .map((f) => f.fileId)
        .toList();
    for (final id in ids) {
      final incoming = _incomingFiles.remove(id);
      incoming?.idleTimer?.cancel();
      if (incoming != null) unawaited(_deleteQuietly(incoming.partFile));
    }
  }

  String _sanitizeFileName(String name) {
    var cleaned = name
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll('\u0000', '');
    // Keep the receive dir browsable: no hidden/dot-prefixed results.
    while (cleaned.startsWith('.')) {
      cleaned = cleaned.substring(1);
    }
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  Future<File> _dedupeDestination(Directory dir, String fileName) async {
    var candidate = File('${dir.path}/$fileName');
    if (!await candidate.exists()) return candidate;
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var n = 2;
    while (true) {
      candidate = File('${dir.path}/$stem ($n)$ext');
      if (!await candidate.exists()) return candidate;
      n++;
    }
  }
}
