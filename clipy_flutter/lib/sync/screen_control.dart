part of '../sync_manager.dart';

extension ScreenControlSync on SyncManager {
  void queryMacScreen(String id) {
    if (!macScreenControlSupported) return;
    final session = _sessions[id];
    if (session == null) return;
    final frame = syncEncodeFrame(
      SyncEnvelope.make(type: 'screen.query', peerId: peerId),
    );
    if (frame != null) session.socket.add(frame);
  }

  void _clearMacScreen(String id) {
    macScreens.value = Map.of(macScreens.value)..remove(id);
    _screenQueries.remove(id)?.complete(null);
    final requests = _screenRequests.entries
        .where((e) => e.value.$1 == id)
        .map((e) => e.key)
        .toList();
    for (final request in requests) {
      _screenRequests.remove(request)?.$2.complete('disconnected');
    }
  }

  void _handleScreenFrame(SyncEnvelope env, String from) {
    if (env.peerId != from || !_sessions.containsKey(from)) return;
    final text = env.payload == null ? null : _crypto.decryptText(env.payload!);
    if (text == null) return;
    if (env.type == 'screen.state') {
      final state = MacScreenState.parse(text);
      if (state == null ||
          (!macScreens.value.containsKey(from) &&
              macScreens.value.length >= 128)) {
        return;
      }
      macScreens.value = Map.of(macScreens.value)..[from] = state;
      _screenQueries.remove(from)?.complete(state);
    } else if (env.type == 'screen.result') {
      final request = _screenRequests[env.hash];
      if (request != null && request.$1 == from) {
        final result = parseMacScreenResult(text, request.$3);
        if (result != null) {
          _screenRequests.remove(env.hash)?.$2.complete(result);
        }
      }
    }
  }

  Future<String> controlMacScreen(String id, String action) async {
    if (!['lock', 'unlock'].contains(action) || !_sessions.containsKey(id)) {
      return 'disconnected';
    }
    if (!macScreenControlSupported) return 'unavailable';
    if (_screenQueries.length >= 32 ||
        _screenQueries.containsKey(id) ||
        _screenRequests.values.any((e) => e.$1 == id) ||
        _screenRequests.length >= 32) {
      return 'busy';
    }
    final query = Completer<MacScreenState?>();
    _screenQueries[id] = query;
    try {
      queryMacScreen(id);
      final state = await query.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );
      if (state == null) return 'stateTimeout';
      if (!state.configured) return 'notConfigured';
      if (state.locked == null) return 'sessionUnavailable';
      if (!state.directControl) return 'updateMac';
      final command = macScreenCommand(state, action);
      final payload = command == null ? null : _crypto.encryptText(command);
      if (payload == null) return 'unavailable';
      final env = SyncEnvelope.make(
        type: 'screen.command',
        peerId: peerId,
        payload: payload,
      );
      final frame = syncEncodeFrame(env);
      final session = _sessions[id];
      if (frame == null || session == null) return 'disconnected';
      final response = Completer<String>();
      _screenRequests[env.msgId] = (id, response, state.challenge);
      try {
        session.socket.add(frame);
        return await response.future.timeout(
          const Duration(seconds: 16),
          onTimeout: () => 'notConfirmed',
        );
      } finally {
        _screenRequests.remove(env.msgId);
      }
    } catch (_) {
      return 'unavailable';
    } finally {
      if (identical(_screenQueries[id], query)) _screenQueries.remove(id);
    }
  }
}
