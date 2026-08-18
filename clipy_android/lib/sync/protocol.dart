import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// Length-prefixed JSON envelope (v2). See docs/PROTOCOL.md.
class SyncEnvelope {
  static const int version = 2;

  final int v;
  final String type;
  final String msgId;
  final String peerId;
  final String? name;
  final int? port;
  final double ts;
  final String? hash;
  final String? payload;

  SyncEnvelope({
    required this.v,
    required this.type,
    required this.msgId,
    required this.peerId,
    this.name,
    this.port,
    required this.ts,
    this.hash,
    this.payload,
  });

  factory SyncEnvelope.make({
    required String type,
    required String peerId,
    String? name,
    int? port,
    String? hash,
    String? payload,
  }) {
    return SyncEnvelope(
      v: version,
      type: type,
      msgId: const Uuid().v4(),
      peerId: peerId,
      name: name,
      port: port,
      ts: DateTime.now().millisecondsSinceEpoch / 1000.0,
      hash: hash,
      payload: payload,
    );
  }

  factory SyncEnvelope.fromJson(Map<String, dynamic> json) {
    return SyncEnvelope(
      v: json['v'] as int? ?? 0,
      type: json['type'] as String? ?? '',
      msgId: json['msgId'] as String? ?? '',
      peerId: json['peerId'] as String? ?? '',
      name: json['name'] as String?,
      port: json['port'] as int?,
      ts: (json['ts'] as num?)?.toDouble() ?? 0,
      hash: json['hash'] as String?,
      payload: json['payload'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': v,
        'type': type,
        'msgId': msgId,
        'peerId': peerId,
        if (name != null) 'name': name,
        if (port != null) 'port': port,
        'ts': ts,
        if (hash != null) 'hash': hash,
        if (payload != null) 'payload': payload,
      };
}

class SyncType {
  static const hello = 'hello';
  static const welcome = 'welcome';
  static const history = 'history';
  /// Device-list one-shot text send; no mutual authorization required.
  static const historyDirect = 'history.direct';
  static const historyFetch = 'history.fetch';
  static const notifPost = 'notif.post';
  static const notifDismiss = 'notif.dismiss';
  static const notifClear = 'notif.clear';
  static const notifAck = 'notif.ack';
  static const notifConfig = 'notif.config';
  static const ping = 'ping';
  static const pong = 'pong';
  static const ack = 'ack';

  /// Chunked file transfer (device-list send, same no-auth rule as
  /// `history.direct`). `file.meta` payload = encrypted JSON metadata,
  /// `file.chunk` payload = encrypted `u32 BE index ‖ bytes`,
  /// `file.ack` payload = encrypted JSON `{fileId, ok, error?}`.
  static const fileMeta = 'file.meta';
  static const fileChunk = 'file.chunk';
  static const fileAck = 'file.ack';
}

/// Max JSON body size (excluding 4-byte length prefix).
const int syncMaxFrameLength = 2 * 1024 * 1024;

/// Returns a compact `Uint8List`. Spreading into `[...]` produced a growable
/// `List<int>` where every byte occupies an 8-byte VM slot — an 8x blowup on
/// every in-flight frame, the pending queue and each pending_sync BLOB.
List<int>? syncEncodeFrame(SyncEnvelope env) {
  try {
    final jsonBytes = utf8.encode(jsonEncode(env.toJson()));
    if (jsonBytes.length > syncMaxFrameLength) return null;
    final header = ByteData(4)..setUint32(0, jsonBytes.length, Endian.big);
    final out = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(jsonBytes);
    return out.toBytes();
  } catch (_) {
    return null;
  }
}

SyncEnvelope? syncDecodeEnvelope(List<int> data) {
  try {
    final map = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    return SyncEnvelope.fromJson(map);
  } catch (_) {
    return null;
  }
}

/// Pull one length-prefixed frame from [buffer], leaving any remainder.
List<int>? syncTryTakeFrame(BytesBuilder buffer,
    {int maxFrameLength = syncMaxFrameLength}) {
  final bytes = buffer.toBytes();
  if (bytes.length < 4) {
    buffer.clear();
    buffer.add(bytes);
    return null;
  }
  final length = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4)))
      .getUint32(0, Endian.big);
  if (length <= 0 || length > maxFrameLength) {
    buffer.clear();
    return null;
  }
  if (bytes.length < 4 + length) {
    buffer.clear();
    buffer.add(bytes);
    return null;
  }
  final frame = bytes.sublist(4, 4 + length);
  final rest = bytes.sublist(4 + length);
  buffer.clear();
  if (rest.isNotEmpty) buffer.add(rest);
  return frame;
}
