import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:common_relay/common_relay.dart';
import 'package:sodium/sodium.dart';
Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Usage: probe.dart private-config.json');
  final c = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final sodium = await SodiumInit.init();
  final identity = RelayIdentity(sodium: sodium, app: c['app'] as String, group: c['group'] as String, device: c['device'] as String, secretKey: SecureKey.fromList(sodium, unhex(c['secret_key'] as String)), publicKey: unhex(c['public_key'] as String), trustedPeers: (c['trusted_peers'] as Map<String, dynamic>).map((name, key) => MapEntry(name, unhex(key as String))));
  final client = RelayClient(identity, journal: c['state_path'] == null ? null : RelayJournal(Directory(c['state_path'] as String)));
  await client.connect(c['url'] as String, c['token'] as String, allowLocalTest: c['allow_local_test'] == true);
  stdout.writeln('READY');
  await for (final event in client.events) {
    if (event['type'] == 'stream.open') {
      unawaited(() async { final stream = await client.acceptStream(event); while (!stream.receivedFinal) { final data = await stream.receive(); await stream.send(data, finalRecord: stream.receivedFinal); } }());
    } else if (event['type'] == 'message') {
      await client.message(event['from'] as String, event['data'] as Uint8List, offline: event['offline'] == true);
      if (event['offline'] == true) await client.acknowledge(event);
    }
  }
}
