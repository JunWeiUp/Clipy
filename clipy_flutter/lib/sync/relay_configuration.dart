import 'dart:convert';

/// Editing credentials preserves identity keys and trust; never changes LAN IDs.
enum RelayGroupAccess { unconfigured, legacy, managed }

class RelayConfiguration {
  static RelayGroupAccess groupAccess(Map<String, dynamic> config) {
    if (config['app'] != 'clipy' ||
        config['group'] is! String ||
        (config['group'] as String).isEmpty ||
        config['device'] is! String ||
        (config['device'] as String).isEmpty ||
        config['token'] is! String ||
        (config['token'] as String).length < 32 ||
        config['secret_key'] is! String ||
        (config['secret_key'] as String).length != 64) {
      return RelayGroupAccess.unconfigured;
    }
    return config['group_entry'] is Map
        ? RelayGroupAccess.managed
        : RelayGroupAccess.legacy;
  }

  /// Empty means no server access credential; whitespace is never trimmed.
  static bool validPassword(String value) =>
      value.isEmpty ||
      (value.length >= 8 &&
          value.length <= 128 &&
          value.codeUnits.every((c) => c >= 0x21 && c <= 0x7e));

  static String passwordScope(String url) {
    final uri = Uri.parse(url.trim());
    return Uri(
      scheme: uri.scheme,
      host: uri.host.toLowerCase(),
      port: uri.port == 443 ? null : uri.port,
      path: uri.path,
    ).toString();
  }

  static bool validDevice(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(value);
  static Map<String, dynamic> decode(String raw) =>
      raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;

  static Map<String, dynamic> update({
    required String existing,
    required String device,
    String accessKey = '',
    String enrollment = '',
  }) {
    if (!validDevice(device)) throw const FormatException('invalidDevice');
    final value = Map<String, dynamic>.from(
      decode(enrollment.isEmpty ? existing : enrollment),
    );
    if (value.isEmpty) {
      if (accessKey.isNotEmpty) {
        throw const FormatException('enrollmentRequired');
      }
      return value;
    }
    if (enrollment.isNotEmpty && value['device'] != device) {
      throw const FormatException('deviceMismatch');
    }
    value.remove('password'); // Enrollment never supplies a local credential.
    value['device'] = device;
    if (accessKey.isNotEmpty) value['token'] = accessKey;
    final key = value['token'];
    if (value['app'] != 'clipy' ||
        value['group'] is! String ||
        !validDevice(value['group'] as String) ||
        key is! String ||
        key.length < 32 ||
        key.length > 4096 ||
        value['trusted_peers'] is! Map) {
      throw const FormatException('invalidConfiguration');
    }
    return value;
  }

  /// Old clients advertise only the relay ID (which was their LAN UUID).
  static String? lanPeer(String relayId, Map<String, dynamic>? presence) {
    final id = presence?['peerId'] ?? relayId;
    return id is String &&
            RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
            ).hasMatch(id)
        ? id
        : null;
  }
}
