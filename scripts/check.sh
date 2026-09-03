#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

check_repo() {
  git diff --check
  bash -n build_macos_app.sh build_android_apk.sh scripts/check.sh scripts/lib/build_common.sh scripts/test_build_config.sh
  bash scripts/test_build_config.sh
  python3 scripts/check_repository.py
  python3 -B scripts/test_repository_privacy.py
  python3 scripts/check_icons.py
}

check_flutter() {
  (
    cd clipy_android
    # Resolve dependencies first with flutter pub get --enforce-lockfile.
    dart format --output=none --set-exit-if-changed lib test tool
    flutter analyze --no-pub
    flutter test --no-pub
  )
}

case "${1:-all}" in
  repo) check_repo ;;
  flutter) check_flutter ;;
  macos) INSTALL_APP=0 LAUNCH_APP=0 bash build_macos_app.sh ;;
  all) check_repo; check_flutter ;;
  *) printf 'Usage: bash scripts/check.sh [all|repo|flutter|macos]\n' >&2; exit 64 ;;
esac
