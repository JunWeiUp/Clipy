import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:common_relay/common_relay.dart' as cr;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/relay_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';

void main() {
  test(
    'relay configuration requires TLS and keeps credentials out of URLs',
    () {
      expect(SyncRelayClient.validUrl('wss://example.com/relay/v1/ws'), isTrue);
      for (final url in [
        'ws://example.com/clipy-relay',
        'wss://key@example.com/clipy-relay',
        'wss://example.com/clipy-relay?token=x',
        'wss://example.com/clipy-relay#x',
        'https://example.com',
      ]) {
        expect(SyncRelayClient.validUrl(url), isFalse);
      }
    },
  );

  test(
    'invalid device configuration cannot open a socket and stop is idempotent',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) {
        requests++;
        request.response.close();
      });
      final states = <RelayConnectionState>[];
      final client = SyncRelayClient(
        url: 'ws://127.0.0.1:${server.port}/relay/v1/ws',
        token: jsonEncode({'app': 'wrong', 'device': 'local'}),
        id: 'local',
        name: 'Local',
        port: 5566,
        addresses: [],
        hasSession: (_) => false,
        tryLan: (_, _, _) async {},
        onSocket: (_, socket) {
          socket.destroy();
          fail('invalid identity opened a stream');
        },
        onStateChanged: states.add,
      );
      try {
        client.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(states, [
          RelayConnectionState.connecting,
          RelayConnectionState.retrying,
        ]);
        client.refreshPeers();
        client.refreshPeers();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          states.where((s) => s == RelayConnectionState.connecting).length,
          2,
        );
        client.networkChanged();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          states.where((s) => s == RelayConnectionState.connecting).length,
          3,
        );
        client.stop();
        client.refreshPeers();
        client.networkChanged();
        client.stop();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(states.last, RelayConnectionState.disabled);
        expect(requests, 0);
      } finally {
        client.stop();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'v2 resolvedPeers maps relayDeviceId to lanPeerId and openPeer opens on demand',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final sodium = await SodiumInit.init();
      final phoneKeys = sodium.crypto.box.keyPair();
      final macKeys = sodium.crypto.box.keyPair();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <String, WebSocket>{};
      final streamPeers = <String, (String, String)>{};

      final serverSub = server.listen((req) async {
        final dev = (req.headers.value('authorization') ?? '').replaceFirst(
          'Bearer ',
          '',
        );
        final ws = await WebSocketTransformer.upgrade(req);
        sockets[dev] = ws;
        ws.listen((raw) {
          if (raw is Uint8List || raw is List<int>) {
            final bytes = raw is Uint8List
                ? raw
                : Uint8List.fromList(raw as List<int>);
            final sid = utf8.decode(bytes.sublist(0, 16));
            final pair = streamPeers[sid];
            if (pair == null) return;
            final target = pair.$1 == dev ? pair.$2 : pair.$1;
            sockets[target]?.add(bytes);
            return;
          }
          final ev = jsonDecode(raw as String) as Map<String, dynamic>;
          final type = ev['type'] as String?;
          if (type == 'presence') {
            ws.add(
              jsonEncode({
                'type': 'presence',
                'space': ev['space'],
                'id': ev['id'],
                'peers': sockets.keys.toList(),
              }),
            );
          } else if (type == 'msg') {
            final to = ev['to'] as String;
            sockets[to]?.add(jsonEncode({...ev, 'from': dev}));
          } else if (type == 'stream.open') {
            final sid = ev['id'] as String;
            final to = ev['to'] as String;
            streamPeers[sid] = (dev, to);
            sockets[to]?.add(jsonEncode({...ev, 'from': dev}));
          } else if (type == 'stream.accept') {
            final sid = ev['id'] as String;
            final pair = streamPeers[sid];
            if (pair == null) return;
            final target = pair.$1 == dev ? pair.$2 : pair.$1;
            sockets[target]?.add(jsonEncode({...ev, 'from': dev}));
          } else if (type == 'stream.close') {
            final sid = ev['id'] as String;
            final pair = streamPeers.remove(sid);
            if (pair == null) return;
            final target = pair.$1 == dev ? pair.$2 : pair.$1;
            sockets[target]?.add(jsonEncode({...ev, 'from': dev}));
          }
        });
      });

      const phoneLanId = 'ffffffff-1111-4111-8111-111111111111';
      const macLanId = '11111111-2222-4222-8222-222222222222';
      const phoneRelayId = 'phone-relay-id';
      const macRelayId = 'mac-relay-id';

      final wsUrl = 'ws://127.0.0.1:${server.port}/v2/ws';
      final httpUrl = 'http://127.0.0.1:${server.port}';
      final macIdentity = cr.RelayIdentity(
        sodium: sodium,
        app: 'clipy',
        group: 'grp',
        device: macRelayId,
        secretKey: macKeys.secretKey,
        publicKey: macKeys.publicKey,
        trustedPeers: {phoneRelayId: phoneKeys.publicKey},
      );
      final macV2Client = cr.RelayV2Client(
        baseUrl: httpUrl,
        accessPassword: '',
        token: macRelayId,
        allowLocal: true,
      );
      final macPipe = cr.RelayV2Pipe(
        client: macV2Client,
        space: 'grp',
        identity: macIdentity,
      );

      final phoneToken = jsonEncode({
        'app': 'clipy',
        'group': 'grp',
        'device': phoneRelayId,
        'token': phoneRelayId,
        'secret_key': cr.hex(phoneKeys.secretKey.extractBytes()),
        'public_key': cr.hex(phoneKeys.publicKey),
        'trusted_peers': {macRelayId: cr.hex(macKeys.publicKey)},
      });

      final phoneSocketReady = Completer<(String, Socket)>();
      final presenceReady = Completer<void>();
      final errors = <String>[];

      late final SyncRelayClient phoneRelay;
      phoneRelay = SyncRelayClient(
        url: wsUrl,
        token: phoneToken,
        id: phoneLanId,
        name: 'Phone',
        port: 5566,
        addresses: const [],
        hasSession: (_) => false,
        tryLan: (_, _, _) async {},
        onSocket: (peer, socket) {
          if (!phoneSocketReady.isCompleted) {
            phoneSocketReady.complete((peer, socket));
          } else {
            socket.destroy();
          }
        },
        onStateChanged: (_) {
          if (phoneRelay.resolvedPeers.containsKey(macLanId) &&
              !presenceReady.isCompleted) {
            presenceReady.complete();
          }
        },
        onLog: errors.add,
        allowLocalTest: true,
      );

      StreamSubscription<Map<String, dynamic>>? macEventsSub;
      cr.RelayV2Stream? macStream;
      Socket? phoneSocket;
      try {
        await macPipe.connect();
        macEventsSub = macPipe.events.listen((ev) async {
          if (ev['type'] == 'msg' && ev['topic'] == 'clipy.presence') {
            await macPipe.sendMessage(
              phoneRelayId,
              'clipy.presence',
              Uint8List.fromList(
                utf8.encode(
                  jsonEncode({
                    'type': 'clipy.presence',
                    'peerId': macLanId,
                    'name': 'MacBook Pro',
                    'port': 5566,
                    'addresses': <String>[],
                  }),
                ),
              ),
            );
          } else if (ev['type'] == 'stream.open') {
            macStream = await macPipe.acceptStream(ev);
            for (var i = 0; i < 30; i++) {
              await macStream!.send(Uint8List.fromList(utf8.encode('p$i\n')));
            }
          }
        });

        phoneRelay.start();
        await presenceReady.future.timeout(const Duration(seconds: 5));

        expect(phoneRelay.resolvedPeers.keys, [macLanId]);
        expect(phoneRelay.resolvedPeers.containsKey(macRelayId), isFalse);
        expect(phoneRelay.resolvedPeers.containsKey(phoneLanId), isFalse);
        expect(phoneRelay.resolvedPeers[macLanId]!.name, 'MacBook Pro');

        // Phone has the larger LAN peerId (ffff... > 1111...), so auto-open did
        // not initiate; calling openPeer with macLanId must resolve macRelayId
        // and open the v2 stream cleanly.
        phoneRelay.openPeer(macLanId);
        final (connectedPeer, sock) = await phoneSocketReady.future.timeout(
          const Duration(seconds: 5),
        );
        phoneSocket = sock;
        expect(connectedPeer, macLanId);

        final received = StringBuffer();
        final allReceived = Completer<void>();
        final sockSub = sock.listen((chunk) {
          received.write(utf8.decode(chunk));
          if (received
                      .toString()
                      .split('\n')
                      .where((l) => l.isNotEmpty)
                      .length >=
                  30 &&
              !allReceived.isCompleted) {
            allReceived.complete();
          }
        });
        await allReceived.future.timeout(const Duration(seconds: 5));
        await sockSub.cancel();
        expect(
          received.toString().split('\n').where((l) => l.isNotEmpty).toList(),
          List.generate(30, (i) => 'p$i'),
        );
        expect(errors, isEmpty);
      } finally {
        phoneSocket?.destroy();
        phoneRelay.stop();
        await macStream?.close();
        await macEventsSub?.cancel();
        await macPipe.close();
        macV2Client.close();
        await serverSub.cancel();
        await server.close(force: true);
        phoneKeys.secretKey.dispose();
        macKeys.secretKey.dispose();
      }
    },
  );
}
