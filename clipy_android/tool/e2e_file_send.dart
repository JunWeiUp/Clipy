// Manual integration probe. Sends an EXISTING file; never creates/overwrites it.
// The receiver writes to its normal Downloads/Clipy directory.
// Usage: dart run tool/e2e_file_send.dart <host> <file>
// Optional: CLIPY_PAIRING_SECRET and CLIPY_SYNC_PORT environment variables.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:clipy_android/sync/crypto.dart';
import 'package:clipy_android/sync/protocol.dart';

Future<void> main(List<String> args) async {
  const usage =
      'Usage: dart run tool/e2e_file_send.dart <host> <existing-file>';
  if (args.length == 1 && args.single == '--help') {
    stdout.writeln(usage);
    return;
  }
  if (args.length != 2 || args.first.trim().isEmpty) {
    stderr.writeln(usage);
    exitCode = 64;
    return;
  }
  final port = int.tryParse(Platform.environment['CLIPY_SYNC_PORT'] ?? '5566');
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('CLIPY_SYNC_PORT must be between 1 and 65535.');
    exitCode = 64;
    return;
  }
  final file = File(args[1]);
  if (!await file.exists()) {
    stderr.writeln('Input file does not exist: ${file.path}');
    exitCode = 66;
    return;
  }
  try {
    final success = await sendFileProbe(args[0], port, file);
    exitCode = success ? 0 : 2;
  } catch (error) {
    stderr.writeln('Transfer failed: $error');
    exitCode = 1;
  }
}

/// Uses bounded file reads and waits for the actual handshake, not a fixed sleep.
Future<bool> sendFileProbe(String host, int port, File file) async {
  const chunkSize = 1024 * 1024;
  final length = await file.length();
  if (length > 512 * 1024 * 1024) {
    throw ArgumentError('The sync protocol accepts files up to 512 MiB.');
  }
  final digest = (await sha256.bind(file.openRead()).first).toString();
  final chunks = (length + chunkSize - 1) ~/ chunkSize;
  final peerId = const Uuid().v4();
  final fileId = const Uuid().v4();
  final crypto = SyncCrypto()
    ..pairingSecret = Platform.environment['CLIPY_PAIRING_SECRET'] ?? '';
  final handshake = Completer<SyncEnvelope?>();
  final ack = Completer<Map<String, dynamic>>();
  final buffer = BytesBuilder(copy: false);
  final stopwatch = Stopwatch()..start();
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 3),
  );
  RandomAccessFile? input;
  StreamSubscription<Uint8List>? subscription;

  void disconnected(String reason) {
    if (!handshake.isCompleted) handshake.complete(null);
    if (!ack.isCompleted) ack.complete({'ok': false, 'error': reason});
  }

  void send(SyncEnvelope envelope) {
    final frame = syncEncodeFrame(envelope);
    if (frame == null) throw StateError('Cannot encode ${envelope.type}');
    socket.add(frame);
  }

  try {
    subscription = socket.listen(
      (data) {
        buffer.add(data);
        List<int>? frame;
        while ((frame = syncTryTakeFrame(buffer)) != null) {
          final envelope = syncDecodeEnvelope(frame!);
          if (envelope == null) continue;
          if (envelope.type == SyncType.welcome ||
              envelope.type == SyncType.hello) {
            if (!handshake.isCompleted) handshake.complete(envelope);
          } else if (envelope.type == SyncType.fileAck && !ack.isCompleted) {
            final text = crypto.decryptText(envelope.payload ?? '');
            if (text == null) continue;
            try {
              final result = jsonDecode(text);
              if (result is Map<String, dynamic> &&
                  result['fileId'] == fileId) {
                ack.complete(result);
              }
            } on FormatException {
              // Ignore malformed acknowledgements; the timeout remains bounded.
            }
          }
        }
      },
      onError: (Object error) {
        disconnected('Socket error: $error');
      },
      onDone: () {
        disconnected('Socket closed before acknowledgement');
      },
    );

    send(
      SyncEnvelope.make(
        type: SyncType.hello,
        peerId: peerId,
        name: 'Clipy-E2E',
        port: port,
      ),
    );
    await socket.flush();
    final remote = await handshake.future.timeout(const Duration(seconds: 8));
    if (remote == null || remote.v != SyncEnvelope.version) {
      throw StateError('Peer disconnected or rejected the protocol version');
    }
    stdout.writeln('Connected to $host:$port; sending $length bytes');
    send(
      SyncEnvelope.make(
        type: SyncType.fileMeta,
        peerId: peerId,
        hash: digest,
        payload: crypto.encryptText(
          jsonEncode({
            'fileId': fileId,
            'name': file.uri.pathSegments.last,
            'size': length,
            'chunkSize': chunkSize,
            'chunks': chunks,
            'sha256': digest,
          }),
        ),
      ),
    );

    input = await file.open();
    for (var index = 0; index < chunks; index++) {
      final expected = (length - index * chunkSize).clamp(0, chunkSize);
      final bytes = await input.read(expected);
      if (bytes.length != expected) {
        throw StateError('Input changed while sending');
      }
      final header = ByteData(4)..setUint32(0, index, Endian.big);
      final plaintext = BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(bytes);
      final payload = await crypto.encryptBytes(plaintext.toBytes());
      if (payload == null) throw StateError('Encryption failed');
      send(
        SyncEnvelope(
          v: SyncEnvelope.version,
          type: SyncType.fileChunk,
          msgId: fileId,
          peerId: peerId,
          ts: DateTime.now().millisecondsSinceEpoch / 1000.0,
          payload: payload,
        ),
      );
      await socket.flush();
    }
    await socket.flush(); // Also deliver metadata for a zero-byte file.
    final result = await ack.future.timeout(
      Duration(seconds: 45 + length ~/ (200 * 1024)),
    );
    stdout.writeln('ACK: $result');
    stdout.writeln('Elapsed: ${stopwatch.elapsedMilliseconds} ms');
    return result['ok'] == true;
  } finally {
    await input?.close();
    await subscription?.cancel();
    socket.destroy();
  }
}
