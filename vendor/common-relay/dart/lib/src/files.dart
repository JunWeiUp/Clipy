part of '../common_relay.dart';

class PreparedRelayFile {
  final Map<String, dynamic> descriptor;
  final File ciphertext;
  PreparedRelayFile(this.descriptor, this.ciphertext);
}

class RelayFileCrypto {
  static Future<PreparedRelayFile> prepare(RelayIdentity identity, String to, File source, File ciphertext, Map<String, dynamic> metadata) async {
    if (await ciphertext.exists()) throw StateError('Staging already exists');
    final id = hex(identity.sodium.randombytes.buf(16));
    final enc = await RelayEncryptStream.create(identity.sodium);
    final input = await source.open();
    final output = await ciphertext.open(mode: FileMode.write);
    try {
      var seq = 0;
      while (true) {
        final plain = await input.read(65519);
        final cipher = await enc.push(plain, identity.aad(identity.device, to, 'file', id, seq++), finalRecord: plain.isEmpty);
        final prefix = ByteData(4)..setUint32(0, cipher.length);
        await output.writeFrom(prefix.buffer.asUint8List()); await output.writeFrom(cipher);
        if (plain.isEmpty) break;
      }
      await output.flush();
      final wrapped = {...enc.descriptor, 'metadata': metadata};
      final digest = await hashes.sha256.bind(ciphertext.openRead()).first;
      return PreparedRelayFile({'id': id, 'to': to, 'size': await ciphertext.length(), 'sha256': digest.toString(), 'metadata': identity.seal(to, 'file', id, wrapped)}, ciphertext);
    } finally { await input.close(); await output.close(); await enc.close(); }
  }
  static Future<Map<String, dynamic>> decrypt(RelayIdentity identity, String from, Map<String, dynamic> info, File ciphertext, File destination) async {
    if (await destination.exists()) throw StateError('Destination exists');
    if ((await hashes.sha256.bind(ciphertext.openRead()).first).toString() != info['sha256']) throw StateError('Ciphertext digest mismatch');
    final id = info['id'] as String;
    final descriptor = identity.open(from, 'file', id, info['metadata'] as String);
    final dec = RelayDecryptStream.create(identity.sodium, descriptor);
    final temporary = File('${destination.path}.${hex(identity.sodium.randombytes.buf(16))}.partial');
    final input = await ciphertext.open(), output = await temporary.open(mode: FileMode.write);
    try {
      var seq = 0;
      while (true) {
        final prefix = await input.read(4); if (prefix.isEmpty) break;
        if (prefix.length != 4) throw StateError('Truncated record');
        final size = ByteData.sublistView(prefix).getUint32(0);
        if (size < 17 || size > 65536) throw StateError('Invalid record size');
        final cipher = await input.read(size); if (cipher.length != size) throw StateError('Truncated ciphertext');
        await output.writeFrom(await dec.pull(cipher, identity.aad(from, identity.device, 'file', id, seq++)));
      }
      if (!dec.finished) throw StateError('Missing final record');
      await output.flush(); await output.close();
      // Application supplies a unique destination; do not derive a filesystem path from remote metadata.
      if (await destination.exists()) throw StateError('Destination appeared during transfer');
      await temporary.rename(destination.path);
      return descriptor['metadata'] as Map<String, dynamic>;
    } finally { await input.close(); try { await output.close(); } catch (_) {} await dec.close(); if (await temporary.exists()) await temporary.delete(); }
  }
}

class RelayFiles {
  final Uri base;
  final String token;
  final http.Client _http;
  RelayFiles(this.base, this.token, {http.Client? client, bool allowLocalTest = false}) : _http = client ?? http.Client() {
    if (base.scheme != 'https' && !(allowLocalTest && base.scheme == 'http' && base.host == '127.0.0.1')) throw ArgumentError('HTTPS required');
  }
  Future<http.Response> _request(String method, String path, {List<int>? body, Map<String, String>? headers}) async {
    final uri = base.replace(path: '${base.path.replaceAll(RegExp(r'/+$'), '')}$path');
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers.addAll({'Authorization': 'Bearer $token', ...?headers});
    if (body != null) request.bodyBytes = body;
    return await http.Response.fromStream(await _http.send(request)).timeout(const Duration(seconds: 60));
  }
  Future<Map<String, dynamic>> upload(PreparedRelayFile file) async {
    final id = file.descriptor['id'] as String;
    var response = await _request('POST', '', body: jsonBytes(file.descriptor));
    if (response.statusCode == 409) response = await _request('GET', '/$id');
    if (response.statusCode != 200 && response.statusCode != 201) throw StateError('File admission ${response.statusCode}');
    final status = jsonDecode(response.body) as Map<String, dynamic>;
    for (final field in ['id', 'to', 'size', 'sha256', 'metadata']) { if (status[field] != file.descriptor[field]) throw StateError('Upload ID conflict'); }
    var offset = status['offset'] as int;
    final input = await file.ciphertext.open();
    try {
      await input.setPosition(offset);
      while (true) {
        final chunk = await input.read(1 << 20); if (chunk.isEmpty) break;
        response = await _request('PUT', '/$id/data', body: chunk, headers: {'Upload-Offset': '$offset'});
        if (response.statusCode != 200) throw StateError('Upload failed ${response.statusCode}');
        offset = (jsonDecode(response.body) as Map<String, dynamic>)['offset'] as int;
      }
    } finally { await input.close(); }
    response = await _request('POST', '/$id/commit');
    if (response.statusCode != 200) throw StateError('Commit failed ${response.statusCode}');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
  Future<List<dynamic>> inbox() async { final r = await _request('GET', ''); if (r.statusCode != 200) throw StateError('Inbox failed'); return jsonDecode(r.body) as List<dynamic>; }
  Future<void> download(Map<String, dynamic> info, File ciphertext) async {
    final size = info['size'] as int, id = info['id'] as String;
    final output = await ciphertext.open(mode: FileMode.append);
    try {
      var offset = await output.length();
      while (offset < size) {
        final end = (offset + (1 << 20) - 1).clamp(0, size - 1);
        final response = await _request('GET', '/$id/data', headers: {'Range': 'bytes=$offset-$end'});
        if (response.statusCode != 206 || response.bodyBytes.length != end - offset + 1) throw StateError('Invalid range download');
        await output.writeFrom(response.bodyBytes); offset += response.bodyBytes.length;
      }
      await output.flush();
    } finally { await output.close(); }
  }
  Future<void> acknowledge(String id) async { final r = await _request('DELETE', '/$id'); if (r.statusCode != 204) throw StateError('Acknowledgement failed'); }
  void close() => _http.close();
}
