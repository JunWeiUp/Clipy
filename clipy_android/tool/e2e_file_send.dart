// End-to-end check for the Mac-side file receive path: acts as a sync v2
// peer (hello → file.meta → file.chunk…) and prints the file.ack verdict.
// Run from clipy_android: dart run tool/e2e_file_send.dart <host> <file>
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:clipy_android/sync/protocol.dart';
import 'package:clipy_android/sync/crypto.dart';

void main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '192.168.31.221';
  final path = args.length > 1 ? args[1] : '/tmp/e2e_send_test.bin';
  final file = File(path);
  await file.writeAsBytes(
      List<int>.generate(800 * 1024 + 137, (i) => i & 0xFF),
      flush: true);
  final bytes = await file.readAsBytes();
  final sha = sha256.convert(bytes).toString();

  final peerId = const Uuid().v4();
  final chunkSize = 512 * 1024;
  final chunkCount = (bytes.length + chunkSize - 1) ~/ chunkSize;
  final fileId = const Uuid().v4();
  final crypto = SyncCrypto()..pairingSecret = '';

  final socket = await Socket.connect(host, 5566, timeout: const Duration(seconds: 3));
  print('connected to $host:5566');

  final done = Completer<void>();
  final ackCompleter = Completer<Map<String, dynamic>>();
  final buffer = BytesBuilder(copy: false);

  void sendEnvelope(SyncEnvelope env) {
    final data = syncEncodeFrame(env);
    if (data == null) throw StateError('encode failed for ${env.type}');
    socket.add(data);
  }

  unawaited(() async {
    await for (final data in socket) {
      buffer.add(data);
      List<int>? frame;
      while ((frame = syncTryTakeFrame(buffer)) != null) {
        final env = syncDecodeEnvelope(frame!);
        if (env == null) continue;
        if (env.type == 'hello' || env.type == 'welcome') {
          print('handshake: ${env.type} from ${env.name}');
        } else if (env.type == 'file.ack') {
          final plain = crypto.decryptText(env.payload ?? '');
          print('file.ack raw payload decrypt: ${plain == null ? "FAILED" : "ok"}');
          if (plain != null) {
            ackCompleter.complete(jsonDecode(plain) as Map<String, dynamic>);
          }
        }
      }
    }
    if (!ackCompleter.isCompleted) {
      ackCompleter.completeError('socket closed before ack');
    }
    if (!done.isCompleted) done.complete();
  }());

  sendEnvelope(SyncEnvelope.make(
    type: SyncType.hello,
    peerId: peerId,
    name: 'E2E-Test',
    port: 5566,
  ));

  // Give the peer a moment to handshake before meta/chunks.
  await Future.delayed(const Duration(milliseconds: 300));

  sendEnvelope(SyncEnvelope.make(
    type: SyncType.fileMeta,
    peerId: peerId,
    name: 'E2E-Test',
    hash: sha,
    payload: crypto.encryptText(jsonEncode({
      'fileId': fileId,
      'name': 'e2e_send_test.bin',
      'size': bytes.length,
      'chunkSize': chunkSize,
      'chunks': chunkCount,
      'sha256': sha,
    }))!,
  ));

  for (var i = 0; i < chunkCount; i++) {
    final start = i * chunkSize;
    final end = (start + chunkSize).clamp(0, bytes.length);
    final header = ByteData(4)..setUint32(0, i, Endian.big);
    final plain = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(bytes.sublist(start, end));
    sendEnvelope(SyncEnvelope(
      v: SyncEnvelope.version,
      type: SyncType.fileChunk,
      msgId: fileId,
      peerId: peerId,
      name: 'E2E-Test',
      ts: DateTime.now().millisecondsSinceEpoch / 1000.0,
      payload: crypto.encryptBytes(plain.toBytes()),
    ));
  }
  print('sent meta + $chunkCount chunks (${bytes.length} bytes)');

  final ack = await ackCompleter.future.timeout(const Duration(seconds: 20));
  print('ACK: $ack');
  await socket.close();
  exit(ack['ok'] == true ? 0 : 2);
}
