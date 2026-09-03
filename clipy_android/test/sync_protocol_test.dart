import 'dart:convert';
import 'dart:typed_data';

import 'package:clipy_android/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SyncEnvelope envelope({String? payload}) => SyncEnvelope(
    v: 2,
    type: SyncType.history,
    msgId: 'fixture-message',
    peerId: 'fixture-peer',
    ts: 1234.5,
    payload: payload ?? 'hello 世界',
  );

  test('encodes a big-endian byte length and round-trips Unicode', () {
    final source = envelope();
    final frame = Uint8List.fromList(syncEncodeFrame(source)!);
    expect(
      ByteData.sublistView(frame).getUint32(0, Endian.big),
      frame.length - 4,
    );
    expect(syncDecodeEnvelope(frame.sublist(4))!.toJson(), source.toJson());
    expect(jsonDecode(utf8.decode(frame.sublist(4))), isNot(contains('name')));
  });

  test('preserves an incomplete header and body at every split point', () {
    final frame = syncEncodeFrame(envelope())!;
    for (var split = 0; split < frame.length; split++) {
      final buffer = BytesBuilder(copy: false)..add(frame.sublist(0, split));
      expect(syncTryTakeFrame(buffer), isNull, reason: 'split=$split');
      expect(buffer.toBytes(), frame.sublist(0, split));
      buffer.add(frame.sublist(split));
      expect(syncTryTakeFrame(buffer), frame.sublist(4));
      expect(buffer.isEmpty, isTrue);
    }
  });

  test('consumes coalesced frames without losing a trailing partial frame', () {
    final first = syncEncodeFrame(envelope(payload: 'first'))!;
    final second = syncEncodeFrame(envelope(payload: 'second'))!;
    final buffer = BytesBuilder(copy: false)
      ..add(first)
      ..add(second)
      ..add(first.sublist(0, 6));
    expect(syncTryTakeFrame(buffer), first.sublist(4));
    expect(syncTryTakeFrame(buffer), second.sublist(4));
    expect(syncTryTakeFrame(buffer), isNull);
    expect(buffer.toBytes(), first.sublist(0, 6));
  });

  test('rejects zero, oversized and unsigned-max lengths', () {
    for (final length in [0, syncMaxFrameLength + 1, 0xffffffff]) {
      final header = ByteData(4)..setUint32(0, length, Endian.big);
      final buffer = BytesBuilder()..add(header.buffer.asUint8List());
      expect(syncTryTakeFrame(buffer), isNull);
      expect(buffer.isEmpty, isTrue);
    }
  });

  test('accepts exactly the configured body limit', () {
    final frame = syncEncodeFrame(envelope())!;
    final buffer = BytesBuilder()..add(frame);
    expect(
      syncTryTakeFrame(buffer, maxFrameLength: frame.length - 4),
      frame.sublist(4),
    );
  });

  test('does not encode an oversized or non-finite JSON body', () {
    expect(
      syncEncodeFrame(envelope(payload: 'x' * syncMaxFrameLength)),
      isNull,
    );
    final invalid = SyncEnvelope(
      v: 2,
      type: 'ping',
      msgId: 'id',
      peerId: 'peer',
      ts: double.nan,
    );
    expect(syncEncodeFrame(invalid), isNull);
  });

  test('rejects invalid UTF-8, JSON and field types without throwing', () {
    for (final bytes in [
      [0xff],
      utf8.encode('{'),
      utf8.encode('[]'),
      utf8.encode('{"v":"2"}'),
    ]) {
      expect(syncDecodeEnvelope(bytes), isNull);
    }
  });
}
