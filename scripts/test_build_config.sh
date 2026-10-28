#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/build_common.sh
source "${REPO_ROOT}/scripts/lib/build_common.sh"

unset APP_VERSION BUILD_NUMBER
resolve_build_version
[ "${APP_VERSION}+${BUILD_NUMBER}" = "$(awk '/^version:/ {print $2; exit}' "${REPO_ROOT}/clipy_android/pubspec.yaml")" ]

expect_invalid() {
  if (APP_VERSION="$1" BUILD_NUMBER="$2"; resolve_build_version) >/dev/null 2>&1; then
    fail "Accepted invalid build metadata"
  fi
}
expect_invalid '1.0;touch-unwanted' 1
expect_invalid '../1.0.0' 1
expect_invalid 1.0.0 0
expect_invalid 1.0.0 -1
expect_invalid 1.0.0 99999999999999999999
if (validate_boolean INSTALL_APP yes) >/dev/null 2>&1; then
  fail "Accepted invalid boolean"
fi
if APP_VERSION=1.0.0 BUILD_NUMBER=1 LAUNCH_APP=1 INSTALL_APP=0 \
  bash "${REPO_ROOT}/build_macos_app.sh" >/dev/null 2>&1; then
  fail "Allowed launching without explicit installation"
fi
# Native default carries the historical ARM64 offset exactly once.
unset BUILD_NUMBER APP_VERSION
resolve_build_version
source_build="${BUILD_NUMBER}"
unset BUILD_NUMBER
resolve_android_build_version
[ "${BUILD_NUMBER}" -eq "$((source_build + 2000))" ]
BUILD_NUMBER=14285
resolve_android_build_version
[ "${BUILD_NUMBER}" = 14285 ]
if (unset BUILD_NUMBER; REPO_ROOT="/nonexistent"; resolve_android_build_version) >/dev/null 2>&1; then
  fail "Accepted missing version source"
fi
printf 'Build configuration tests passed.\n'
