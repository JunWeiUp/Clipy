import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipy_android/sync/crypto.dart';
import 'package:clipy_android/sync/protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/e2e_file_send.dart' as probe;

void main() {
  for (final size in [0, 1024 * 1024 + 17]) {
    test(
      'sends $size bytes to a loopback peer without changing the source',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'clipy-probe-test-',
        );
        final source = File('${directory.path}/fixture.bin');
        final original = Uint8List.fromList(
          List.generate(size, (index) => index & 255),
        );
        await source.writeAsBytes(original);
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final received = BytesBuilder(copy: false);
        final crypto = SyncCrypto()
          ..pairingSecret = Platform.environment['CLIPY_PAIRING_SECRET'] ?? '';
        final receiver = () async {
          final client = await server.first;
          final buffer = BytesBuilder(copy: false);
          Map<String, dynamic>? metadata;
          var index = 0;
          void sendAck() {
            client.add(
              syncEncodeFrame(
                SyncEnvelope.make(
                  type: SyncType.fileAck,
                  peerId: 'loopback-test',
                  payload: crypto.encryptText(
                    jsonEncode({'fileId': metadata!['fileId'], 'ok': true}),
                  ),
                ),
              )!,
            );
          }

          try {
            await for (final data in client) {
              buffer.add(data);
              List<int>? frame;
              while ((frame = syncTryTakeFrame(buffer)) != null) {
                final envelope = syncDecodeEnvelope(frame!)!;
                if (envelope.type == SyncType.hello) {
                  client.add(
                    syncEncodeFrame(
                      SyncEnvelope.make(
                        type: SyncType.welcome,
                        peerId: 'loopback-test',
                      ),
                    )!,
                  );
                } else if (envelope.type == SyncType.fileMeta) {
                  metadata =
                      jsonDecode(crypto.decryptText(envelope.payload!)!)
                          as Map<String, dynamic>;
                  expect(metadata['size'], size);
                  expect(metadata['name'], 'fixture.bin');
                  expect(
                    metadata['sha256'],
                    sha256.convert(original).toString(),
                  );
                  if (size == 0) sendAck();
                } else if (envelope.type == SyncType.fileChunk) {
                  final chunk = (await crypto.decryptToBytes(
                    envelope.payload!,
                  ))!;
                  expect(envelope.msgId, metadata!['fileId']);
                  expect(
                    ByteData.sublistView(chunk).getUint32(0, Endian.big),
                    index++,
                  );
                  received.add(chunk.sublist(4));
                  if (index == metadata['chunks']) sendAck();
                }
                await client.flush();
              }
            }
          } finally {
            client.destroy();
          }
        }();
        try {
          final send = probe.sendFileProbe('127.0.0.1', server.port, source);
          final results = await Future.wait<Object?>([send, receiver]);
          expect(results.first, isTrue);
          expect(received.toBytes(), original);
          expect(await source.readAsBytes(), original);
        } finally {
          await server.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'requires explicit destination and file without creating a fixture',
    () async {
      final previousExitCode = exitCode;
      try {
        await probe.main([]);
        expect(exitCode, 64);
      } finally {
        exitCode = previousExitCode;
      }
    },
  );

  test(
    'missing source is not created and no connection is attempted',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clipy-probe-test-',
      );
      final file = File('${directory.path}/missing.bin');
      final previousExitCode = exitCode;
      try {
        await probe.main(['127.0.0.1', file.path]);
        expect(exitCode, 66);
        expect(await file.exists(), isFalse);
      } finally {
        exitCode = previousExitCode;
        await directory.delete(recursive: true);
      }
    },
  );
}
