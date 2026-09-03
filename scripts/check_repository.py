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
FORBIDDEN_NAMES = {'.DS_Store', 'key.properties', 'local.properties', '.flutter'}
FORBIDDEN_SUFFIXES = {'.jks', '.keystore', '.p12', '.pfx', '.apk', '.aab', '.dmg', '.log'}
SECRET_PATTERNS = (
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{36,}'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{40,}'),
    re.compile(rb'AKIA[0-9A-Z]{16}'),
)


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
        if (set(path.relative_to(ROOT).parts) & FORBIDDEN_PARTS
                or path.name in FORBIDDEN_NAMES
                or path.suffix in FORBIDDEN_SUFFIXES
                or (path.name.startswith('.env') and path.name != '.env.example')
                or relative.startswith('.config/flutter/')):
            findings.append((relative, 'local/generated artifact'))
            continue
        if path.stat().st_size > 2 * 1024 * 1024:
            continue
        data = path.read_bytes()
        if b'\0' not in data and any(pattern.search(data) for pattern in SECRET_PATTERNS):
            findings.append((relative, 'possible credential'))
    for path, category in findings:
        print(f'{path}: {category}', file=sys.stderr)
    if findings:
        return 1
    print('Repository hygiene checks passed (working tree only).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
