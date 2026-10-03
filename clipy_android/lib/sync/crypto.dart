import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// Default AES-GCM transport encryption for the trusted-LAN protocol.
/// The built-in key is shared by every installation; it is not device identity.
class SyncCrypto {
  static const defaultKeySeed = 'ClipySyncSecret2026';
  static final enc.Key _defaultKey = enc.Key(
    Uint8List.fromList(sha256.convert(utf8.encode(defaultKeySeed)).bytes),
  );

  enc.Key key() => _defaultKey;

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
    final k = key();
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
