// Isolated v3 UI peer: loopback only, 20-minute bound, no production storage or clipboard.
// dart run tool/native_ui_peer.dart; stdin commands: send-file, disconnect, quit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:clipy_android/sync/crypto.dart';
import 'package:clipy_android/sync/protocol.dart';

const peerId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const port = 65534;
final crypto = SyncCrypto();
final sockets = <Socket>{};
Socket? active;
final files = <String, Map<String, dynamic>>{};
void event(String kind, [Map<String, dynamic> data = const {}]) =>
    stdout.writeln(jsonEncode({'event': kind, ...data}));
void send(Socket socket, String type, {String? hash, String? payload}) {
  final frame = syncEncodeFrame(
    SyncEnvelope.make(
      type: type,
      peerId: peerId,
      name: 'UI Parity Peer',
      port: port,
      hash: hash,
      payload: payload,
    ),
  );
  if (frame != null) socket.add(frame);
}

Future<void> handle(Socket socket, SyncEnvelope frame) async {
  if (frame.v != 3) {
    socket.destroy();
    return;
  }
  switch (frame.type) {
    case SyncType.hello:
      active = socket;
      send(socket, SyncType.welcome);
      event('connected');
    case SyncType.ping:
      send(socket, SyncType.pong);
    case SyncType.historyDirect:
    case SyncType.history:
      final plaintext = crypto.decryptText(frame.payload ?? '');
      if (plaintext == null || frame.hash == null) return;
      if (sha256.convert(utf8.encode(plaintext)).toString() != frame.hash) {
        return;
      }
      event('text-received', {
        'bytes': utf8.encode(plaintext).length,
        'hash': frame.hash,
      });
      send(socket, SyncType.ack, hash: frame.hash);
    case SyncType.fileMeta:
      final plaintext = crypto.decryptText(frame.payload ?? '');
      if (plaintext == null) return;
      final value = jsonDecode(plaintext) as Map<String, dynamic>;
      if ((value['size'] as num).toInt() > 4 * 1024 * 1024 ||
          files.length >= 4) {
        return;
      }
      files[value['fileId'] as String] = {
        ...value,
        'bytes': BytesBuilder(copy: false),
        'next': 0,
      };
      event('file-meta', {'size': value['size']});
      if (value['size'] == 0) {
        send(
          socket,
          SyncType.fileAck,
          payload: crypto.encryptText(
            jsonEncode({'fileId': value['fileId'], 'ok': true}),
          ),
        );
        files.remove(value['fileId']);
      }
    case SyncType.fileChunk:
      final entry = files[frame.msgId];
      if (entry == null) return;
      final bytes = await crypto.decryptToBytes(frame.payload ?? '');
      if (bytes == null || bytes.length < 4) return;
      final index = ByteData.sublistView(bytes).getUint32(0, Endian.big);
      if (index != entry['next']) return;
      entry['next'] = index + 1;
      final buffer = entry['bytes'] as BytesBuilder;
      buffer.add(bytes.sublist(4));
      if (buffer.length > (entry['size'] as num).toInt()) {
        files.remove(frame.msgId);
        return;
      }
      if (buffer.length == entry['size']) {
        final result = buffer.takeBytes();
        final digest = sha256.convert(result).toString();
        final ok = digest == entry['sha256'];
        event('file-received', {
          'bytes': result.length,
          'sha256': digest,
          'verified': ok,
        });
        send(
          socket,
          SyncType.fileAck,
          payload: crypto.encryptText(
            jsonEncode({'fileId': frame.msgId, 'ok': ok}),
          ),
        );
        files.remove(frame.msgId);
      }
    case SyncType.fileAck:
      final value = crypto.decryptText(frame.payload ?? '');
      if (value != null) {
        event('file-ack', Map<String, dynamic>.from(jsonDecode(value) as Map));
      }
  }
}

Future<void> sendFile() async {
  final socket = active;
  if (socket == null) {
    event('no-active-peer');
    return;
  }
  final pattern = utf8.encode('UI parity file\n');
  final bytes = Uint8List.fromList(
    List<int>.generate(1024 * 1024, (i) => pattern[i % pattern.length]),
  );
  final digest = sha256.convert(bytes).toString();
  final id = 'ui-parity-${DateTime.now().millisecondsSinceEpoch}';
  send(
    socket,
    SyncType.fileMeta,
    hash: digest,
    payload: crypto.encryptText(
      jsonEncode({
        'fileId': id,
        'name': 'ui-parity.txt',
        'size': bytes.length,
        'chunkSize': bytes.length,
        'chunks': 1,
        'sha256': digest,
      }),
    ),
  );
  await socket.flush();
  event('file-sending', {'sha256': digest});
  await Future<void>.delayed(const Duration(seconds: 4));
  final chunk = Uint8List(bytes.length + 4)
    ..setRange(4, bytes.length + 4, bytes);
  final encrypted = await crypto.encryptBytes(chunk);
  socket.add(
    syncEncodeFrame(
      SyncEnvelope(
        v: 3,
        type: SyncType.fileChunk,
        msgId: id,
        peerId: peerId,
        ts: DateTime.now().millisecondsSinceEpoch / 1000,
        payload: encrypted,
      ),
    )!,
  );
  await socket.flush();
}

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  event('listening', {'port': port});
  final expiry = Timer(const Duration(minutes: 20), () {
    for (final s in sockets.toList()) {
      s.destroy();
    }
    server.close();
    exit(0);
  });
  server.listen((socket) {
    if (sockets.length >= 4) {
      socket.destroy();
      return;
    }
    sockets.add(socket);
    final buffer = BytesBuilder(copy: false);
    Future<void> serial = Future.value();
    socket.listen(
      (bytes) {
        buffer.add(bytes);
        if (buffer.length > 3 * 1024 * 1024) {
          socket.destroy();
          return;
        }
        List<int>? frame;
        while ((frame = syncTryTakeFrame(buffer)) != null) {
          final envelope = syncDecodeEnvelope(frame!);
          if (envelope == null) continue;
          serial = serial.then((_) => handle(socket, envelope)).catchError((
            Object error,
          ) {
            event('rejected', {'kind': error.runtimeType.toString()});
          });
        }
      },
      onDone: () {
        sockets.remove(socket);
        if (active == socket) active = null;
        event('disconnected');
      },
      onError: (Object _) {
        sockets.remove(socket);
      },
    );
  });
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'send-file') unawaited(sendFile());
    if (command == 'disconnect') {
      for (final socket in sockets.toList()) {
        socket.destroy();
      }
    }
    if (command == 'quit') break;
  }
  expiry.cancel();
  for (final socket in sockets.toList()) {
    socket.destroy();
  }
  await server.close();
  exit(0);
}
