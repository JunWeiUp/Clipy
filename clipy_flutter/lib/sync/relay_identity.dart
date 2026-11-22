import 'dart:convert';
import 'dart:typed_data';
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

  // Separate from enrollment and invitation drafts; bound to one server URL.
  static Future<String> accessPassword(String url) async {
    final raw = await _store.read(key: 'commonRelayAccessPassword');
    if (raw == null || raw.isEmpty) return '';
    try {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      final value = saved['password'];
      return saved['url'] == RelayConfiguration.passwordScope(url) &&
              value is String &&
              RelayConfiguration.validPassword(value)
          ? value
          : '';
    } on FormatException {
      return '';
    } on TypeError {
      return '';
    }
  }

  static Future<void> saveAccessPassword(String url, String value) async {
    if (!RelayConfiguration.validPassword(value)) {
      throw const FormatException('invalidRelayPassword');
    }
    await _store.write(
      key: 'commonRelayAccessPassword',
      value: jsonEncode({
        'url': RelayConfiguration.passwordScope(url),
        'password': value,
      }),
    );
  }

  static Map<String, dynamic> withoutAccessPassword(
    Map<String, dynamic> config,
  ) => Map<String, dynamic>.from(config)..remove('password');

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
    final hex64 = RegExp(r'^[a-fA-F0-9]{64}$');
    for (final entry in (c['trusted_peers'] as Map).entries) {
      if (entry.key is! String ||
          !RelayConfiguration.validDevice(entry.key as String) ||
          entry.value is! String ||
          !hex64.hasMatch(entry.value as String)) {
        throw const FormatException('invalidConfiguration');
      }
    }
    final suppliedSecret = c['secret_key'];
    final suppliedPublic = c['public_key'];
    if (enrollment.isNotEmpty &&
        suppliedSecret is String &&
        suppliedSecret.isNotEmpty) {
      if (!hex64.hasMatch(suppliedSecret) ||
          suppliedPublic is! String ||
          !hex64.hasMatch(suppliedPublic)) {
        throw const FormatException('publicKeyMismatch');
      }
      final sodium = await SodiumInit.init();
      final sk = SecureKey.fromList(sodium, cr.unhex(suppliedSecret));
      try {
        final pk = cr.unhex(suppliedPublic);
        final probe = Uint8List.fromList([1, 2, 3, 4]);
        final sealed = sodium.crypto.box.seal(message: probe, publicKey: pk);
        final opened = sodium.crypto.box.sealOpen(
          cipherText: sealed,
          publicKey: pk,
          secretKey: sk,
        );
        if (opened.length != probe.length) {
          throw const FormatException('publicKeyMismatch');
        }
      } catch (_) {
        throw const FormatException('publicKeyMismatch');
      } finally {
        sk.dispose();
      }
      final normalizedSecret = suppliedSecret.toLowerCase();
      final normalizedPublic = suppliedPublic.toLowerCase();
      await _store.write(
        key: 'commonRelayIdentity',
        value: jsonEncode({
          'secret_key': normalizedSecret,
          'public_key': normalizedPublic,
        }),
      );
      c['secret_key'] = normalizedSecret;
      c['public_key'] = normalizedPublic;
    } else {
      final identity = await _identity();
      if (suppliedPublic != identity['public_key']) {
        throw const FormatException('publicKeyMismatch');
      }
      c['secret_key'] = identity['secret_key'];
    }
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
