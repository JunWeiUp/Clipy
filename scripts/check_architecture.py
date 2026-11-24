#!/usr/bin/env python3
"""Automated architecture guardrails for AI-friendly repository structure.

Checks:
1. Flutter lib/ root allowlist (new feature/sync/db/ui files must live in subdirectories).
2. File-size ceiling (1,200 lines for new files; explicit non-growing ceiling for legacy files).
3. Local docs hygiene (when docs/ exists): catch corrupted ../history or ../releases prose.
4. Local AGENTS.md size cap (<= 12 KB) so root instructions never get truncated in agent context.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Existing top-level Dart files kept at lib/ for import stability.
# Do NOT add new files here; place new code under lib/features/, lib/sync/, lib/database/, lib/ui/, lib/app/, or lib/utils/.
FLUTTER_LIB_ROOT_ALLOWLIST = {
    'app_localizations.dart',
    'clipboard_manager.dart',
    'compression_utils.dart',
    'log_manager.dart',
    'main.dart',
    'main_windows.dart',
    'models.dart',
    'notification_health_banner.dart',
    'notification_health_monitor.dart',
    'notification_manager.dart',
    'notification_sync_page.dart',
    'storage_paths.dart',
    'sync_manager.dart',
}

DEFAULT_MAX_LINES = 1200

# Legacy oversized files: allowed only up to their recorded ceiling (+20 line buffer for bugfixes).
# Goal is strictly downward over time; never add new entries here.
LEGACY_MAX_LINES = {
    'clipy_macos/Sources/Screenshot/UI/Overlay/OverlayView.swift': 5460,
    'clipy_macos/Sources/Screenshot/UI/Editor/VideoEditorWindowController.swift': 4000,
    'clipy_macos/Sources/Screenshot/Model/Annotation.swift': 2610,
    'clipy_macos/Sources/Screenshot/UI/Toolbar/ToolOptionsRowView.swift': 2380,
    'clipy_macos/Sources/Screenshot/UI/Editor/EffectsBandView.swift': 1950,
    'clipy_macos/Sources/Screenshot/UI/Overlay/OverlayView+ActionsAndRecording.swift': 1830,
    'clipy_macos/Sources/App/Localization.swift': 1700,
    'clipy_macos/Sources/Screenshot/UI/Windows/FloatingThumbnailController.swift': 1500,
    'clipy_macos/Sources/UI/SearchView.swift': 1490,
    'clipy_macos/Sources/Screenshot/UI/Overlay/OverlayView+ImageTransforms.swift': 1320,
    'clipy_macos/Sources/Clipboard/ClipboardManager.swift': 1310,
    'clipy_flutter/lib/features/history/home_page.dart': 1280,
    'clipy_flutter/lib/ui/clipboard_history_list.dart': 1260,
    'clipy_flutter/lib/features/devices/relay_group_page.dart': 1240,
}

CORRUPTED_PROSE_RE = re.compile(r'(?<![(/])\.\./(?:history|releases)(?!/|\.[a-z])')
AGENTS_MAX_BYTES = 12 * 1024


def check_flutter_lib_root() -> list[str]:
    errors: list[str] = []
    lib_dir = ROOT / 'clipy_flutter/lib'
    for entry in sorted(lib_dir.iterdir()):
        if entry.is_file() and entry.suffix == '.dart':
            if entry.name not in FLUTTER_LIB_ROOT_ALLOWLIST:
                errors.append(
                    f'clipy_flutter/lib/{entry.name}: new top-level Dart file is forbidden; '
                    'place under lib/features/, lib/sync/, lib/database/, lib/ui/, lib/app/, or lib/utils/.'
                )
    return errors


def check_file_sizes() -> list[str]:
    errors: list[str] = []
    scan_targets = [
        (ROOT / 'clipy_macos/Sources', '.swift'),
        (ROOT / 'clipy_flutter/lib', '.dart'),
    ]
    for base, suffix in scan_targets:
        for path in sorted(base.rglob(f'*{suffix}')):
            rel = path.relative_to(ROOT).as_posix()
            line_count = len(path.read_text(encoding='utf-8').splitlines())
            limit = LEGACY_MAX_LINES.get(rel, DEFAULT_MAX_LINES)
            if line_count > limit:
                errors.append(
                    f'{rel}: {line_count} lines exceeds limit ({limit}); split into smaller cohesive modules.'
                )
    return errors


def check_local_docs() -> list[str]:
    errors: list[str] = []
    for folder in ('docs/architecture', 'docs/development'):
        dir_path = ROOT / folder
        if not dir_path.is_dir():
            continue
        for md in sorted(dir_path.glob('*.md')):
            rel = md.relative_to(ROOT).as_posix()
            for lineno, line in enumerate(md.read_text(encoding='utf-8').splitlines(), 1):
                if CORRUPTED_PROSE_RE.search(line):
                    errors.append(f'{rel}:{lineno}: corrupted relative prose path (`../history` or `../releases`)')
    return errors


def check_agents_size() -> list[str]:
    agents = ROOT / 'AGENTS.md'
    if not agents.is_file():
        return []
    size = agents.stat().st_size
    if size > AGENTS_MAX_BYTES:
        return [
            f'AGENTS.md: {size} bytes exceeds {AGENTS_MAX_BYTES} byte cap; '
            'keep L0 root instructions concise and archive long details under docs/.'
        ]
    return []


def main() -> int:
    errors: list[str] = []
    errors.extend(check_flutter_lib_root())
    errors.extend(check_file_sizes())
    errors.extend(check_local_docs())
    errors.extend(check_agents_size())
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print('Architecture guardrails passed (lib/ root, file-size ceilings, docs hygiene, AGENTS.md budget).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
