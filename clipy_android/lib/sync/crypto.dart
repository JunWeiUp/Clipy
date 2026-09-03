import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// AES-GCM + HKDF helpers shared with macOS SyncCrypto.
/// See docs/PROTOCOL.md.
class SyncCrypto {
  static const String legacySharedSecret = 'ClipySyncSecret2026';
  static const String keyDerivationSalt = 'clipy.sync.v2.hkdf';
  static const String keyDerivationInfo = 'aes-256-gcm';

  String _pairingSecret = '';
  String? _cachedKeySecret;
  enc.Key? _cachedKey;

  String get pairingSecret => _pairingSecret;

  set pairingSecret(String value) {
    if (value == _pairingSecret) return;
    _pairingSecret = value;
    _cachedKeySecret = null;
    _cachedKey = null;
  }

  void clearKeyCache() {
    _cachedKeySecret = null;
    _cachedKey = null;
  }

  /// HKDF-SHA256 (RFC 5869), mirroring CryptoKit's `HKDF<SHA256>.deriveKey`.
  static Uint8List hkdfSha256({
    required List<int> ikm,
    required List<int> salt,
    required List<int> info,
    required int length,
  }) {
    final prk = Hmac(sha256, salt).convert(ikm).bytes;
    final out = <int>[];
    var block = <int>[];
    var counter = 1;
    while (out.length < length) {
      block = Hmac(sha256, prk).convert([...block, ...info, counter]).bytes;
      out.addAll(block);
      counter++;
    }
    return Uint8List.fromList(out.sublist(0, length));
  }

  enc.Key key() {
    final secret = _pairingSecret;
    if (_cachedKeySecret == secret && _cachedKey != null) return _cachedKey!;
    final Uint8List bytes;
    if (secret.isEmpty) {
      bytes = Uint8List.fromList(
        sha256.convert(utf8.encode(legacySharedSecret)).bytes,
      );
    } else {
      bytes = hkdfSha256(
        ikm: utf8.encode(secret),
        salt: utf8.encode(keyDerivationSalt),
        info: utf8.encode(keyDerivationInfo),
        length: 32,
      );
    }
    final derived = enc.Key(bytes);
    _cachedKeySecret = secret;
    _cachedKey = derived;
    return derived;
  }

  String? encryptText(String text) {
    try {
      final k = key();
      final rng = Random.secure();
      final iv = enc.IV(
        Uint8List.fromList(List<int>.generate(12, (_) => rng.nextInt(256))),
      );
      final encrypter = enc.Encrypter(enc.AES(k, mode: enc.AESMode.gcm));
      final encrypted = encrypter.encrypt(text, iv: iv);
      final combined = Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
      return base64Encode(combined);
    } catch (_) {
      return null;
    }
  }

  String? decryptText(String base64String) {
    try {
      final k = key();
      final data = base64Decode(base64String);
      if (data.length <= 28) return null;
      final iv = enc.IV(data.sublist(0, 12));
      final encryptedBytes = data.sublist(12);
      final encrypter = enc.Encrypter(enc.AES(k, mode: enc.AESMode.gcm));
      return encrypter.decrypt(enc.Encrypted(encryptedBytes), iv: iv);
    } catch (_) {
      return null;
    }
  }

  /// Binary variant of [encryptText] for file chunks: wire form is the same
  /// `base64(nonce12 ‖ ciphertext ‖ tag)` so it interops with the Swift side.
  ///
  /// On Android the heavy lifting goes through the native `sync_crypto`
  /// MethodChannel (javax.crypto / ARMv8 crypto extensions — pure-Dart
  /// pointycastle tops out at tens of MB/s and is the transfer bottleneck).
  /// Any failure (desktop, tests, native error) falls back to pure Dart.
  Future<String?> encryptBytes(List<int> bytes) async {
    final nonce = _randomNonce();
    final keyBytes = key().bytes;
    final native = await (SyncCrypto.nativeAesGcm?.call(
      'seal',
      keyBytes,
      nonce,
      Uint8List.fromList(bytes),
      null,
    ));
    if (native != null) {
      return base64Encode(native);
    }
    try {
      final k = key();
      final encrypter = enc.Encrypter(enc.AES(k, mode: enc.AESMode.gcm));
      final encrypted = encrypter.encryptBytes(bytes, iv: enc.IV(nonce));
      final combined = Uint8List.fromList([...nonce, ...encrypted.bytes]);
      return base64Encode(combined);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> decryptToBytes(String base64String) async {
    try {
      final data = base64Decode(base64String);
      if (data.length <= 28) return null;
      final nonce = data.sublist(0, 12);
      final sealed = data.sublist(12);
      final native = await (SyncCrypto.nativeAesGcm?.call(
        'open',
        key().bytes,
        nonce,
        null,
        sealed,
      ));
      if (native != null) return native;
      final k = key();
      final encrypter = enc.Encrypter(enc.AES(k, mode: enc.AESMode.gcm));
      return Uint8List.fromList(
        encrypter.decryptBytes(enc.Encrypted(sealed), iv: enc.IV(nonce)),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _randomNonce() {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(12, (_) => rng.nextInt(256)));
  }

  /// Native fast path injected by the app layer (SyncManager wires this to
  /// the `sync_crypto` MethodChannel on Android). Returns `nonce ‖ ct ‖ tag`
  /// (seal) / plaintext (open), or null → pure-Dart fallback. Kept as a hook
  /// so this file stays pure Dart (unit tests / dart-run tools import it).
  static Future<Uint8List?> Function(
    String op,
    Uint8List key,
    Uint8List nonce,
    Uint8List? plain,
    Uint8List? sealed,
  )?
  nativeAesGcm;
}
