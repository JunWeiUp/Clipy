import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// AES-GCM + HKDF helpers shared with macOS SyncCrypto.
/// See docs/PROTOCOL.md.
class SyncCrypto {
  /// hello/welcome `payload` = encrypt(prefix + sender peerId); see
  /// [pairingProof].
  static const String pairingProofPrefix = 'clipy.pair.v1:';
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

  bool get isPaired => _pairingSecret.isNotEmpty;

  /// Transport key: the pairing secret stretched with HKDF. `null` while
  /// unpaired — there is deliberately no shipped fallback key, so an unpaired
  /// device can neither encrypt, decrypt nor complete a handshake.
  enc.Key? key() {
    final secret = _pairingSecret;
    if (secret.isEmpty) return null;
    if (_cachedKeySecret == secret && _cachedKey != null) return _cachedKey!;
    final derived = enc.Key(
      hkdfSha256(
        ikm: utf8.encode(secret),
        salt: utf8.encode(keyDerivationSalt),
        info: utf8.encode(keyDerivationInfo),
        length: 32,
      ),
    );
    _cachedKeySecret = secret;
    _cachedKey = derived;
    return derived;
  }

  /// Handshake proof: our peerId sealed with the pairing key. A peer holding
  /// a different secret cannot open it, so the mismatch fails the handshake
  /// instead of every later frame silently failing to decrypt.
  String? pairingProof(String selfPeerId) =>
      encryptText('$pairingProofPrefix$selfPeerId');

  /// A missing proof comes from a pre-proof build; it is accepted for
  /// compatibility (it still cannot decrypt anything without our secret).
  bool verifyPairingProof(String? proof, String remotePeerId) {
    if (proof == null) return true;
    return decryptText(proof) == '$pairingProofPrefix$remotePeerId';
  }

  String? encryptText(String text) {
    try {
      final k = key();
      if (k == null) return null;
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
      if (k == null) return null;
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
    final k = key();
    if (k == null) return null;
    final nonce = _randomNonce();
    final keyBytes = k.bytes;
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
      final k = key();
      if (k == null) return null;
      final data = base64Decode(base64String);
      if (data.length <= 28) return null;
      final nonce = data.sublist(0, 12);
      final sealed = data.sublist(12);
      final native = await (SyncCrypto.nativeAesGcm?.call(
        'open',
        k.bytes,
        nonce,
        null,
        sealed,
      ));
      if (native != null) return native;
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
