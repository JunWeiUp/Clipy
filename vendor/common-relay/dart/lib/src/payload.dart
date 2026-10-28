part of '../common_relay.dart';

// Strict signed-payload scan shared byte for byte with the relay and other
// SDKs. JSON parsers disagree on duplicate keys, key case, unknown fields,
// null, number forms and lone surrogates; a signed group record must have
// exactly one reading everywhere (protocol/README.md, "严格载荷").
const _member = {'device': ('s', true), 'name': ('s', true), 'public_key': ('s', true), 'signing_key': ('s', true), 'manager': ('b', true)};
const _state = {'closed': ('b', false), 'name': ('s', false), 'version': ('i', true), 'app': ('s', true), 'group': ('s', true), 'revision': ('i', true), 'previous': ('s', true), 'members': ('M', true), 'invitation': ('s', true), 'request_hash': ('s', true)};
const _request = {'version': ('i', true), 'app': ('s', true), 'group': ('s', true), 'invitation': ('s', true), 'member': ('m', true), 'token_hash': ('s', true)};
const _grant = {'version': ('i', true), 'purpose': ('s', true), 'mode': ('s', true), 'app': ('s', true), 'group': ('s', true), 'invitation': ('s', true), 'expires': ('i', true), 'secret_hash': ('s', true), 'delegate_key': ('s', true), 'anchor_revision': ('i', true), 'anchor_hash': ('s', true)};
const _schemas = [_state, _request, _grant];

class _Scanner {
  final List<int> b;
  int i = 0;
  _Scanner(this.b);
  int ws() {
    while (i < b.length && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d)) { i++; }
    return i;
  }
  bool eat(int c) {
    ws();
    if (i < b.length && b[i] == c) { i++; return true; }
    return false;
  }
  // Keys are compared as raw bytes, so an escaped key never matches the schema.
  bool object(Map<String, (String, bool)> schema) {
    if (!eat(0x7b)) return false;
    final seen = <String>{};
    if (!eat(0x7d)) {
      while (true) {
        final start = ws();
        if (!string()) return false;
        final k = utf8.decode(b.sublist(start + 1, i - 1));
        final f = schema[k];
        if (f == null || seen.contains(k) || !eat(0x3a) || !value(f.$1)) return false;
        seen.add(k);
        if (eat(0x7d)) break;
        if (!eat(0x2c)) return false;
      }
    }
    return schema.entries.every((e) => !e.value.$2 || seen.contains(e.key));
  }
  bool value(String kind) {
    ws();
    switch (kind) {
      case 's': return string();
      case 'b': return word('true') || word('false');
      case 'i': return integer();
      case 'm': return object(_member);
    }
    if (!eat(0x5b)) return false;
    if (eat(0x5d)) return true;
    while (true) {
      if (!object(_member)) return false;
      if (eat(0x5d)) return true;
      if (!eat(0x2c)) return false;
    }
  }
  bool word(String w) {
    if (i + w.length > b.length) return false;
    for (var j = 0; j < w.length; j++) { if (b[i + j] != w.codeUnitAt(j)) return false; }
    i += w.length;
    return true;
  }
  // Only 0 or [1-9][0-9]* up to 2^53-1; a fraction or exponent fails at the caller.
  bool integer() {
    final start = i;
    while (i < b.length && b[i] >= 0x30 && b[i] <= 0x39) { i++; }
    final s = String.fromCharCodes(b.sublist(start, i));
    final n = BigInt.tryParse(s);
    return n != null && (s == '0' || s[0] != '0') && n <= BigInt.from(9007199254740991);
  }
  bool string() {
    if (i >= b.length || b[i] != 0x22) return false;
    for (i++; i < b.length; i++) {
      final c = b[i];
      if (c == 0x22) { i++; return true; }
      if (c < 0x20) return false;
      if (c == 0x5c) {
        i++;
        if (i >= b.length) return false;
        final e = b[i];
        if (e == 0x75) {
          if (i + 4 >= b.length) return false;
          final h = String.fromCharCodes(b.sublist(i + 1, i + 5));
          if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(h)) return false;
          final n = int.parse(h, radix: 16);
          if (n >= 0xd800 && n <= 0xdfff) return false;
          i += 4;
        } else if (!'"\\/bfnrt'.codeUnits.contains(e)) {
          return false;
        }
      }
    }
    return false;
  }
}

bool _strict(List<int> raw, Map<String, (String, bool)> schema) {
  try { utf8.decode(raw); } on FormatException { return false; }
  final p = _Scanner(raw);
  return p.object(schema) && p.ws() == raw.length;
}
