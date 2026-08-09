part of '../sync_manager.dart';

extension SyncDiscoveryMethods on SyncManager {
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
    _scanDebounceTimer = Timer(SyncManager._discoveryDebounce, () {
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
      final subnets = <String>{};
      for (final ip in myIPs) {
        final parts = ip.split('.');
        if (parts.length != 4) continue;
        final a = int.tryParse(parts[0]);
        final b = int.tryParse(parts[1]);
        final c = int.tryParse(parts[2]);
        if (a == null || b == null || c == null) continue;
        if (!_isLanIPv4(a, b)) continue;
        subnets.add('$a.$b.$c.0/24');
        for (var d = 1; d <= 254; d++) {
          final candidate = '$a.$b.$c.$d';
          if (myIPs.contains(candidate)) continue;
          if (connectedHosts.contains(candidate)) continue;
          candidates.add(candidate);
        }
      }

      final list = candidates.toList()..sort();
      final subnetList =
          subnets.isEmpty ? '<none>' : (subnets.toList()..sort()).join(', ');
      appLog('Subnet scan: ${list.length} hosts on :$port (subnets: $subnetList)');

      // Aggregate stats across all /24 workers (mirrors the Mac side's ScanStats).
      // `timeout` dominating connectFailures is the VPN/route-hijack tell-tale.
      var attempted = 0;
      final connectFail = <String, int>{};
      final handshakeFail = <String, int>{};
      void cf(String label) => connectFail[label] = (connectFail[label] ?? 0) + 1;
      void hf(String label) => handshakeFail[label] = (handshakeFail[label] ?? 0) + 1;

      var index = 0;
      Future<void> worker() async {
        while (true) {
          if (index >= list.length) return;
          final host = list[index++];
          attempted++;
          await _dial(host, port, reason: 'scan', timeout: SyncManager._scanConnectTimeout,
              onConnectFailure: cf, onHandshakeFailure: hf);
        }
      }

      await Future.wait(
          List.generate(SyncManager._scanConcurrency, (_) => worker()));

      // connect_ok = attempted - connectFailures (those that got past TCP).
      final connectOkCount = attempted - connectFail.values.fold(0, (a, b) => a + b);
      final hsFailTotal = handshakeFail.values.fold(0, (a, b) => a + b);
      final hsOk = connectOkCount - hsFailTotal;
      final cfStr = connectFail.entries.map((e) => '${e.key}=${e.value}').join(',');
      final hfStr = handshakeFail.entries.map((e) => '${e.key}=${e.value}').join(',');
      appLog('Subnet scan finished: attempted=$attempted connect_ok=$connectOkCount '
          'handshake_ok=${hsOk < 0 ? 0 : hsOk} | connect_fail{$cfStr} handshake_fail{$hfStr}');
    } finally {
      _discoveryRunning = false;
    }
  }

  Future<List<String>> _enumerateLocalIPv4s() async {
    final result = <String>[];
    final diagParts = <String>[];
    try {
      for (final iface in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          final parts = ip.split('.').map(int.tryParse).toList();
          if (parts.length != 4 || parts.any((p) => p == null)) {
            diagParts.add('${iface.name}=$ip[ignored]');
            continue;
          }
          final lan = _isLanIPv4(parts[0]!, parts[1]!);
          diagParts.add('${iface.name}=$ip[${lan ? "LAN" : "ignored"}]');
          if (!lan) continue;
          result.add(ip);
        }
      }
    } catch (e) {
      appLog('enumerate IPv4 failed: $e', level: 'warning');
    }
    // A VPN tun0 carrying 10.8.0.x shows up as [LAN] here — that is the
    // tell-tale sign of route hijack starving the real wlan0 subnet.
    appLog('Discovery local interfaces: ${diagParts.isEmpty ? "<none>" : diagParts.join(", ")}');
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
    await prefs.setString(SyncManager._endpointCacheKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> _readEndpointCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(SyncManager._endpointCacheKey);
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final cutoff = DateTime.now()
          .subtract(SyncManager._endpointCacheTtl)
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
