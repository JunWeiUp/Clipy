import 'dart:convert';
import 'relay_configuration.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium/sodium.dart';
import 'package:common_relay/common_relay.dart' as cr;

/// Identity keys, access token and private LAN group key never enter ordinary preferences.
class ClipyRelayIdentity {
  static const _store = FlutterSecureStorage();
  static Future<Map<String, dynamic>>? _pendingIdentity;
  static Future<Map<String, dynamic>> _identity() =>
      _pendingIdentity ??= _loadIdentity().whenComplete(() {
        _pendingIdentity = null;
      });
  static Future<Map<String, dynamic>> _loadIdentity() async {
    final saved = await _store.read(key: 'commonRelayIdentity');
    if (saved != null) return jsonDecode(saved) as Map<String, dynamic>;
    final sodium = await SodiumInit.init();
    final pair = sodium.crypto.box.keyPair();
    final value = {
      'secret_key': cr.hex(pair.secretKey.extractBytes()),
      'public_key': cr.hex(pair.publicKey),
    };
    pair.secretKey.dispose();
    await _store.write(key: 'commonRelayIdentity', value: jsonEncode(value));
    return value;
  }

  static Future<Map<String, dynamic>> localIdentity() => _identity();
  static Future<String> groupExit() async =>
      await _store.read(key: 'commonRelayGroupExit') ?? '';
  static Future<void> saveGroupExit(String value) =>
      _store.write(key: 'commonRelayGroupExit', value: value);
  static Future<String> groupInvitation() async =>
      await _store.read(key: 'commonRelayGroupInvitation') ?? '';
  static Future<void> saveGroupInvitation(String value) =>
      _store.write(key: 'commonRelayGroupInvitation', value: value);
  static Future<String> groupDraft() async =>
      await _store.read(key: 'commonRelayGroupDraft') ?? '';
  static Future<void> saveGroupDraft(String value) =>
      _store.write(key: 'commonRelayGroupDraft', value: value);

  static Future<String> publicInfo(String device) async => jsonEncode({
    'app': 'clipy',
    'device': device,
    'public_key': (await _identity())['public_key'],
  });
  static Future<String> config() async =>
      await _store.read(key: 'commonRelayConfig') ?? '';
  static Future<String> groupKey() async {
    final saved = await _store.read(key: 'privateSyncGroupKey');
    if (saved != null) return saved;
    final sodium = await SodiumInit.init();
    final value = cr.hex(sodium.randombytes.buf(32));
    await _store.write(key: 'privateSyncGroupKey', value: value);
    return value;
  }

  static Future<String> prepareConfig({
    required String existing,
    required String device,
    String accessKey = '',
    String enrollment = '',
  }) async {
    final c = RelayConfiguration.update(
      existing: existing,
      device: device,
      accessKey: accessKey,
      enrollment: enrollment,
    );
    if (c.isEmpty) return '';
    final identity = await _identity();
    if ((enrollment.isNotEmpty && c.containsKey('secret_key')) ||
        c['public_key'] != identity['public_key']) {
      throw const FormatException('publicKeyMismatch');
    }
    for (final entry in (c['trusted_peers'] as Map).entries) {
      if (entry.key is! String ||
          !RelayConfiguration.validDevice(entry.key as String) ||
          entry.value is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(entry.value as String)) {
        throw const FormatException('invalidConfiguration');
      }
    }
    c['secret_key'] = identity['secret_key'];
    return jsonEncode(c);
  }

  static Future<void> saveConfig(String raw) =>
      _store.write(key: 'commonRelayConfig', value: raw);

  static Future<void> importConfig(String raw, String device) async {
    await saveConfig(
      await prepareConfig(existing: '', device: device, enrollment: raw),
    );
  }
}
