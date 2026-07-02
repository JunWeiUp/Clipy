#!/bin/bash
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/clipy_macos/build_macos_app.sh" "$@"
