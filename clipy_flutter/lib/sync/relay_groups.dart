import 'dart:convert';
import 'package:common_relay/common_relay.dart' as cr;
import 'package:sodium/sodium.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'relay_identity.dart';
import 'relay_configuration.dart';

/// Serializes management actions; pending enrollment survives closing the page.
class ClipyRelayGroups {
  static Future<void>? _tail;
  static Future<T> run<T>(Future<T> Function() action) {
    final next = (_tail ?? Future<void>.value()).then((_) => action());
    late final Future<void> tail;
    void release() {
      if (identical(_tail, tail)) _tail = null;
    }

    tail = next.then<void>((_) => release(), onError: (Object _) => release());
    _tail = tail;
    return next;
  }

  static String encodeInvitation(Map<String, dynamic> value) =>
      value['short_link'] as String? ??
      'common-relay://join#${base64Url.encode(utf8.encode(jsonEncode(ClipyRelayIdentity.withoutAccessPassword(value))))}';
  static Future<Map<String, dynamic>> resolveInvitation(String text) async {
    final raw = text.trim();
    if (raw.startsWith('common-relay://') &&
        !raw.startsWith('common-relay://join#')) {
      final endpoint = cr.RelayInvitationLinks.parse(raw);
      await _checkServer(endpoint.url);
      final g = await load();
      final previousPassword = g.config['password'] as String? ?? '';
      if (endpoint.password == null) await requireAccess();
      g.config['app'] = 'clipy';
      final invitation = await g.resolveInvitation(raw);
      // Only adopt a credential after the encrypted invitation's scope and expiry
      // have been verified. A late response must not overwrite edited settings.
      await _checkServer(endpoint.url);
      if (await ClipyRelayIdentity.accessPassword(endpoint.url) !=
          previousPassword) {
        throw StateError('Access credential changed during request');
      }
      if (endpoint.password != null) {
        await ClipyRelayIdentity.saveAccessPassword(
          endpoint.url,
          endpoint.password!,
        );
      }
      return ClipyRelayIdentity.withoutAccessPassword(invitation);
    }
    await requireAccess();
    return decodeInvitation(raw);
  }

  /// Refresh the fragment when resuming an invitation made before password links
  /// or after the administrator changes the server credential.
  static Future<Map<String, dynamic>> invitationForSharing(
    Map<String, dynamic> invitation,
  ) async {
    final result = ClipyRelayIdentity.withoutAccessPassword(invitation);
    final link = result['short_link'] as String?;
    if (link == null) return result;
    final endpoint = cr.RelayInvitationLinks.parse(link);
    await _checkServer(endpoint.url);
    final password = await ClipyRelayIdentity.accessPassword(endpoint.url);
    if (password.isEmpty) throw const FormatException('relayPasswordRequired');
    result['short_link'] = cr.RelayInvitationLinks.make(
      result,
      endpoint.key,
      password: password,
    );
    return result;
  }

  static Map<String, dynamic> decodeInvitation(String text) {
    if (text.length > 8192) throw const FormatException('Invitation too large');
    final raw = text.trim();
    final value = raw.startsWith('common-relay://join#')
        ? utf8.decode(
            base64Url.decode(base64Url.normalize(raw.split('#').last)),
          )
        : raw;
    final code = jsonDecode(value) as Map<String, dynamic>;
    if (code['version'] != 1 ||
        code['app'] != 'clipy' ||
        code['group'] is! String) {
      throw const FormatException('Invalid Clipy invitation');
    }
    return ClipyRelayIdentity.withoutAccessPassword(code);
  }

  static Future<cr.RelayGroups> load() async {
    final raw = await ClipyRelayIdentity.config();
    final c = raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final prefs = await SharedPreferences.getInstance();
    final configured = prefs.getString('syncRelayURL')?.trim() ?? '';
    final saved = (c['url'] as String?)?.trim() ?? '';
    c['url'] = configured.isNotEmpty
        ? configured
        : saved.isNotEmpty
        ? saved
        : 'wss://relay.example.test/relay/v1/ws';
    return _withAccess(await SodiumInit.init(), c);
  }

  static Future<String> _selectedURL() async {
    final prefs = await SharedPreferences.getInstance();
    final selected = prefs.getString('syncRelayURL')?.trim() ?? '';
    if (selected.isNotEmpty) return selected;
    final raw = await ClipyRelayIdentity.config();
    final saved = raw.isEmpty
        ? null
        : (jsonDecode(raw) as Map)['url'] as String?;
    return saved?.trim().isNotEmpty == true
        ? saved!
        : 'wss://relay.example.test/relay/v1/ws';
  }

  static Future<void> requireAccess() async {
    if ((await ClipyRelayIdentity.accessPassword(
      await _selectedURL(),
    )).isEmpty) {
      throw const FormatException('relayPasswordRequired');
    }
  }

  static Future<void> _checkServer(String url) async {
    if (RelayConfiguration.passwordScope(url) !=
        RelayConfiguration.passwordScope(await _selectedURL())) {
      throw const FormatException('relayServerMismatch');
    }
  }

  static Future<cr.RelayGroups> _withAccess(
    Sodium sodium,
    Map<String, dynamic> c,
  ) async {
    await _checkServer(c['url'] as String);
    c.remove('password');
    final password = await ClipyRelayIdentity.accessPassword(
      c['url'] as String,
    );
    if (password.isNotEmpty) c['password'] = password;
    return cr.RelayGroups(sodium, c);
  }

  static Future<void> persist(cr.RelayGroups groups) async {
    await _checkServer(groups.config['url'] as String);
    final currentPassword = await ClipyRelayIdentity.accessPassword(
      groups.config['url'] as String,
    );
    if ((groups.config['password'] as String? ?? '') != currentPassword) {
      throw StateError('Access credential changed during request');
    }
    final raw = await ClipyRelayIdentity.config();
    if (raw.isNotEmpty) {
      final current = jsonDecode(raw) as Map<String, dynamic>;
      if ([
        'device',
        'group',
        'token',
        'secret_key',
      ].any((k) => current[k] != groups.config[k])) {
        throw StateError('Configuration changed during request');
      }
      final old = current['group_entry'] as Map<String, dynamic>?,
          next = groups.config['group_entry'] as Map<String, dynamic>?;
      if (old != null &&
          next != null &&
          (cr.RelayGroups.unpack(old)['revision'] as int) >
              (cr.RelayGroups.unpack(next)['revision'] as int)) {
        return;
      }
    }
    final value = Map<String, dynamic>.from(groups.config)
      ..remove('enrollment_invitation')
      ..remove('enrollment_name')
      ..remove('creation_draft')
      ..remove('password');
    await ClipyRelayIdentity.saveConfig(jsonEncode(value));
  }

  static Future<cr.RelayGroups> draft(
    Map<String, dynamic> invitation,
    String device,
  ) async {
    final saved = await pending();
    final marker = saved?.config['enrollment_invitation'] as Map?;
    if (marker != null &&
        marker['group'] == invitation['group'] &&
        marker['url'] == invitation['url'] &&
        ((invitation['id'] != null &&
                marker['id'] == invitation['id'] &&
                marker['secret'] == invitation['secret']) ||
            (invitation['bootstrap'] != null &&
                marker['bootstrap'] == invitation['bootstrap']))) {
      return saved!;
    }
    final existing = await load();
    if (existing.config.containsKey('group_entry')) {
      throw StateError('Already enrolled. Use the existing group.');
    }
    if (existing.config.containsKey('token') &&
        (existing.config['group'] != invitation['group'] ||
            (invitation['url'] != null &&
                invitation['url'] != existing.config['url']))) {
      throw StateError(
        'Existing identity belongs to a different group or server',
      );
    }
    final c = Map<String, dynamic>.from(existing.config);
    final identity = await ClipyRelayIdentity.localIdentity();
    c.addAll(identity);
    c['device'] =
        c['device'] ??
        (await SharedPreferences.getInstance()).getString(
          'syncRelayDeviceId',
        ) ??
        device;
    c['app'] = 'clipy';
    c['group'] = invitation['group'];
    c['url'] = invitation['url'] ?? c['url'];
    c['trusted_peers'] ??= <String, dynamic>{};
    c.putIfAbsent('token', () => cr.hex(existing.sodium.randombytes.buf(32)));
    return _withAccess(existing.sodium, c);
  }

  static Future<cr.RelayGroups> creationDraft(
    String title,
    String name,
    String device,
  ) async {
    final existing = await load();
    if (existing.config['token'] != null) throw StateError('Already enrolled');
    final saved = await pending();
    if (saved != null) {
      if (saved.config['pending_create'] != null ||
          saved.config['creation_draft'] == true) {
        return saved;
      }
      throw StateError('Finish the pending invitation first');
    }
    final c = <String, dynamic>{
      'url': existing.config['url'],
      'app': 'clipy',
      'device':
          (await SharedPreferences.getInstance()).getString(
            'syncRelayDeviceId',
          ) ??
          device,
      ...await ClipyRelayIdentity.localIdentity(),
    };
    final g = await _withAccess(existing.sodium, c);
    g.prepareCreate(title, name);
    g.config['creation_draft'] = true;
    await savePending(g);
    return g;
  }

  static Future<void> exitGroup({required bool disband}) async {
    final current = await load();
    var raw = await ClipyRelayIdentity.groupExit();
    var saved = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
    if (saved != null &&
        [
          'device',
          'group',
          'token',
          'url',
        ].any((key) => saved![key] != current.config[key])) {
      await ClipyRelayIdentity.saveGroupExit('');
      raw = '';
      saved = null;
    }
    final g = saved == null
        ? current
        : await _withAccess(current.sodium, saved);
    if (raw.isNotEmpty && g.config['exit_disband'] != disband) {
      throw StateError('Retry the pending exit operation');
    }
    await g.prepareExit(disband: disband);
    g.config['exit_disband'] = disband;
    await ClipyRelayIdentity.saveGroupExit(
      jsonEncode(ClipyRelayIdentity.withoutAccessPassword(g.config)),
    );
    try {
      await g.exit();
    } catch (error) {
      if (error.toString().contains('409')) {
        await ClipyRelayIdentity.saveGroupExit(
          jsonEncode(ClipyRelayIdentity.withoutAccessPassword(g.config)),
        );
      }
      rethrow;
    }
  }

  static Future<void> clearEnrollment() async {
    final sodium = await SodiumInit.init();
    // Change only the relay identity, leaving LAN identity and local data intact.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('syncRelayEnabled', false);
    await prefs.setString(
      'syncRelayDeviceId',
      cr.hex(sodium.randombytes.buf(16)),
    );
    await ClipyRelayIdentity.saveConfig('');
    await clearPending();
    await ClipyRelayIdentity.saveGroupInvitation('');
    await ClipyRelayIdentity.saveGroupExit('');
  }

  static Future<void> savePending(cr.RelayGroups groups) =>
      ClipyRelayIdentity.saveGroupDraft(
        jsonEncode(ClipyRelayIdentity.withoutAccessPassword(groups.config)),
      );
  static Future<cr.RelayGroups?> pending() async {
    final raw = await ClipyRelayIdentity.groupDraft();
    if (raw.isEmpty) return null;
    return _withAccess(
      await SodiumInit.init(),
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  static Future<void> clearPending() => ClipyRelayIdentity.saveGroupDraft('');
  static String verificationCode(Map<String, dynamic> request) =>
      cr.RelayGroups.digest(cr.RelayGroups.payload(request))
          .substring(0, 12)
          .toUpperCase()
          .replaceAllMapped(RegExp('.{4}'), (m) => '${m[0]} ')
          .trim();
}
