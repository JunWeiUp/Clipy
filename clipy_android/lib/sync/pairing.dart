import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync_manager.dart';

/// Pairing code generation and `clipy://pair` link import (the Mac shows the
/// link as a QR code). Mirrors `SyncPairing.swift`; see docs/PROTOCOL.md
/// "Pairing".
class SyncPairing {
  SyncPairing._();

  /// Crockford base32 without I/L/O/U — unambiguous when read aloud or typed.
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// 20 symbols × 5 bits = 100 bits of CSPRNG entropy, `XXXX-XXXX-…` groups.
  static String generateCode([Random? random]) {
    final rng = random ?? Random.secure();
    final symbols = List.generate(20, (_) => _alphabet[rng.nextInt(32)]);
    return [
      for (var i = 0; i < symbols.length; i += 4)
        symbols.sublist(i, i + 4).join(),
    ].join('-');
  }

  /// Parses `clipy://pair?code=..&port=..&host=..&name=..`; null when the
  /// URI is not a pairing link or carries no code.
  static PairingLink? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'clipy' || uri.host != 'pair') {
      return null;
    }
    final code = uri.queryParameters['code']?.trim() ?? '';
    if (code.isEmpty) return null;
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final host = uri.queryParameters['host']?.trim();
    return PairingLink(
      code: code,
      host: host == null || host.isEmpty ? null : host,
      port: port != null && port > 0 && port <= 65535 ? port : null,
      name: uri.queryParameters['name']?.trim() ?? '',
    );
  }

  /// Saves the link's secret and remembers the sender as a manual peer so
  /// the first connection does not depend on a /24 scan.
  static Future<void> apply(PairingLink link) async {
    await SyncManager.instance.updatePairingSecret(link.code);
    final host = link.host;
    if (host == null) return;
    final entry = '$host:${link.port ?? SyncManager.instance.port}';
    final prefs = await SharedPreferences.getInstance();
    final peers = prefs.getStringList('manualSyncPeers') ?? [];
    if (!peers.contains(entry)) {
      peers.add(entry);
      await prefs.setStringList('manualSyncPeers', peers);
    }
    if (SyncManager.instance.isEnabled) {
      SyncManager.instance.triggerCrossBandDiscovery();
    }
  }
}

class PairingLink {
  const PairingLink({
    required this.code,
    required this.host,
    required this.port,
    required this.name,
  });
  final String code;
  final String? host;
  final int? port;
  final String name;
}

/// Delivers `clipy://pair` links opened from the camera/browser. MainActivity
/// holds the latest link until the UI asks for it, so a cold start does not
/// lose it. Links are only surfaced — applying one always needs the user's
/// confirmation, since any app can fire a deep link.
class PairingLinkChannel {
  PairingLinkChannel._();
  static final instance = PairingLinkChannel._();

  static const _channel = MethodChannel('com.clipyclone.clipy_android/pairing');
  final _links = StreamController<PairingLink>.broadcast();
  bool _attached = false;

  Stream<PairingLink> get links => _links.stream;

  /// Call once the UI can show a dialog; replays a link that launched the app.
  Future<void> attach() async {
    if (!_attached) {
      _attached = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'linkAvailable') await _drain();
      });
    }
    await _drain();
  }

  Future<void> _drain() async {
    try {
      final raw = await _channel.invokeMethod<String>('takePendingLink');
      final link = raw == null ? null : SyncPairing.parse(raw);
      if (link != null) _links.add(link);
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // Activity not attached yet; the next linkAvailable retries.
    }
  }
}
