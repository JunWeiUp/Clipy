library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
// Pinned sodium native bindings expose init_push before any data record.
import 'package:sodium/src/ffi/bindings/libsodium.ffi.dart' as native;
import 'dart:typed_data';
import 'package:sodium/sodium.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as hashes;

part 'src/files.dart';
part 'src/journal.dart';
part 'src/groups.dart';
part 'src/invitation_links.dart';
part 'src/payload.dart';

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String value) {
  if (value.length.isOdd) throw const FormatException('Invalid hex');
  return Uint8List.fromList([for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]);
}
Uint8List jsonBytes(Object value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

class RelayIdentity {
  final Sodium sodium;
  final String app, group, device;
  final SecureKey secretKey;
  final Uint8List publicKey;
  final Map<String, Uint8List> trustedPeers;
  RelayIdentity({required this.sodium, required this.app, required this.group, required this.device, required this.secretKey, required this.publicKey, required Map<String, Uint8List> trustedPeers}) : trustedPeers = Map.unmodifiable(trustedPeers);
  List<Object> context(String from, String to, String kind, String id) => [1, app, group, from, to, kind, id];
  Uint8List aad(String from, String to, String kind, String id, int seq) => jsonBytes([...context(from, to, kind, id), seq]);
  String seal(String to, String kind, String id, Map<String, dynamic> value) {
    final peer = trustedPeers[to];
    if (peer == null) throw StateError('Untrusted peer');
    final nonce = sodium.randombytes.buf(24);
    final cipher = sodium.crypto.box.easy(message: jsonBytes({'context': context(device, to, kind, id), 'value': value}), nonce: nonce, publicKey: peer, secretKey: secretKey);
    return base64Encode([...nonce, ...cipher]);
  }
  Map<String, dynamic> open(String from, String kind, String id, String body) {
    final peer = trustedPeers[from];
    final raw = base64Decode(body);
    if (peer == null || raw.length < 40) throw StateError('Untrusted peer or invalid envelope');
    final plain = sodium.crypto.box.openEasy(cipherText: Uint8List.sublistView(raw, 24), nonce: Uint8List.sublistView(raw, 0, 24), publicKey: peer, secretKey: secretKey);
    final parsed = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    if (jsonEncode(parsed['context']) != jsonEncode(context(from, device, kind, id))) throw StateError('Context mismatch');
    return parsed['value'] as Map<String, dynamic>;
  }
}

class RelayEncryptStream implements ffi.Finalizable {
  final SecureKey key;
  final ffi.Pointer<ffi.Void> _state;
  final Uint8List header;
  bool finished = false, _closed = false;
  static final _finalizer = ffi.NativeFinalizer(ffi.Native.addressOf(native.sodium_free));
  RelayEncryptStream._(this.key, this._state, this.header) { _finalizer.attach(this, _state, detach: this); }
  static Future<RelayEncryptStream> create(Sodium sodium) async {
    final key = sodium.crypto.secretStream.keygen();
    final state = native.sodium_malloc(native.crypto_secretstream_xchacha20poly1305_statebytes());
    if (state == ffi.nullptr) { key.dispose(); throw StateError('Allocation failed'); }
    final header = calloc<ffi.UnsignedChar>(24), secret = calloc<ffi.UnsignedChar>(32);
    try {
      secret.cast<ffi.Uint8>().asTypedList(32).setAll(0, key.extractBytes());
      if (native.crypto_secretstream_xchacha20poly1305_init_push(state.cast(), header, secret) != 0) throw StateError('Stream initialization failed');
      return RelayEncryptStream._(key, state, Uint8List.fromList(header.cast<ffi.Uint8>().asTypedList(24)));
    } catch (_) { native.sodium_free(state); key.dispose(); rethrow; }
    finally { native.sodium_memzero(secret.cast(), 32); calloc.free(secret); calloc.free(header); }
  }
  Map<String, dynamic> get descriptor => {'key': hex(key.extractBytes()), 'header': hex(header)};
  Future<Uint8List> push(Uint8List data, Uint8List aad, {bool finalRecord = false}) async {
    if (_closed || finished || data.length > 65519) throw StateError('Invalid stream state');
    final plain = calloc<ffi.UnsignedChar>(data.isEmpty ? 1 : data.length), ad = calloc<ffi.UnsignedChar>(aad.isEmpty ? 1 : aad.length), out = calloc<ffi.UnsignedChar>(data.length + 17);
    try {
      plain.cast<ffi.Uint8>().asTypedList(data.length).setAll(0, data); ad.cast<ffi.Uint8>().asTypedList(aad.length).setAll(0, aad);
      if (native.crypto_secretstream_xchacha20poly1305_push(_state.cast(), out, ffi.nullptr, plain, data.length, ad, aad.length, finalRecord ? 3 : 0) != 0) throw StateError('Encryption failed');
      finished = finalRecord; return Uint8List.fromList(out.cast<ffi.Uint8>().asTypedList(data.length + 17));
    } finally { native.sodium_memzero(plain.cast(), data.length); calloc.free(plain); calloc.free(ad); calloc.free(out); }
  }
  Future<void> close() async { if (_closed) return; _closed = true; _finalizer.detach(this); native.sodium_free(_state); key.dispose(); }
}

class RelayDecryptStream {
  final SecureKey key;
  final StreamController<SecretStreamCipherMessage> _input;
  final StreamIterator<SecretStreamPlainMessage> _output;
  bool finished = false;
  RelayDecryptStream._(this.key, this._input, this._output);
  static RelayDecryptStream create(Sodium sodium, Map<String, dynamic> descriptor) {
    final key = SecureKey.fromList(sodium, unhex(descriptor['key'] as String));
    final input = StreamController<SecretStreamCipherMessage>();
    final output = StreamIterator(sodium.crypto.secretStream.pullEx(cipherStream: input.stream, key: key));
    input.add(SecretStreamCipherMessage(unhex(descriptor['header'] as String)));
    return RelayDecryptStream._(key, input, output);
  }
  Future<Uint8List> pull(Uint8List cipher, Uint8List aad) async {
    if (finished || cipher.length < 17 || cipher.length > 65536) throw StateError('Invalid stream state');
    _input.add(SecretStreamCipherMessage(cipher, additionalData: aad));
    if (!await _output.moveNext()) throw StateError('Decryption stream closed');
    final message = _output.current;
    if (message.tag != SecretStreamMessageTag.message && message.tag != SecretStreamMessageTag.finalPush) throw StateError('Invalid stream tag');
    finished = message.tag == SecretStreamMessageTag.finalPush;
    return message.message;
  }
  Future<void> close() async { await _output.cancel(); unawaited(_input.close()); key.dispose(); }
}

class RelayClient {
  final RelayIdentity identity;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _reader;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _streams = <String, RelayStream>{};
  // The application must consume this single-subscription stream promptly.
  final _events = StreamController<Map<String, dynamic>>();
  int _eventCount = 0;
  bool _closed = false;
  final RelayJournal? journal;
  Timer? _cleaner;
  String get _scope => '${identity.app}/${identity.group}/${identity.device}';
  RelayClient(this.identity, {this.journal});
  void cleanup() => journal?.cleanup();
  Stream<Map<String, dynamic>> get events => _events.stream.map((event) { _eventCount--; return event; });
  String newId() => hex(identity.sodium.randombytes.buf(16));
  Future<void> connect(String url, String token, {bool allowLocalTest = false}) async {
    final uri = Uri.parse(url);
    if (_socket != null || (uri.scheme != 'wss' && !(allowLocalTest && uri.scheme == 'ws' && uri.host == '127.0.0.1'))) throw ArgumentError('WSS required');
    final ws = await WebSocket.connect(url, headers: {'Authorization': 'Bearer $token'}, protocols: ['common-relay.v1'], compression: CompressionOptions.compressionOff).timeout(const Duration(seconds: 12));
    _socket = ws; ws.pingInterval = const Duration(seconds: 20);
    final ready = Completer<void>();
    _reader = ws.listen((raw) {
      try {
        if (!ready.isCompleted) {
          final event = jsonDecode(raw as String) as Map<String, dynamic>;
          final own = event['identity'] as Map<String, dynamic>;
          if (ws.protocol != 'common-relay.v1' || event['version'] != 1 || own['app'] != identity.app || own['group'] != identity.group || own['device'] != identity.device || own['public_key'] != hex(identity.publicKey)) throw StateError('Identity mismatch');
          ready.complete(); return;
        }
        _dispatch(raw);
      } catch (e, st) { if (!ready.isCompleted) ready.completeError(e, st); unawaited(close(e)); }
    }, onError: (Object e) { if (!ready.isCompleted) ready.completeError(e); unawaited(close(e)); }, onDone: () { if (!ready.isCompleted) ready.completeError(StateError('Disconnected')); unawaited(close()); });
    try { await ready.future.timeout(const Duration(seconds: 10));
      if (journal != null) _cleaner = Timer.periodic(const Duration(hours: 1), (_) { try { cleanup(); } catch (e) { unawaited(close(e)); } });
    } catch (_) { await close(); rethrow; }
  }
  void send(Map<String, dynamic> event) { final ws = _socket; if (_closed || ws == null) throw StateError('Disconnected'); final text = jsonEncode(event); if (utf8.encode(text).length > 270336) throw ArgumentError('Message too large'); ws.add(text); }
  Future<Map<String, dynamic>> request(Map<String, dynamic> event) async {
    final id = event.putIfAbsent('id', newId) as String;
    if (_pending.containsKey(id)) throw StateError('Duplicate request');
    final result = Completer<Map<String, dynamic>>(); _pending[id] = result;
    try { send(event); return await result.future.timeout(const Duration(seconds: 45)); } finally { _pending.remove(id); }
  }
  /// Queues an online-only frame. This is not a server, device or business receipt.
  Future<void> sendOnline(String to, Uint8List data) async {
    final id = newId();
    send({'type': 'message', 'id': id, 'to': to, 'offline': false, 'body': identity.seal(to, 'message', id, {'data': base64Encode(data)})});
  }
  Future<Map<String, dynamic>> message(String to, Uint8List data, {bool offline = false, String? id}) async {
    final objectId = id ?? newId();
    String body; var expires = 0;
    if (offline) {
      final state = journal;
      if (state == null) throw StateError('Persistent state required');
      final record = state.prepare(_scope, objectId, to, data, 86400, (expiry) => identity.seal(to, 'message', objectId, {'data': base64Encode(data), 'expires': expiry}));
      if (record['status'] == 'received') return {'type': 'received', 'id': objectId};
      body = record['body'] as String; expires = record['expires'] as int;
    } else { body = identity.seal(to, 'message', objectId, {'data': base64Encode(data)}); }
    final result = await request({'type': 'message', 'id': objectId, 'to': to, 'offline': offline, 'body': body, 'expires': expires});
    if (offline && result['type'] == 'received') journal!.complete(_scope, objectId);
    return result;
  }
  Future<void> acknowledge(Map<String, dynamic> event) async {
    if (event['offline'] == true && journal == null) throw StateError('Persistent state required');
    journal?.acknowledge(_scope, event['from'] as String, event['id'] as String);
    await request({'type': 'ack', 'id': event['id'], 'from': event['from']});
  }
  Future<List<dynamic>> peers() async => (await request({'type': 'peers'}))['devices'] as List<dynamic>;
  Future<RelayStream> openStream(String to) async {
    final id = newId(), enc = await RelayEncryptStream.create(identity.sodium);
    final stream = RelayStream._(this, to, id, enc); _streams[id] = stream;
    try {
      final result = await request({'type': 'stream.open', 'id': id, 'to': to, 'body': identity.seal(to, 'stream.open', id, enc.descriptor)});
      stream._decryptor = RelayDecryptStream.create(identity.sodium, identity.open(to, 'stream.accept', id, result['body'] as String));
      return stream;
    } catch (_) { await stream.close(); rethrow; }
  }
  Future<RelayStream> acceptStream(Map<String, dynamic> event) async {
    final id = event['id'] as String, peer = event['from'] as String;
    final enc = await RelayEncryptStream.create(identity.sodium);
    final stream = RelayStream._(this, peer, id, enc);
    stream._decryptor = RelayDecryptStream.create(identity.sodium, identity.open(peer, 'stream.open', id, event['body'] as String)); _streams[id] = stream;
    try { await request({'type': 'stream.accept', 'id': id, 'body': identity.seal(peer, 'stream.accept', id, enc.descriptor)}); return stream; } catch (_) { await stream.close(); rethrow; }
  }
  void _dispatch(dynamic raw) {
    if (raw is List<int>) {
      final data = Uint8List.fromList(raw);
      if (data.length < 26 || data.length > 65561 || data[0] != 1) throw StateError('Invalid frame');
      final id = hex(data.sublist(1, 17));
      _streams[id]?._enqueue(ByteData.sublistView(data, 17, 25).getUint64(0), Uint8List.sublistView(data, 25)); return;
    }
    final e = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = e['id'] as String?;
    if (e['type'] == 'stream.credit') { _streams[id]?._credit(e['sequence'] as int); return; }
    if (e['type'] == 'stream.close') { _streams.remove(id)?._abort(); _pending.remove(id)?.completeError(StateError('Stream closed')); return; }
    if (e['type'] != 'message' && e['type'] != 'stream.open') {
      final pending = _pending.remove(id);
      if (pending != null) { if (e['type'] == 'error') { pending.completeError(StateError(e['code'] as String)); } else { pending.complete(e); } return; }
    }
    if (e['type'] == 'message') {
      if (e['offline'] == true && journal == null) throw StateError('Persistent state required for offline reception');
      final value = identity.open(e['from'] as String, 'message', id!, e['body'] as String); if ((value['expires'] != null && (value['expires'] as int) <= DateTime.now().millisecondsSinceEpoch ~/ 1000) || (journal?.contains(_scope, e['from'] as String, id) ?? false)) {
        if (e['offline'] == true) send({'type': 'ack', 'id': id, 'from': e['from']}); return;
      }
      e['data'] = base64Decode(value['data'] as String); }
    if (['message', 'stream.open', 'peer.up', 'peer.down'].contains(e['type'])) { if (++_eventCount > 64) throw StateError('Event queue overflow'); _events.add(e); }
  }
  Future<void> close([Object? error]) async {
    if (_closed) return; _closed = true; _cleaner?.cancel(); _cleaner = null;
    for (final pending in _pending.values) { pending.completeError(error ?? StateError('Disconnected')); } _pending.clear();
    for (final stream in _streams.values.toList()) { stream._abort(); } _streams.clear();
    await _reader?.cancel(); await _socket?.close(); _socket = null; unawaited(_events.close());
  }
}

class RelayStream {
  final RelayClient client;
  final String peer, id;
  final RelayEncryptStream _encryptor;
  RelayDecryptStream? _decryptor;
  final _queue = <(int, Uint8List)>[];
  Completer<(int, Uint8List)>? _receiver;
  Completer<void>? _creditWaiter;
  int _tx = 0, _rx = 0, _ack = 0;
  bool _closed = false, _sending = false;
  RelayStream._(this.client, this.peer, this.id, this._encryptor);
  bool get receivedFinal => _decryptor?.finished ?? false;
  Future<void> send(Uint8List data, {bool finalRecord = false}) async {
    if (_closed || _sending) throw StateError('Concurrent send or closed stream'); _sending = true;
    try {
      for (var offset = 0; offset < (data.isEmpty ? 1 : data.length); offset += 65519) {
        if (_tx - _ack >= 8) { _creditWaiter = Completer<void>(); await _creditWaiter!.future.timeout(const Duration(seconds: 30)); }
        if (_closed) throw StateError('Stream closed');
        final end = (offset + 65519).clamp(0, data.length);
        final cipher = await _encryptor.push(Uint8List.sublistView(data, offset, end), client.identity.aad(client.identity.device, peer, 'stream', id, _tx), finalRecord: finalRecord && end == data.length);
        final frame = Uint8List(25 + cipher.length); frame[0] = 1; frame.setRange(1, 17, unhex(id)); ByteData.sublistView(frame).setUint64(17, _tx); frame.setRange(25, frame.length, cipher); _tx++;
        final ws = client._socket; if (ws == null || _closed) throw StateError('Disconnected'); ws.add(frame);
      }
    } finally { _sending = false; }
  }
  Future<Uint8List> receive() async {
    if (_closed || _receiver != null) throw StateError('Concurrent receive or closed stream');
    late (int, Uint8List) item;
    if (_queue.isEmpty) { _receiver = Completer<(int, Uint8List)>(); item = await _receiver!.future; } else { item = _queue.removeAt(0); }
    if (item.$1 != _rx || _decryptor == null) throw StateError('Invalid sequence');
    final plain = await _decryptor!.pull(item.$2, client.identity.aad(peer, client.identity.device, 'stream', id, _rx)); _rx++;
    client.send({'type': 'stream.credit', 'id': id, 'sequence': _rx}); return plain;
  }
  void _enqueue(int seq, Uint8List data) { if (_closed) return; final receiver = _receiver; if (receiver != null) { _receiver = null; receiver.complete((seq, data)); } else { if (_queue.length >= 16) throw StateError('Receive overflow'); _queue.add((seq, data)); } }
  void _credit(int seq) { if (seq < _ack || seq > _tx) throw StateError('Invalid credit'); _ack = seq; if (_tx - _ack < 8) { _creditWaiter?.complete(); _creditWaiter = null; } }
  void _abort() { if (_closed) return; _closed = true; _queue.clear(); _receiver?.completeError(StateError('Stream interrupted')); _receiver = null; _creditWaiter?.completeError(StateError('Stream interrupted')); _creditWaiter = null; unawaited(_encryptor.close()); unawaited(_decryptor?.close()); }
  Future<void> close() async { _abort(); client._streams.remove(id); if (!client._closed) client.send({'type': 'stream.close', 'id': id}); }
}
