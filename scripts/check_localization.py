#!/usr/bin/env python3
"""Verify localization key symmetry and format placeholder parity across macOS and Flutter."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT_L10N = ROOT / 'clipy_macos/Sources/App/Localization.swift'
DART_L10N = ROOT / 'clipy_flutter/lib/app_localizations.dart'

SWIFT_CASE_RE = re.compile(r'^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\b')
SWIFT_ENTRY_RE = re.compile(r'^\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"((?:[^"\\]|\\.)*)"\s*,?\s*(?://.*)?$')
SWIFT_FMT_RE = re.compile(r'%(?:\d+\$)?(?:ll|l)?[@dDuUxXoOfeEgGcCsSp]|%\.\d+f')

DART_MEMBER_RE = re.compile(r'^\s*String\s+(?:get\s+)?([A-Za-z_][A-Za-z0-9_]*)\b')


def parse_swift_l10n(path: Path) -> tuple[list[str], int]:
    errors: list[str] = []
    text = path.read_text(encoding='utf-8')
    lines = text.splitlines()

    enum_keys: list[str] = []
    in_enum = False
    section: str | None = None
    tables: dict[str, dict[str, str]] = {'zh': {}, 'en': {}}

    for lineno, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('enum L10nKey'):
            in_enum = True
            continue
        if in_enum:
            if stripped == '}':
                in_enum = False
                continue
            m = SWIFT_CASE_RE.match(line)
            if m:
                key = m.group(1)
                if key in enum_keys:
                    errors.append(f'{path.relative_to(ROOT)}:{lineno}: duplicate L10nKey case `{key}`')
                enum_keys.append(key)
            continue

        if stripped.startswith('.zh: ['):
            section = 'zh'
            continue
        if stripped.startswith('.en: ['):
            section = 'en'
            continue
        if section is not None:
            if stripped in ('],', ']'):
                section = None
                continue
            m = SWIFT_ENTRY_RE.match(line)
            if m:
                key, value = m.group(1), m.group(2)
                if key in tables[section]:
                    errors.append(f'{path.relative_to(ROOT)}:{lineno}: duplicate .{section} entry `.{key}`')
                if value == '':
                    errors.append(f'{path.relative_to(ROOT)}:{lineno}: empty .{section} value for `.{key}`')
                tables[section][key] = value

    enum_set = set(enum_keys)
    zh_set = set(tables['zh'])
    en_set = set(tables['en'])

    for lang, lang_set in (('zh', zh_set), ('en', en_set)):
        missing = sorted(enum_set - lang_set)
        if missing:
            errors.append(f'{path.relative_to(ROOT)}: .{lang} missing {len(missing)} key(s): {", ".join(missing[:10])}')
        extra = sorted(lang_set - enum_set)
        if extra:
            errors.append(f'{path.relative_to(ROOT)}: .{lang} has {len(extra)} unknown key(s): {", ".join(extra[:10])}')

    for key in sorted(zh_set & en_set):
        zh_fmt = sorted(SWIFT_FMT_RE.findall(tables['zh'][key]))
        en_fmt = sorted(SWIFT_FMT_RE.findall(tables['en'][key]))
        if zh_fmt != en_fmt:
            errors.append(
                f'{path.relative_to(ROOT)}: format specifier mismatch for `.{key}`: zh={zh_fmt} vs en={en_fmt}'
            )

    if not enum_keys:
        errors.append(f'{path.relative_to(ROOT)}: failed to parse L10nKey enum')
    return errors, len(enum_keys)


def _extract_dart_string_literal(text: str, pos: int) -> tuple[str | None, int]:
    """Parse a single or adjacent Dart string literal starting at pos (ignoring whitespace)."""
    n = len(text)
    parts: list[str] = []
    while pos < n:
        while pos < n and text[pos] in ' \t\r\n':
            pos += 1
        if pos >= n or text[pos] not in ("'", '"'):
            break
        quote = text[pos]
        pos += 1
        buf: list[str] = []
        while pos < n:
            ch = text[pos]
            if ch == '\\' and pos + 1 < n:
                buf.append(ch)
                buf.append(text[pos + 1])
                pos += 2
                continue
            if ch == quote:
                pos += 1
                break
            buf.append(ch)
            pos += 1
        parts.append(''.join(buf))
    if not parts:
        return None, pos
    return ''.join(parts), pos


def parse_dart_l10n(path: Path) -> tuple[list[str], int]:
    errors: list[str] = []
    text = path.read_text(encoding='utf-8')

    in_class = False
    seen_members: set[str] = set()
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('class AppStrings'):
            in_class = True
            continue
        if in_class:
            m = DART_MEMBER_RE.match(line)
            if m:
                name = m.group(1)
                if name != '_t':
                    if name in seen_members:
                        errors.append(f'{path.relative_to(ROOT)}:{lineno}: duplicate AppStrings member `{name}`')
                    seen_members.add(name)

    # Validate every _t(zh, en) call
    call_count = 0
    for match in re.finditer(r'\b_t\(', text):
        # Skip definition `String _t(String zh, String en)`
        line_start = text.rfind('\n', 0, match.start()) + 1
        if 'String _t(' in text[line_start:match.end() + 20]:
            continue
        pos = match.end()
        zh, pos = _extract_dart_string_literal(text, pos)
        while pos < len(text) and text[pos] in ' \t\r\n':
            pos += 1
        if zh is None or pos >= len(text) or text[pos] != ',':
            continue
        pos += 1
        en, pos = _extract_dart_string_literal(text, pos)
        if en is None:
            continue
        call_count += 1
        lineno = text.count('\n', 0, match.start()) + 1
        if not zh.strip():
            errors.append(f'{path.relative_to(ROOT)}:{lineno}: empty zh string in _t(...)')
        if not en.strip():
            errors.append(f'{path.relative_to(ROOT)}:{lineno}: empty en string in _t(...)')

    if call_count == 0:
        errors.append(f'{path.relative_to(ROOT)}: failed to parse _t(...) calls in AppStrings')
    return errors, call_count


def main() -> int:
    swift_errors, swift_count = parse_swift_l10n(SWIFT_L10N)
    dart_errors, dart_count = parse_dart_l10n(DART_L10N)
    errors = swift_errors + dart_errors
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print(f'Localization symmetry checks passed (macOS: {swift_count} keys, Flutter: {dart_count} entries).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
