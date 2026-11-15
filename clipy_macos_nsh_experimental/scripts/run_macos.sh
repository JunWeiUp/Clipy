#!/usr/bin/env bash
set -euo pipefail
command -v proxy >/dev/null 2>&1 && proxy || true
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$TASK_ROOT/scripts/runtime_env.sh"
HELPER="$("$TASK_ROOT/scripts/build_native.sh")"
export PATH="$(dirname "$HELPER"):$PATH"
export CLIPY_NSH_HELPER=clipy-native
exec "$CLIPY_NSH_BIN" run "$TASK_ROOT" --target macos --name "Clipy TSX Preview" "$@"
