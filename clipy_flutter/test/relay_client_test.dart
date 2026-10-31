import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/relay_client.dart';

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
}
