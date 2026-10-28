part of '../common_relay.dart';

/// Client-signed membership. Persist [config] in private storage after operations.
/// First trust comes from an invitation/QR, never from the relay's device list.
class RelayGroups {
  final Sodium sodium;
  final Map<String, dynamic> config;
  final bool allowLocalTest;
  RelayGroups(this.sodium, this.config, {this.allowLocalTest = false});
  static const domain = 'common-relay/group-signing/v1\u0000';
  static String digest(List<int> data) =>
      hashes.sha256.convert(data).toString();
  static Uint8List payload(Map<String, dynamic> e) =>
      base64Decode(e['payload'] as String);
  static Map<String, dynamic> unpack(Map<String, dynamic> e) {
    final raw = payload(e);
    // Every signed payload is a state, join request or admission grant.
    if (!_schemas.any((schema) => _strict(raw, schema))) throw StateError('Ambiguous signed payload');
    return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  }
  KeyPair _signing() {
    final seed = SecureKey.fromList(
      sodium,
      Uint8List.fromList(
        hashes.sha256.convert([
          ...utf8.encode(domain),
          ...unhex(config['secret_key'] as String),
        ]).bytes,
      ),
    );
    try {
      return sodium.crypto.sign.seedKeyPair(seed);
    } finally {
      seed.dispose();
    }
  }

  Map<String, dynamic> sign(Map<String, dynamic> value) {
    final pair = _signing();
    try {
      final bytes = jsonBytes(value);
      return {
        'payload': base64Encode(bytes),
        'signature': hex(
          sodium.crypto.sign.detached(
            message: bytes,
            secretKey: pair.secretKey,
          ),
        ),
        'signer': config['device'],
      };
    } finally {
      pair.secretKey.dispose();
    }
  }

  void verify(Map<String, dynamic> e, String key) {
    if (!sodium.crypto.sign.verifyDetached(
      signature: unhex(e['signature'] as String),
      message: payload(e),
      publicKey: unhex(key),
    ))
      throw StateError('Invalid membership signature');
  }

  Map<String, dynamic> member(String name) {
    final pair = _signing();
    final raw = unhex(config['secret_key'] as String);
    if (raw.length != 32) {
      pair.secretKey.dispose();
      throw StateError('Invalid identity');
    }
    final secret = calloc<ffi.UnsignedChar>(32),
        public = calloc<ffi.UnsignedChar>(32);
    secret.cast<ffi.Uint8>().asTypedList(32).setAll(0, raw);
    try {
      if (native.crypto_scalarmult_base(public, secret) != 0)
        throw StateError('Invalid identity');
      return {
        'device': config['device'],
        'name': name,
        'public_key': hex(public.cast<ffi.Uint8>().asTypedList(32)),
        'signing_key': hex(pair.publicKey),
        'manager': false,
      };
    } finally {
      pair.secretKey.dispose();
      native.sodium_memzero(secret.cast(), 32);
      calloc.free(secret);
      calloc.free(public);
    }
  }

  void _validate(Map<String, dynamic> state) {
    final members = state['members'] as List;
    if (state['version'] != 1 ||
        state['app'] != config['app'] ||
        state['group'] != config['group'] ||
        (state['closed'] == true ? members.isNotEmpty : members.isEmpty) ||
        members.length > 32 ||
        members.map((m) => m['device']).toSet().length != members.length ||
        (state['closed'] != true && !members.any((m) => m['manager'] == true)))
      throw StateError('Invalid membership');
  }

  static bool _same(Map a, Map b) =>
      a.length == b.length && a.keys.every((k) => a[k] == b[k]);
  Map<String, dynamic> advance(
    Map<String, dynamic> current,
    Map<String, dynamic> entry,
  ) {
    final old = unpack(current), next = unpack(entry);
    _validate(next);
    final actor = (old['members'] as List)
        .where((m) => m['device'] == entry['signer'])
        .firstOrNull;
    if (actor == null || old['closed'] == true)
      throw StateError('Untrusted manager');
    if (entry['authorization'] == null)
      verify(entry, actor['signing_key'] as String);
    if ((next['name'] ?? '') != (old['name'] ?? '') ||
        next['revision'] != (old['revision'] as int) + 1 ||
        next['previous'] != digest(payload(current)))
      throw StateError('Broken membership chain');
    if (entry['authorization'] != null) {
      _advanceAuto(current, entry, old, next, actor as Map<String, dynamic>);
      return entry;
    }
    final before = {
      for (final m in old['members'] as List) m['device']: m as Map,
    };
    final after = {
      for (final m in next['members'] as List) m['device']: m as Map,
    };
    final upgrades = <dynamic>{}, renamed = <dynamic>{};
    for (final k in before.keys.toSet().intersection(after.keys.toSet())) {
      if (!_same(before[k]!, after[k]!)) {
        final same = Map.from(before[k]!)..['name'] = after[k]!['name'];
        if (_same(same, after[k]!)) {
          renamed.add(k);
          continue;
        }
        if (before[k]!['signing_key'] == '' &&
            after[k]!['signing_key'] != '' &&
            before[k]!['public_key'] == after[k]!['public_key']) {
          upgrades.add(k);
        } else {
          throw StateError('Identity replacement');
        }
      }
    }
    final added = after.keys
            .toSet()
            .difference(before.keys.toSet())
            .union(upgrades),
        removed = before.keys.toSet().difference(after.keys.toSet());
    if (renamed.isNotEmpty) {
      if (renamed.length != 1 ||
          added.isNotEmpty ||
          removed.isNotEmpty ||
          next['invitation'] != '' ||
          next['request_hash'] != '' ||
          !(actor['manager'] == true || renamed.contains(entry['signer'])))
        throw StateError('Invalid rename');
      return entry;
    }
    if (!((next['closed'] == true &&
            actor['manager'] == true &&
            after.isEmpty &&
            next['invitation'] == '' &&
            next['request_hash'] == '') ||
        (actor['manager'] == true &&
            added.length == 1 &&
            removed.isEmpty &&
            next['invitation'] != '' &&
            next['request_hash'] != '') ||
        (removed.length == 1 &&
            added.isEmpty &&
            next['invitation'] == '' &&
            next['request_hash'] == '' &&
            (actor['manager'] == true || removed.contains(entry['signer'])))))
      throw StateError('Invalid membership transition');
    return entry;
  }

  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Object? value,
    String? authorization,
  }) async {
    final uri = Uri.parse(config['url'] as String);
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/relay/v1/ws' ||
        (uri.scheme != 'wss' &&
            !(allowLocalTest && uri.scheme == 'ws' && uri.host == '127.0.0.1')))
      throw ArgumentError('WSS required');
    final base = uri
        .replace(
          scheme: uri.scheme == 'wss' ? 'https' : 'http',
          path: '/relay/v1',
        )
        .toString();
    final client = http.Client();
    try {
      final req = http.Request(method, Uri.parse('$base$path'))
        ..followRedirects = false;
      req.headers['Authorization'] =
          authorization ?? 'Bearer ${config['token'] ?? ''}';
      if (value != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(value);
      }
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200)
        throw StateError('Group request failed (${res.statusCode})');
      final bytes = <int>[];
      await for (final chunk in res.stream.timeout(
        const Duration(seconds: 15),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 3 * 1024 * 1024)
          throw StateError('Response too large');
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  void accept(Map<String, dynamic> e) {
    config['group_entry'] = e;
    config['trusted_peers'] = {
      for (final m in unpack(e)['members'] as List)
        if (m['device'] != config['device'])
          m['device'] as String: m['public_key'],
    };
    config['public_key'] = member(config['device'] as String)['public_key'];
  }

  Future<Map<String, dynamic>> refresh() async {
    var current = config['group_entry'] as Map<String, dynamic>?;
    if (current == null)
      throw StateError('Group management requires enrollment');
    while (true) {
      final result = await call(
        'GET',
        '/group?after=${unpack(current!)['revision']}',
      );
      for (final entry in result['entries'] as List) {
        current = advance(current!, entry as Map<String, dynamic>);
      }
      accept(current!);
      if ((result['entries'] as List).isEmpty ||
          (unpack(current)['revision'] as int) >= (result['revision'] as int))
        return {'state': unpack(current), 'online': result['online']};
    }
  }

  void prepareCreate(String groupName, String deviceName) {
    if (config['group_entry'] != null || config['pending_join'] != null)
      throw StateError('Already enrolled or joining');
    if (config['pending_create'] != null) return;
    final title = groupName.trim(), name = deviceName.trim();
    if (utf8.encode(title).isEmpty ||
        utf8.encode(title).length > 128 ||
        utf8.encode(name).isEmpty ||
        utf8.encode(name).length > 128 ||
        config['group'] != null)
      throw StateError('Invalid name or existing group');
    config['group'] = 'g-${hex(sodium.randombytes.buf(16))}';
    config.putIfAbsent('token', () => hex(sodium.randombytes.buf(32)));
    final own = member(name)..['manager'] = true;
    config['pending_create'] = sign({
      'version': 1,
      'app': config['app'],
      'group': config['group'],
      'name': title,
      'revision': 1,
      'previous': '',
      'members': [own],
      'invitation': '',
      'request_hash': '',
    });
  }

  Future<void> create() async {
    final entry = config['pending_create'] as Map<String, dynamic>;
    await call(
      'POST',
      '/group/create',
      value: {
        'entry': entry,
        'token_hash': digest(utf8.encode(config['token'] as String)),
      },
    );
    accept(entry);
    config.remove('pending_create');
  }

  Future<void> bootstrap(Map<String, dynamic> code, String name) async {
    if (code['app'] != config['app'] || code['group'] != config['group'])
      throw StateError('Bootstrap scope mismatch');
    config.putIfAbsent('token', () => hex(sodium.randombytes.buf(32)));
    final own = member(name)..['manager'] = true;
    final peers = config['trusted_peers'] as Map? ?? {};
    final e = sign({
      'version': 1,
      'app': config['app'],
      'group': config['group'],
      'revision': 1,
      'previous': '',
      'members': [
        own,
        for (final k in peers.keys)
          if (k != config['device'])
            {
              'device': k,
              'name': k,
              'public_key': peers[k],
              'signing_key': '',
              'manager': false,
            },
      ],
      'invitation': '',
      'request_hash': '',
    });
    await call(
      'POST',
      '/group/bootstrap',
      value: {
        'entry': e,
        'token_hash': digest(utf8.encode(config['token'] as String)),
      },
      authorization: 'Bootstrap ${code['bootstrap']}',
    );
    accept(e);
  }

  Future<Map<String, dynamic>> invite({
    String mode = 'manual',
    bool compact = false,
  }) async {
    if (!['manual', 'auto'].contains(mode))
      throw StateError('Unknown invitation mode');
    await refresh();
    final current = config['group_entry'] as Map<String, dynamic>,
        state = unpack(config['group_entry'] as Map<String, dynamic>);
    final own = (state['members'] as List).firstWhere(
      (m) => m['device'] == config['device'],
    );
    if (own['manager'] != true) throw StateError('Manager permission required');
    final secret = hex(sodium.randombytes.buf(32));
    final data = <String, dynamic>{'secret_hash': digest(utf8.encode(secret))},
        extra = <String, dynamic>{};
    if (mode == 'auto') {
      final delegate = hex(sodium.randombytes.buf(32));
      final grant = sign({
        'version': 1,
        'purpose': 'common-relay/admission/v1',
        'mode': 'auto',
        'app': config['app'],
        'group': config['group'],
        'invitation': hex(sodium.randombytes.buf(16)),
        'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
        'secret_hash': data['secret_hash'],
        'delegate_key': _delegateSigner(
          delegate,
          config['device'] as String,
        ).member('')['signing_key'],
        'anchor_revision': state['revision'],
        'anchor_hash': digest(payload(current)),
      });
      data['mode'] = mode;
      data['grant'] = grant;
      extra.addAll({'grant': grant, 'delegate_secret': delegate});
    }
    final result = await call('POST', '/group/invitations', value: data);
    if (mode == 'auto') {
      final g = unpack(extra['grant'] as Map<String, dynamic>);
      if (result['mode'] != mode ||
          result['id'] != g['invitation'] ||
          result['expires'] != g['expires'])
        throw StateError('Automatic admission unsupported');
    }
    final invitation = <String, dynamic>{
      ...extra,
      'version': 1,
      'mode': mode,
      'url': config['url'],
      'app': config['app'],
      'group': config['group'],
      'id': result['id'],
      'expires': result['expires'],
      'secret': secret,
      'manager': own,
    };
    if (compact) await publishInvitation(invitation);
    return invitation;
  }

  Future<String> publishInvitation(Map<String, dynamic> invitation) async {
    final key = sodium.randombytes.buf(32), nonce = sodium.randombytes.buf(24);
    final packet = RelayInvitationLinks.seal(sodium, invitation, key, nonce);
    await call(
      'POST',
      "/group/invitations/${invitation['id']}/link",
      value: {
        'read_hash': digest(utf8.encode(RelayInvitationLinks.readToken(key))),
        'packet': packet,
      },
    );
    final link = RelayInvitationLinks.make(invitation, key);
    invitation['short_link'] = link;
    return link;
  }

  Future<Map<String, dynamic>> resolveInvitation(String text) async {
    final p = RelayInvitationLinks.parse(
      text.trim(),
      allowLocalTest: allowLocalTest,
    );
    final endpoint = RelayGroups(sodium, {
      'url': p.url,
    }, allowLocalTest: allowLocalTest);
    final result = await endpoint.call(
      'GET',
      '/enroll/${p.id}/link',
      authorization: 'InvitationLink ${RelayInvitationLinks.readToken(p.key)}',
    );
    if (result['version'] != 1) throw StateError('Invitation packet version');
    final inv = RelayInvitationLinks.open(
      sodium,
      result['packet'] as String,
      p.key,
    );
    if (inv['version'] != 1 ||
        inv['url'] != p.url ||
        inv['id'] != p.id ||
        inv['app'] != config['app'] ||
        (inv['expires'] as int) <=
            DateTime.now().millisecondsSinceEpoch ~/ 1000)
      throw StateError('Invalid or expired invitation scope');
    return inv;
  }

  Future<Map<String, dynamic>?> pending(Map<String, dynamic> invitation) async {
    final result = await call('GET', '/group/invitations/${invitation['id']}');
    final e = result['request'] as Map<String, dynamic>?;
    if (e != null) {
      final j = unpack(e);
      verify(e, j['member']['signing_key'] as String);
      if (j['invitation'] != invitation['id'] ||
          j['app'] != config['app'] ||
          j['group'] != config['group'] ||
          e['signer'] != j['member']['device'])
        throw StateError('Join scope mismatch');
    }
    return e;
  }

  Future<void> join(Map<String, dynamic> invitation, String name) async {
    if (invitation['version'] != 1 ||
        (invitation['expires'] as int) <=
            DateTime.now().millisecondsSinceEpoch ~/ 1000 ||
        ['url', 'app', 'group'].any((k) => invitation[k] != config[k]))
      throw StateError('Invalid or expired invitation');
    final mode = invitation['mode'] ?? 'manual';
    if (!['manual', 'auto'].contains(mode))
      throw StateError('Unknown invitation mode');
    if (mode == 'auto') _invitationGrant(invitation);
    config.putIfAbsent('token', () => hex(sodium.randombytes.buf(32)));
    final pending = config['pending_join'] as Map?;
    final e = pending?['invitation']?['id'] == invitation['id']
        ? pending!['request'] as Map<String, dynamic>
        : sign({
            'version': 1,
            'app': config['app'],
            'group': config['group'],
            'invitation': invitation['id'],
            'member': member(name),
            'token_hash': digest(utf8.encode(config['token'] as String)),
          });
    // Caller persists before network use so a lost response can be retried.
    config['pending_join'] = {'invitation': invitation, 'request': e};
    await call(
      'POST',
      '/enroll/${invitation['id']}',
      value: e,
      authorization: 'Invitation ${invitation['secret']}',
    );
  }

  Future<bool> finishJoin() async {
    final pending = config['pending_join'] as Map,
        inv = pending['invitation'] as Map,
        req = unpack(pending['request'] as Map<String, dynamic>);
    if (inv['mode'] == 'auto')
      return _finishAuto(Map<String, dynamic>.from(pending));
    final result = await call(
      'GET',
      '/enroll/${inv['id']}',
      authorization: 'Claim ${config['token']}',
    );
    final e = result['entry'] as Map<String, dynamic>?;
    if (e == null) return false;
    if (e['authorization'] != null)
      throw StateError('Unexpected delegated approval');
    verify(e, inv['manager']['signing_key'] as String);
    final g = unpack(e);
    _validate(g);
    final own = (g['members'] as List)
        .where((m) => m['device'] == config['device'])
        .firstOrNull;
    final expected = Map<String, dynamic>.from(req['member'] as Map)
      ..['manager'] = own?['manager'] ?? false;
    if (e['signer'] != inv['manager']['device'] ||
        g['invitation'] != inv['id'] ||
        g['request_hash'] !=
            digest(payload(pending['request'] as Map<String, dynamic>)) ||
        own == null ||
        !_same(own as Map, expected))
      throw StateError('Approval mismatch');
    accept(e);
    config.remove('pending_join');
    return true;
  }

  RelayGroups _delegateSigner(String secret, String device) => RelayGroups(
    sodium,
    {...config, 'secret_key': secret, 'device': device},
    allowLocalTest: allowLocalTest,
  );
  static bool _sameEntry(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    return a['payload'] == b['payload'] &&
        a['signature'] == b['signature'] &&
        a['signer'] == b['signer'] &&
        _sameEntry(
          a['authorization'] as Map<String, dynamic>?,
          b['authorization'] as Map<String, dynamic>?,
        );
  }

  Map<String, dynamic> _validateGrant(
    Map<String, dynamic> entry,
    Map<String, dynamic> owner,
    Map<String, dynamic> state,
  ) {
    if (entry['authorization'] != null ||
        owner['manager'] != true ||
        entry['signer'] != owner['device'])
      throw StateError('Invalid admission grant');
    verify(entry, owner['signing_key'] as String);
    final g = unpack(entry);
    if (g['version'] != 1 ||
        g['purpose'] != 'common-relay/admission/v1' ||
        g['mode'] != 'auto' ||
        g['app'] != state['app'] ||
        g['group'] != state['group'] ||
        (g['anchor_revision'] as int) < 1 ||
        (g['anchor_revision'] as int) > (state['revision'] as int) ||
        (g['expires'] as int) <= 0)
      throw StateError('Admission grant scope');
    for (final field in [
      'invitation',
      'secret_hash',
      'delegate_key',
      'anchor_hash',
    ]) {
      if (!RegExp(
        field == 'invitation' ? r'^[0-9a-f]{32}$' : r'^[0-9a-f]{64}$',
      ).hasMatch(g[field] as String))
        throw StateError('Admission grant encoding');
    }
    return g;
  }

  void _advanceAuto(
    Map<String, dynamic> current,
    Map<String, dynamic> entry,
    Map<String, dynamic> old,
    Map<String, dynamic> next,
    Map<String, dynamic> actor,
  ) {
    final grant = _validateGrant(
      entry['authorization'] as Map<String, dynamic>,
      actor,
      old,
    );
    verify(entry, grant['delegate_key'] as String);
    final before = {
          for (final m in old['members'] as List) m['device']: m as Map,
        },
        after = {
          for (final m in next['members'] as List) m['device']: m as Map,
        };
    final added = after.keys.toSet().difference(before.keys.toSet());
    if (next['closed'] == true ||
        next['invitation'] != grant['invitation'] ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(next['request_hash'] as String) ||
        after.length != before.length + 1 ||
        added.length != 1 ||
        after[added.single]!['manager'] != false ||
        before.keys.any(
          (k) => after[k] == null || !_same(before[k]!, after[k]!),
        ))
      throw StateError('Invalid automatic admission');
    if (old['revision'] == grant['anchor_revision'] &&
        digest(payload(current)) != grant['anchor_hash'])
      throw StateError('Admission anchor mismatch');
  }

  Map<String, dynamic> _invitationGrant(Map<String, dynamic> inv) {
    final g = unpack(inv['grant'] as Map<String, dynamic>);
    _validateGrant(
      inv['grant'] as Map<String, dynamic>,
      inv['manager'] as Map<String, dynamic>,
      {
        'app': config['app'],
        'group': config['group'],
        'revision': g['anchor_revision'],
      },
    );
    if (g['invitation'] != inv['id'] ||
        g['expires'] != inv['expires'] ||
        g['secret_hash'] != digest(utf8.encode(inv['secret'] as String)) ||
        g['delegate_key'] !=
            _delegateSigner(
              inv['delegate_secret'] as String,
              inv['manager']['device'] as String,
            ).member('')['signing_key'])
      throw StateError('Invitation grant mismatch');
    return g;
  }

  Future<bool> _finishAuto(Map<String, dynamic> pending) async {
    final inv = pending['invitation'] as Map<String, dynamic>,
        request = pending['request'] as Map<String, dynamic>;
    final grant = _invitationGrant(inv), req = unpack(request);
    Map<String, dynamic>? current;
    var after = (grant['anchor_revision'] as int) - 1;
    late Map<String, dynamic> result;
    final path = "/enroll/${inv['id']}/auto", auth = "Claim ${config['token']}";
    while (true) {
      result = await call('GET', '$path?after=$after', authorization: auth);
      if ((result['revision'] as int) < (grant['anchor_revision'] as int) ||
          (result['revision'] as int) > 4096)
        throw StateError('Admission revision');
      final entries = result['entries'] as List;
      if (entries.isEmpty) throw StateError('Incomplete admission chain');
      for (final value in entries) {
        final e = value as Map<String, dynamic>;
        if (current == null) {
          if (digest(payload(e)) != grant['anchor_hash'] ||
              unpack(e)['revision'] != grant['anchor_revision'])
            throw StateError('Admission anchor mismatch');
          _validate(unpack(e));
          current = e;
        } else {
          current = advance(current, e);
        }
      }
      final revision = unpack(current!)['revision'] as int;
      if (revision <= after || revision > (result['revision'] as int))
        throw StateError('Admission revision');
      after = revision;
      if (after == result['revision']) break;
    }
    Map<String, dynamic> e;
    if (result['entry'] != null) {
      if (!_sameEntry(current, result['entry'] as Map<String, dynamic>))
        throw StateError('Admission tip mismatch');
      e = current;
    } else {
      final g = unpack(current);
      (g['members'] as List).add(req['member']);
      g['revision'] = (g['revision'] as int) + 1;
      g['previous'] = digest(payload(current));
      g['invitation'] = inv['id'];
      g['request_hash'] = digest(payload(request));
      e = _delegateSigner(
        inv['delegate_secret'] as String,
        inv['manager']['device'] as String,
      ).sign(g);
      e['authorization'] = inv['grant'];
      advance(current, e);
      pending['auto_entry'] = e;
      config['pending_join'] = pending;
      if (!_sameEntry(
        e,
        await call('POST', path, value: e, authorization: auth),
      ))
        throw StateError('Admission response mismatch');
    }
    final g = unpack(e),
        own = (unpack(e)['members'] as List)
            .where((m) => m['device'] == config['device'])
            .firstOrNull;
    if (!_sameEntry(
          e['authorization'] as Map<String, dynamic>?,
          inv['grant'] as Map<String, dynamic>,
        ) ||
        g['invitation'] != inv['id'] ||
        g['request_hash'] != digest(payload(request)) ||
        own == null ||
        !_same(own as Map, req['member'] as Map))
      throw StateError('Automatic approval mismatch');
    accept(e);
    config.remove('pending_join');
    return true;
  }

  Future<void> approve(
    Map<String, dynamic> invitation,
    Map<String, dynamic> request, {
    bool manager = false,
  }) async {
    await refresh();
    final j = unpack(request);
    verify(request, j['member']['signing_key'] as String);
    if (j['invitation'] != invitation['id'] ||
        j['app'] != config['app'] ||
        j['group'] != config['group'])
      throw StateError('Join scope mismatch');
    final g = unpack(config['group_entry'] as Map<String, dynamic>),
        m = Map<String, dynamic>.from(j['member'] as Map)
          ..['manager'] = manager;
    (g['members'] as List).removeWhere((v) => v['device'] == m['device']);
    (g['members'] as List).add(m);
    g['invitation'] = invitation['id'];
    g['request_hash'] = digest(payload(request));
    await _change(g);
  }

  Future<void> remove(String device) async {
    if (device == config['device']) throw StateError('Use exit for yourself');
    await refresh();
    final g = unpack(config['group_entry'] as Map<String, dynamic>);
    (g['members'] as List).removeWhere((m) => m['device'] == device);
    g['invitation'] = '';
    g['request_hash'] = '';
    await _change(g);
  }

  Future<void> rename(String device, String name) async {
    name = name.trim();
    if (utf8.encode(name).isEmpty || utf8.encode(name).length > 128)
      throw StateError('Name required');
    await refresh();
    final g = unpack(config['group_entry'] as Map<String, dynamic>);
    final member = (g['members'] as List).firstWhere(
      (m) => m['device'] == device,
    );
    if (member['name'] == name) return;
    member['name'] = name;
    g['invitation'] = '';
    g['request_hash'] = '';
    await _change(g);
  }

  Future<void> prepareExit({bool disband = false}) async {
    if (config['pending_exit'] != null) return;
    await refresh();
    final old = config['group_entry'] as Map<String, dynamic>;
    final g = unpack(old), members = unpack(old)['members'] as List;
    final own = members.firstWhere((m) => m['device'] == config['device']);
    if (disband && own['manager'] != true)
      throw StateError('Manager permission required');
    final after = disband
        ? <dynamic>[]
        : members.where((m) => m['device'] != config['device']).toList();
    g['members'] = after;
    if (after.isEmpty) g['closed'] = true;
    g['invitation'] = '';
    g['request_hash'] = '';
    g['revision'] = (g['revision'] as int) + 1;
    g['previous'] = digest(payload(old));
    final e = sign(g);
    advance(old, e);
    config['pending_exit'] = e;
  }

  Future<void> exit() async {
    final e = config['pending_exit'] as Map<String, dynamic>;
    try {
      await call('POST', '/group/exit', value: e);
    } catch (error) {
      if (error.toString().contains('409')) config.remove('pending_exit');
      rethrow;
    }
    accept(e);
    config.remove('pending_exit');
  }

  Future<void> cancel(Map<String, dynamic> invitation) async {
    await call('DELETE', '/group/invitations/${invitation['id']}');
  }

  Future<void> _change(Map<String, dynamic> g) async {
    final old = config['group_entry'] as Map<String, dynamic>;
    g['revision'] = (g['revision'] as int) + 1;
    g['previous'] = digest(payload(old));
    final e = sign(g);
    advance(old, e);
    await call('PUT', '/group', value: e);
    accept(e);
  }
}
