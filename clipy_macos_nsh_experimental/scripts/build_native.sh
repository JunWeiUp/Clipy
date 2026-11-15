#!/usr/bin/env bash
set -euo pipefail
command -v proxy >/dev/null 2>&1 && proxy || true
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_ROOT="${COMMON_RELAY_PATH:-}"
if [[ -z "$RELAY_ROOT" ]]; then
  for candidate in "$TASK_ROOT/../../common-relay/sdk/swift" "$TASK_ROOT/../../../code/common-relay/sdk/swift"; do
    if [[ -d "$candidate" ]]; then RELAY_ROOT="$candidate"; break; fi
  done
fi
[[ -n "$RELAY_ROOT" && -f "$RELAY_ROOT/Package.swift" ]] || { echo 'Set COMMON_RELAY_PATH to the common-relay/sdk/swift checkout.' >&2; exit 1; }
RELAY_ROOT="$(cd "$RELAY_ROOT" && pwd)"
CACHE_ROOT="${CLIPY_NSH_CACHE:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/clipy-nsh}"
mkdir -p "$CACHE_ROOT"
export COMMON_RELAY_PATH="$RELAY_ROOT"
swift build --package-path "$TASK_ROOT/host/macos" --scratch-path "$CACHE_ROOT/swift" -c release --product clipy-native >&2
printf '%s\n' "$CACHE_ROOT/swift/release/clipy-native"
