import 'dart:async';
import 'dart:io';
import '../../clipy_android/lib/sync/relay_client.dart';

Future<void> main() async {
  final env = Platform.environment;
  final key = File(env['CLIPY_RELAY_TEST_KEY_FILE']!).readAsStringSync().trim();
  final done = Completer<void>();
  final connected = <String>{};
  final client = SyncRelayClient(url: env['CLIPY_RELAY_TEST_URL']!, token: key,
    id: 'smoke-dart', name: 'Relay test Dart', port: 5566, addresses: [],
    hasSession: connected.contains, tryLan: (_, _, _) async {},
    onSocket: (id, socket) {
      connected.add(id);
      unawaited(() async {
        var count = 0;
        await for (final chunk in socket) {
          socket.add(chunk);
          await socket.flush();
          count += chunk.length;
        }
        if (count != 8 * 1024 * 1024) throw StateError('Unexpected byte count $count');
        print('Dart relay echoed $count bytes');
        done.complete();
      }().catchError((Object e, StackTrace s) => done.completeError(e, s)));
    });
  client.start();
  try { await done.future.timeout(const Duration(seconds: 90)); }
  finally { client.stop(); }
}
