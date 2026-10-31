import 'relay_groups.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:common_relay/common_relay.dart' as cr;
import 'package:sodium/sodium.dart';
import '../storage_paths.dart';
import 'relay_configuration.dart';

enum RelayConnectionState { disabled, connecting, ready, retrying }

class SyncRelayClient {
  SyncRelayClient({
    required this.url,
    required this.token,
    required this.id,
    required this.name,
    required this.port,
    required this.addresses,
    required this.hasSession,
    required this.tryLan,
    required this.onSocket,
    this.onStateChanged,
    this.onPeerAvailable,
  });
  final String url, token, id, name;
  final int port;
  final List<String> addresses;
  final bool Function(String) hasSession;
  final Future<void> Function(String, String, int) tryLan;
  final void Function(String, Socket) onSocket;
  final void Function(RelayConnectionState)? onStateChanged;
  final void Function()? onPeerAvailable;
  cr.RelayClient? _refreshingClient;
  RelayConnectionState state = RelayConnectionState.disabled;
  static Future<cr.RelayJournal>? _journal;
  static Future<cr.RelayJournal> _loadJournal() async {
    final support = await StoragePaths.appStorageDirectory();
    return cr.RelayJournal(Directory('${support.path}/common-relay-journal'));
  }

  cr.RelayClient? _client;
  Timer? _timer;
  final _tunnels = <String, _RelayTunnel>{};
  final _metadata = <String, Map<String, dynamic>>{};
  bool _stopped = false;
  int _retry = 1;
  bool _running = false, _restartRequested = false;
  void _setState(RelayConnectionState value) {
    if (state == value) return;
    state = value;
    onStateChanged?.call(value);
  }

  static bool validUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        uri.scheme == 'wss' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.path == '/relay/v1/ws';
  }

  void start() => unawaited(_run());
  void networkChanged() {
    if (_stopped) return;
    _retry = 1;
    _restartRequested = _running;
    _timer?.cancel();
    if (_running) {
      unawaited(_client?.close());
    } else {
      unawaited(_run());
    }
  }

  void refreshPeers() {
    if (_stopped) return;
    if (!_running) {
      _timer?.cancel();
      unawaited(_run());
      return;
    }
    final client = _client;
    if (client == null || state != RelayConnectionState.ready) return;
    unawaited(_refresh(client).catchError((Object _) {}));
  }

  Future<void> _announce(cr.RelayClient client, String peer) async {
    if (!client.identity.trustedPeers.containsKey(peer)) return;
    await client.sendOnline(
      peer,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'clipy.presence',
            'peerId': id,
            'name': name,
            'port': port,
            'addresses': addresses.take(8).toList(),
          }),
        ),
      ),
    );
  }

  String? _lanPeer(String peer) =>
      RelayConfiguration.lanPeer(peer, _metadata[peer]);
  bool _hasSession(String peer) =>
      _lanPeer(peer) != null && hasSession(_lanPeer(peer)!);

  Future<void> _refresh(cr.RelayClient client) async {
    if (_stopped || !identical(_client, client)) return;
    for (final entry in _metadata.entries.toList()) {
      if (_lanPeer(entry.key) != null &&
          !_hasSession(entry.key) &&
          id.compareTo(_lanPeer(entry.key)!) < 0) {
        unawaited(_open(entry.key, entry.value));
      }
    }
    if (identical(_refreshingClient, client)) return;
    _refreshingClient = client;
    try {
      for (final raw in await client.peers().timeout(
        const Duration(seconds: 3),
      )) {
        if (_stopped || !identical(_client, client)) return;
        await _announce(client, (raw as Map)['device'] as String);
      }
    } on TimeoutException {
      if (!_stopped && identical(_client, client)) networkChanged();
    } finally {
      if (identical(_refreshingClient, client)) _refreshingClient = null;
    }
  }

  Future<void> _run() async {
    if (_stopped || _running) return;
    _running = true;
    _setState(RelayConnectionState.connecting);
    cr.RelayClient? client;
    SecureKey? key;
    try {
      var c = jsonDecode(token) as Map<String, dynamic>;
      if (c.containsKey('group_entry')) {
        c = await ClipyRelayGroups.run(() async {
          final latest = await ClipyRelayGroups.load();
          if (latest.config['device'] != c['device']) {
            throw StateError('Identity changed');
          }
          await latest.refresh();
          await ClipyRelayGroups.persist(latest);
          return latest.config;
        });
      }
      if (c['app'] != 'clipy' ||
          c['device'] is! String ||
          !RelayConfiguration.validDevice(c['device'] as String)) {
        throw StateError('Device identity mismatch');
      }
      final sodium = await SodiumInit.init();
      key = SecureKey.fromList(sodium, cr.unhex(c['secret_key'] as String));
      final identity = cr.RelayIdentity(
        sodium: sodium,
        app: 'clipy',
        group: c['group'] as String,
        device: c['device'] as String,
        secretKey: key,
        publicKey: cr.unhex(c['public_key'] as String),
        trustedPeers: (c['trusted_peers'] as Map<String, dynamic>).map(
          (name, value) => MapEntry(name, cr.unhex(value as String)),
        ),
      );
      final journal = await (_journal ??= _loadJournal().catchError((
        Object error,
      ) {
        _journal = null;
        throw error;
      }));
      if (_stopped || _restartRequested) return;
      client = cr.RelayClient(identity, journal: journal);
      _client = client;
      await client.connect(url, c['token'] as String);
      if (_stopped || _restartRequested) return;
      _retry = 1;
      _setState(RelayConnectionState.ready);
      final active = client;
      unawaited(_refresh(active).catchError((Object _) {}));
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_refresh(active).catchError((Object _) {})),
      );
      await for (final event in client.events) {
        if (_stopped) break;
        switch (event['type']) {
          case 'group.changed':
            if (c['group_entry'] is Map<String, dynamic> &&
                (event['revision'] as int? ?? 0) >
                    (cr.RelayGroups.unpack(
                          c['group_entry'] as Map<String, dynamic>,
                        )['revision']
                        as int)) {
              await active.close();
            }
            break;
          case 'peer.up':
            onPeerAvailable?.call();
            unawaited(
              _announce(
                active,
                (event['identity'] as Map)['device'] as String,
              ).catchError((Object _) {}),
            );
            break;
          case 'peer.down':
            final peer = (event['identity'] as Map)['device'] as String;
            _metadata.remove(peer);
            _tunnels.remove(peer)?.close();
            break;
          case 'message':
            if (event['offline'] == true) break;
            final peer = event['from'] as String;
            final info =
                jsonDecode(utf8.decode(event['data'] as Uint8List))
                    as Map<String, dynamic>;
            if (info['type'] != 'clipy.presence' ||
                info['addresses'] is! List ||
                (info['addresses'] as List).length > 8 ||
                info['port'] is! int ||
                (info['port'] as int) < 1 ||
                (info['port'] as int) > 65535) {
              break;
            }
            final lanPeer = RelayConfiguration.lanPeer(peer, info);
            if (lanPeer == null || lanPeer == id) break;
            final first = !_metadata.containsKey(peer);
            _metadata[peer] = info;
            if (first) {
              unawaited(_announce(active, peer).catchError((Object _) {}));
            }
            if (id.compareTo(lanPeer) < 0) unawaited(_open(peer, info));
            break;
          case 'stream.open':
            final peer = event['from'] as String;
            if (_lanPeer(peer) == null ||
                _hasSession(peer) ||
                _tunnels.containsKey(peer) ||
                id.compareTo(_lanPeer(peer)!) < 0) {
              active.send({'type': 'stream.close', 'id': event['id']});
              break;
            }
            final tunnel = _RelayTunnel();
            _tunnels[peer] = tunnel;
            unawaited(() async {
              try {
                tunnel.stream = await active.acceptStream(event);
                await _bridge(peer, tunnel);
              } catch (_) {
              } finally {
                tunnel.close();
                if (identical(_tunnels[peer], tunnel)) _tunnels.remove(peer);
              }
            }());
            break;
        }
      }
    } catch (_) {
      /* No request/credential logging. */
    } finally {
      _timer?.cancel();
      _client = null;
      _metadata.clear();
      for (final t in _tunnels.values.toList()) {
        t.close();
      }
      _tunnels.clear();
      await client?.close();
      key?.dispose();
      _running = false;
      final restart = _restartRequested;
      _restartRequested = false;
      if (!_stopped) {
        _setState(RelayConnectionState.retrying);
        _timer = Timer(
          restart ? Duration.zero : Duration(seconds: _retry),
          () => unawaited(_run()),
        );
        _retry = (_retry * 2).clamp(1, 30);
      }
    }
  }

  Future<void> _open(String peer, Map<String, dynamic> info) async {
    final client = _client;
    if (_stopped ||
        client == null ||
        _lanPeer(peer) == null ||
        _hasSession(peer) ||
        _tunnels.containsKey(peer)) {
      return;
    }
    final tunnel = _RelayTunnel();
    _tunnels[peer] = tunnel;
    try {
      for (final raw in (info['addresses'] as List).take(2)) {
        final ip = InternetAddress.tryParse(raw as String);
        if (ip == null || ip.type != InternetAddressType.IPv4) continue;
        final b = ip.rawAddress;
        if (!(b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
            (b[0] == 192 && b[1] == 168))) {
          continue;
        }
        await tryLan(_lanPeer(peer)!, raw, info['port'] as int);
      }
      if (_stopped || tunnel.closed || _hasSession(peer)) return;
      tunnel.stream = await client.openStream(peer);
      await _bridge(peer, tunnel);
    } catch (_) {
    } finally {
      tunnel.close();
      if (identical(_tunnels[peer], tunnel)) _tunnels.remove(peer);
    }
  }

  Future<void> _bridge(String peer, _RelayTunnel tunnel) async {
    final stream = tunnel.stream!;
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final accepted = listener.first;
      tunnel.local = await Socket.connect(
        InternetAddress.loopbackIPv4,
        listener.port,
      );
      tunnel.bridge = await accepted;
    } finally {
      await listener.close();
    }
    if (_stopped || tunnel.closed || _hasSession(peer)) return;
    onSocket(_lanPeer(peer)!, tunnel.local!);
    final upload = () async {
      await for (final bytes in tunnel.bridge!) {
        await stream.send(bytes);
      }
    }();
    final download = () async {
      while (!stream.receivedFinal) {
        final bytes = await stream.receive();
        tunnel.bridge!.add(bytes);
        await tunnel.bridge!.flush();
      }
    }();
    await Future.any([upload, download]);
  }

  void stop() {
    _stopped = true;
    _setState(RelayConnectionState.disabled);
    _timer?.cancel();
    for (final t in _tunnels.values.toList()) {
      t.close();
    }
    _tunnels.clear();
    unawaited(_client?.close());
  }
}

class _RelayTunnel {
  cr.RelayStream? stream;
  Socket? local, bridge;
  bool closed = false;
  void close() {
    if (closed) return;
    closed = true;
    local?.destroy();
    bridge?.destroy();
    unawaited(stream?.close());
  }
}
