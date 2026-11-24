import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipy_flutter/sync/crypto.dart';
import 'package:clipy_flutter/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _loadFixtures() {
  final candidates = [
    File('../scripts/fixtures/protocol_v3_fixtures.json'),
    File('scripts/fixtures/protocol_v3_fixtures.json'),
  ];
  for (final file in candidates) {
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  throw StateError('Missing shared scripts/fixtures/protocol_v3_fixtures.json');
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final fixtures = _loadFixtures();

  test('Protocol v3 constants and SyncType names match shared contract', () {
    expect(SyncEnvelope.version, fixtures['version']);
    expect(syncMaxFrameLength, fixtures['maxFrameLength']);
    expect(SyncCrypto.defaultKeySeed, fixtures['defaultKeySeed']);

    final crypto = SyncCrypto();
    expect(_toHex(crypto.key().bytes), fixtures['expectedKeySha256Hex']);

    final actualTypes = <String>{
      SyncType.hello,
      SyncType.welcome,
      SyncType.history,
      SyncType.historyDirect,
      SyncType.historyFetch,
      SyncType.notifPost,
      SyncType.notifDismiss,
      SyncType.notifClear,
      SyncType.notifAck,
      SyncType.notifConfig,
      SyncType.ping,
      SyncType.pong,
      SyncType.ack,
      SyncType.fileMeta,
      SyncType.fileChunk,
      SyncType.fileAck,
    };
    final requiredTypes = (fixtures['requiredSyncTypes'] as List)
        .cast<String>()
        .toSet();
    expect(actualTypes, containsAll(requiredTypes));
  });

  test(
    'AES-GCM text and binary vectors interoperate with Swift CryptoKit',
    () async {
      final crypto = SyncCrypto();
      final textVec = fixtures['textCryptoVector'] as Map<String, dynamic>;
      expect(
        crypto.decryptText(textVec['sealedBase64'] as String),
        textVec['plaintext'],
      );

      final binVec = fixtures['binaryCryptoVector'] as Map<String, dynamic>;
      final decryptedBytes = await crypto.decryptToBytes(
        binVec['sealedBase64'] as String,
      );
      expect(decryptedBytes, isNotNull);
      expect(_toHex(decryptedBytes!), binVec['rawHex']);

      // Round-trip freshly encrypted payloads
      final reEncrypted = crypto.encryptText(textVec['plaintext'] as String);
      expect(reEncrypted, isNotNull);
      expect(crypto.decryptText(reEncrypted!), textVec['plaintext']);

      for (final bad
          in (fixtures['invalidCiphertexts'] as List).cast<String>()) {
        expect(crypto.decryptText(bad), isNull);
        expect(await crypto.decryptToBytes(bad), isNull);
      }
    },
  );

  test(
    'Length-prefixed framing, unknown fields, v2 rejection, and size cap',
    () {
      final envelopes = (fixtures['envelopes'] as List)
          .cast<Map<String, dynamic>>();
      for (final raw in envelopes) {
        final env = SyncEnvelope.fromJson(raw);
        final frame = syncEncodeFrame(env);
        expect(frame, isNotNull);
        final builder = BytesBuilder()..add(frame!);
        final extracted = syncTryTakeFrame(builder);
        expect(extracted, isNotNull);
        expect(builder.isEmpty, isTrue);

        final decoded = syncDecodeEnvelope(extracted!);
        expect(decoded, isNotNull);
        expect(decoded!.v, env.v);
        expect(decoded.type, env.type);
        expect(decoded.msgId, env.msgId);
        expect(decoded.peerId, env.peerId);
        expect(decoded.name, env.name);
        expect(decoded.port, env.port);
        expect(decoded.ts, env.ts);
        expect(decoded.hash, env.hash);
        expect(decoded.payload, env.payload);
        expect(decoded.sessionPolicy, env.sessionPolicy);
      }

      final unknownJson = fixtures['unknownFieldEnvelopeJson'] as String;
      final unknownDecoded = syncDecodeEnvelope(utf8.encode(unknownJson));
      expect(unknownDecoded, isNotNull);
      expect(unknownDecoded!.v, 3);
      expect(unknownDecoded.type, SyncType.welcome);
      expect(unknownDecoded.msgId, 'm-extra');

      final v2Json = fixtures['legacyV2EnvelopeJson'] as String;
      final v2Decoded = syncDecodeEnvelope(utf8.encode(v2Json));
      expect(v2Decoded, isNotNull);
      expect(v2Decoded!.v, isNot(SyncEnvelope.version));

      final oversized = SyncEnvelope.make(
        type: SyncType.history,
        peerId: 'peer-oversized',
        payload: 'x' * (syncMaxFrameLength + 1),
      );
      expect(syncEncodeFrame(oversized), isNull);
    },
  );
}
