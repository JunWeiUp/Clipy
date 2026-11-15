#!/usr/bin/env bash
# Source from run/package; no Rust toolchain is needed for this client.
CLIPY_NSH_BIN="${CLIPY_NSH_BIN:-nsh}"
clipy_runtime_version="$("$CLIPY_NSH_BIN" --version)"
case "$clipy_runtime_version" in
  "nsh 0.5.0 "*|"nsh 0.5.0") ;;
  *) echo "Expected NSH 0.5.0; found $clipy_runtime_version. Set CLIPY_NSH_BIN to the pinned executable." >&2; exit 1 ;;
esac
