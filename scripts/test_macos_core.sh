#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipy-core-tests.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
cp -R "${REPO_ROOT}/clipy_macos/Sources" "${TEST_DIR}/Sources"
cp "${REPO_ROOT}/clipy_macos/Tests/CoreRegression.swift" "${TEST_DIR}/CoreRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/WordLookupRegression.swift" "${TEST_DIR}/WordLookupRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/FolderTransferRegression.swift" "${TEST_DIR}/FolderTransferRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/SyncTransportRegression.swift" "${TEST_DIR}/SyncTransportRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/MenuBarOverflowRegression.swift" "${TEST_DIR}/MenuBarOverflowRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/MenuBarPanelRegression.swift" "${TEST_DIR}/MenuBarPanelRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/CaptureResultsLayoutRegression.swift" "${TEST_DIR}/CaptureResultsLayoutRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/VideoEditorLayoutRegression.swift" "${TEST_DIR}/VideoEditorLayoutRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/EditorLayoutRegression.swift" "${TEST_DIR}/EditorLayoutRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/KeepAwakeRegression.swift" "${TEST_DIR}/KeepAwakeRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/OCRMemoryRegression.swift" "${TEST_DIR}/OCRMemoryRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/ScreenshotOCRGestureRegression.swift" "${TEST_DIR}/ScreenshotOCRGestureRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/UIMemoryPolicyRegression.swift" "${TEST_DIR}/UIMemoryPolicyRegression.swift"
cp "${REPO_ROOT}/clipy_macos/Tests/UIMemoryLifecycleRegression.swift" "${TEST_DIR}/UIMemoryLifecycleRegression.swift"
swiftc "${REPO_ROOT}/clipy_macos/Sources/Sync/SyncInboundBudget.swift" "${REPO_ROOT}/clipy_macos/Tests/SyncInboundBudgetRegression.swift" -o "${TEST_DIR}/inbound-budget-tests"
"${TEST_DIR}/inbound-budget-tests"
swiftc "${REPO_ROOT}/clipy_macos/Sources/ScreenControl/ScreenControlSecurity.swift" "${REPO_ROOT}/clipy_macos/Sources/ScreenControl/ScreenControlUnlockSubmission.swift" "${REPO_ROOT}/clipy_macos/Sources/ScreenControl/ScreenControlAXTraversal.swift" "${REPO_ROOT}/clipy_macos/Tests/ScreenControlRegression.swift" -o "${TEST_DIR}/screen-control-tests"
"${TEST_DIR}/screen-control-tests"
source "${REPO_ROOT}/scripts/common_relay_swift.sh"
common_relay_swift "${REPO_ROOT}" "$(uname -m)"
swiftc "${COMMON_RELAY_COMPILE_FLAGS[@]}" "${COMMON_RELAY_LINK_FLAGS[@]}" -target "$(uname -m)-apple-macos13.0" "${REPO_ROOT}/clipy_macos/Sources/Sync/SyncRelayGroupState.swift" "${REPO_ROOT}/clipy_macos/Tests/RelayGroupStateRegression.swift" -o "${TEST_DIR}/group-state-tests"
"${TEST_DIR}/group-state-tests"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("${source}"); done < <(find "${TEST_DIR}/Sources" -name '*.swift' -print0)
swiftc "${COMMON_RELAY_COMPILE_FLAGS[@]}" "${COMMON_RELAY_LINK_FLAGS[@]}" "${SOURCES[@]}" "${TEST_DIR}/CoreRegression.swift" "${TEST_DIR}/WordLookupRegression.swift" "${TEST_DIR}/FolderTransferRegression.swift" "${TEST_DIR}/SyncTransportRegression.swift" "${TEST_DIR}/MenuBarOverflowRegression.swift" "${TEST_DIR}/MenuBarPanelRegression.swift" "${TEST_DIR}/EditorLayoutRegression.swift" "${TEST_DIR}/VideoEditorLayoutRegression.swift" "${TEST_DIR}/CaptureResultsLayoutRegression.swift" "${TEST_DIR}/KeepAwakeRegression.swift" "${TEST_DIR}/OCRMemoryRegression.swift" "${TEST_DIR}/ScreenshotOCRGestureRegression.swift" "${TEST_DIR}/UIMemoryPolicyRegression.swift" "${TEST_DIR}/UIMemoryLifecycleRegression.swift" \
  -swift-version 5 -target "$(uname -m)-apple-macos13.0" -D OFFLINE -D CLIPY_CORE_TESTS \
  -lcompression -o "${TEST_DIR}/core-tests"
"${TEST_DIR}/core-tests"

# Mouse dispatch runs in its own registered AppKit lifecycle and targets the
# fixture window directly. Mandatory on CI; a missing success marker is failure.
UI_TEST_APP="${TEST_DIR}/ClipyUIRegression.app"
mkdir -p "${UI_TEST_APP}/Contents/MacOS"
cp "${TEST_DIR}/core-tests" "${UI_TEST_APP}/Contents/MacOS/ClipyUIRegression"
cat > "${UI_TEST_APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.clipyclone.ui-regression</string>
<key>CFBundleExecutable</key><string>ClipyUIRegression</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
UI_TEST_RESULT="${TEST_DIR}/history-ui-passed"
/usr/bin/open -W -n --stdout "${TEST_DIR}/history-ui.log" --stderr "${TEST_DIR}/history-ui-error.log" \
  "${UI_TEST_APP}" --args --clipy-history-selection-tests --result-file "${UI_TEST_RESULT}"
cat "${TEST_DIR}/history-ui.log" "${TEST_DIR}/history-ui-error.log"
test -f "${UI_TEST_RESULT}" || { echo "History UI regression did not complete successfully" >&2; exit 1; }

# Explicit opt-in: disposable status items, real AXPress, existing permissions only.
if [ "${CLIPY_MENU_BAR_LIVE_TESTS:-0}" = 1 ]; then
  "${TEST_DIR}/core-tests" --clipy-overflow-live-tests
fi

# Render the native view with disposable fictional content; never writes real history.
if [ -n "${CLIPY_PANEL_SNAPSHOT_DIR:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-panel-snapshot
fi

if [ -n "${CLIPY_WINDOW_SNAPSHOT_DIR:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-window-snapshot
fi

if [ -n "${CLIPY_EDITOR_SNAPSHOT_DIR:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-editor-snapshot
fi

if [ -n "${CLIPY_VIDEO_EDITOR_SNAPSHOT_DIR:-}" ] && [ -n "${CLIPY_VIDEO_EDITOR_FIXTURE:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-video-editor-snapshot
fi

if [ -n "${CLIPY_CAPTURE_RESULTS_SNAPSHOT_DIR:-}" ]; then
  "${TEST_DIR}/core-tests" --clipy-capture-results-snapshot
fi
