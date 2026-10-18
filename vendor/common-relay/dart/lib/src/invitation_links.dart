part of '../common_relay.dart';

/// Fragment keys stay local. Only a domain-separated read token reaches HTTP.
class RelayInvitationLinks {
  static String base64url(List<int> raw) =>
      base64UrlEncode(raw).replaceAll('=', '');
  static Uint8List _decode(String text, int size) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(text))
      throw FormatException('Compact invitation encoding');
    final raw = base64Url.decode(base64Url.normalize(text));
    if (raw.length != size || base64url(raw) != text)
      throw FormatException('Compact invitation size');
    return raw;
  }

  static String readToken(Uint8List key) {
    if (key.length != 32) throw ArgumentError('Invitation key size');
    return RelayGroups.digest([
      ...utf8.encode('common-relay/invitation-link/read/v1\u0000'),
      ...key,
    ]);
  }

  static String seal(
    Sodium sodium,
    Map<String, dynamic> invitation,
    Uint8List key,
    Uint8List nonce,
  ) {
    final secure = SecureKey.fromList(sodium, key);
    try {
      final plain = jsonBytes({
        'version': 1,
        'purpose': 'common-relay/invitation-link/v1',
        'invitation': invitation,
      });
      final cipher = sodium.crypto.secretBox.easy(
        message: plain,
        nonce: nonce,
        key: secure,
      );
      return base64Encode([...nonce, ...cipher]);
    } finally {
      secure.dispose();
    }
  }

  static Map<String, dynamic> open(
    Sodium sodium,
    String packet,
    Uint8List key,
  ) {
    final raw = base64Decode(packet);
    if (raw.length < 40 || raw.length > 16384)
      throw FormatException('Invitation packet size');
    final secure = SecureKey.fromList(sodium, key);
    try {
      final plain = sodium.crypto.secretBox.openEasy(
        cipherText: raw.sublist(24),
        nonce: raw.sublist(0, 24),
        key: secure,
      );
      final value = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      if (value['version'] != 1 ||
          value['purpose'] != 'common-relay/invitation-link/v1')
        throw StateError('Invitation packet scope');
      return value['invitation'] as Map<String, dynamic>;
    } finally {
      secure.dispose();
    }
  }

  static String make(Map<String, dynamic> invitation, Uint8List key) {
    final u = Uri.parse(invitation['url'] as String);
    return 'common-relay://${u.authority}/i/${base64url(unhex(invitation['id'] as String))}#${base64url(key)}';
  }

  static ({String url, String id, Uint8List key}) parse(
    String text, {
    bool allowLocalTest = false,
  }) {
    if (text.length > 2048) throw FormatException('Invitation too long');
    final u = Uri.parse(text);
    if (u.scheme != 'common-relay' ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        text.contains('%') ||
        !RegExp(r'^/i/[A-Za-z0-9_-]{22}$').hasMatch(u.path))
      throw FormatException('Compact invitation URL');
    final scheme = allowLocalTest && u.host == '127.0.0.1' ? 'ws' : 'wss';
    return (
      url: Uri(
        scheme: scheme,
        host: u.host,
        port: u.hasPort ? u.port : null,
        path: '/relay/v1/ws',
      ).toString(),
      id: hex(_decode(u.path.substring(3), 16)),
      key: _decode(u.fragment, 32),
    );
  }
}
