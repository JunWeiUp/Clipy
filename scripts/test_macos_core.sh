#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipy-core-tests.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
cp -R "${REPO_ROOT}/clipy_macos/Sources" "${TEST_DIR}/Sources"
cp "${REPO_ROOT}/clipy_macos/Tests/CoreRegression.swift" "${TEST_DIR}/CoreRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/WordLookupRegression.swift" "${TEST_DIR}/WordLookupRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/SmartSwitchRegression.swift" "${TEST_DIR}/SmartSwitchRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/SmartSwitchVoiceRegression.swift" "${TEST_DIR}/SmartSwitchVoiceRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/SmartSwitchActionRegression.swift" "${TEST_DIR}/SmartSwitchActionRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/FolderTransferRegression.swift" "${TEST_DIR}/FolderTransferRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/SyncTransportRegression.swift" "${TEST_DIR}/SyncTransportRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/MenuBarOverflowRegression.swift" "${TEST_DIR}/MenuBarOverflowRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/MenuBarPanelRegression.swift" "${TEST_DIR}/MenuBarPanelRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/TokenUsageRegression.swift" "${TEST_DIR}/TokenUsageRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/NativeScreenshotScrollRegression.swift" "${TEST_DIR}/NativeScreenshotScrollRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/NativeScreenshotProcessingRegression.swift" "${TEST_DIR}/NativeScreenshotProcessingRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/NativeScreenshotWebPRegression.swift" "${TEST_DIR}/NativeScreenshotWebPRegression.swift"
BUILD_DIR="${TEST_DIR}"
MACOS_ARCH="$(uname -m)"
# shellcheck source=scripts/lib/build_webp.sh
source "${REPO_ROOT}/scripts/lib/build_webp.sh"
build_webp_static
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("${source}"); done < <(find "${TEST_DIR}/Sources" -name '*.swift' -print0)
swiftc "${SOURCES[@]}" "${TEST_DIR}/CoreRegression.swift" "${TEST_DIR}/WordLookupRegression.swift" "${TEST_DIR}/SmartSwitchRegression.swift" "${TEST_DIR}/SmartSwitchVoiceRegression.swift" "${TEST_DIR}/SmartSwitchActionRegression.swift" "${TEST_DIR}/FolderTransferRegression.swift" "${TEST_DIR}/SyncTransportRegression.swift" "${TEST_DIR}/MenuBarOverflowRegression.swift" "${TEST_DIR}/MenuBarPanelRegression.swift" "${TEST_DIR}/TokenUsageRegression.swift" "${TEST_DIR}/NativeScreenshotScrollRegression.swift" "${TEST_DIR}/NativeScreenshotProcessingRegression.swift" "${TEST_DIR}/NativeScreenshotWebPRegression.swift" \
  -swift-version 5 -target "$(uname -m)-apple-macos13.0" -D OFFLINE -D CLIPY_CORE_TESTS \
  "${WEBP_STATIC_LIBRARY}" "${SHARPYUV_STATIC_LIBRARY}" -Xlinker -weak_framework -Xlinker Translation \
  -lcompression -o "${TEST_DIR}/core-tests"
"${TEST_DIR}/core-tests"

# Sharing keeps its toolbar visible. Exercise the exact-window branch without
# requiring Screen Recording permission or opening a system share sheet.
swiftc "${REPO_ROOT}/clipy_macos/Sources/NativeScreenshot/UI/NativeScreenshotShareImagePipeline.swift" \
  "${REPO_ROOT}/clipy_macos/Tests/NativeScreenshotShareImageRegression.swift" \
  -swift-version 5 -target "${MACOS_ARCH}-apple-macos13.0" \
  -o "${TEST_DIR}/share-image"
"${TEST_DIR}/share-image"

# Explicit opt-in: disposable status items, real AXPress, existing permissions only.
if [ "${CLIPY_MENU_BAR_LIVE_TESTS:-0}" = 1 ]; then
  "${TEST_DIR}/core-tests" --clipy-overflow-live-tests
fi

# Render the native view with disposable fictional content; never writes real history.
if [ -n "${CLIPY_PANEL_SNAPSHOT_DIR:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-panel-snapshot
fi

if [ -n "${CLIPY_TOKEN_SNAPSHOT_DIR:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-token-snapshot
fi
