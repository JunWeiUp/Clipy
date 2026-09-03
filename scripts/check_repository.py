#!/usr/bin/env python3
"""Small offline guard against committing local artifacts or obvious secrets.

This scans the working tree, not Git history, and is not a full security audit.
Only paths and finding categories are printed; never print a matched secret.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_PARTS = {'.dart-tool', '.dart_tool', '.gradle', '.fvm', '.video_agent', 'node_modules'}
FORBIDDEN_NAMES = {
    '.DS_Store', 'key.properties', 'local.properties', '.flutter',
    'snippets.json', 'history.json', 'notifications.json',
}
FORBIDDEN_SUFFIXES = {
    '.jks', '.keystore', '.p12', '.pfx', '.apk', '.aab', '.dmg', '.log',
    '.db', '.db-shm', '.db-wal', '.sqlite', '.sqlite3',
    '.sqlite-shm', '.sqlite-wal', '.sqlite3-shm', '.sqlite3-wal',
}
# This retired screenshot includes real clipboard history, not synthetic demo data.
PRIVATE_SCREENSHOTS = {'res/search.png'}
SECRET_PATTERNS = (
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{36,}'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{40,}'),
    re.compile(rb'AKIA[0-9A-Z]{16}'),
)
EMAIL_PATTERN = re.compile(rb'[A-Za-z0-9_.+%-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})')
EXAMPLE_EMAIL_DOMAINS = {b'example.com', b'example.org', b'example.net'}
SNIPPET_SOURCE_PREFIXES = (
    'clipy_macos/Sources/Snippets/',
    'clipy_macos/Sources/UI/Snippets/',
)


def check_path(relative):
    path = Path(relative)
    if relative in PRIVATE_SCREENSHOTS:
        return 'private screenshot (use sanitized demo data)'
    if (set(path.parts) & FORBIDDEN_PARTS
            or path.name in FORBIDDEN_NAMES
            or path.suffix in FORBIDDEN_SUFFIXES
            or (path.name.startswith('.env') and path.name != '.env.example')
            or relative.startswith('.config/flutter/')):
        return 'local/generated artifact or personal data'
    return None


def check_text(relative, data):
    if b'\0' in data:
        return None
    if any(pattern.search(data) for pattern in SECRET_PATTERNS):
        return 'possible credential'
    if relative.startswith(SNIPPET_SOURCE_PREFIXES):
        for match in EMAIL_PATTERN.finditer(data):
            domain = match.group(1).lower()
            if domain not in EXAMPLE_EMAIL_DOMAINS and not domain.endswith(b'.example'):
                return 'snippet email must use a reserved example domain'
    return None


def main():
    paths = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT
    ).decode().split('\0')
    findings = []
    for relative in sorted(set(filter(None, paths))):
        path = ROOT / relative
        if not path.is_file():  # Deletions awaiting commit are intentional.
            continue
        if path.is_symlink():
            continue
        category = check_path(relative)
        if category:
            findings.append((relative, category))
            continue
        if path.stat().st_size > 2 * 1024 * 1024:
            continue
        data = path.read_bytes()
        category = check_text(relative, data)
        if category:
            findings.append((relative, category))
    for path, category in findings:
        print(f'{path}: {category}', file=sys.stderr)
    if findings:
        return 1
    print('Repository hygiene checks passed (working tree only).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
