#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipy-native-screenshot.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
MACOS_ARCH="$(uname -m)"
SOURCES="${REPO_ROOT}/clipy_macos/Sources/NativeScreenshot"
TESTS="${REPO_ROOT}/clipy_macos/Tests"
COMMON=(-swift-version 5 -target "${MACOS_ARCH}-apple-macos13.0" -D OFFLINE)

swiftc "${COMMON[@]}" "${SOURCES}/Annotation/"*.swift "${TESTS}/NativeScreenshotAnnotationRegression.swift" -o "${TEST_DIR}/annotation"
"${TEST_DIR}/annotation"

swiftc "${COMMON[@]}" "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/Annotation/"*.swift "${SOURCES}/Capture/NativeScreenshotCaptureGeometry.swift" "${SOURCES}/Capture/NativeScreenshotStaticCapture.swift" "${TESTS}/NativeScreenshotCaptureRegression.swift" -o "${TEST_DIR}/capture"
"${TEST_DIR}/capture"

swiftc "${COMMON[@]}" "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/Capture/NativeScreenshotStartupDeadline.swift" "${TESTS}/NativeScreenshotStartupRegression.swift" -o "${TEST_DIR}/startup"
"${TEST_DIR}/startup"

swiftc "${COMMON[@]}" "${SOURCES}/Editor/"*.swift "${TESTS}/NativeScreenshotImageEditorRegression.swift" -o "${TEST_DIR}/image-editor"
"${TEST_DIR}/image-editor"

swiftc "${COMMON[@]}" -D EDITOR_STANDALONE_TEST "${SOURCES}/Annotation/"*.swift "${SOURCES}/Editor/"*.swift "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/UI/NativeScreenshotEditorController.swift" "${SOURCES}/UI/NativeScreenshotCanvasGeometry.swift" "${SOURCES}/UI/NativeScreenshotLocalization.swift" "${SOURCES}/UI/NativeScreenshotToolbarConfiguration.swift" "${SOURCES}/UI/NativeScreenshotRememberedTool.swift" "${TESTS}/NativeScreenshotEditorUIRegression.swift" -o "${TEST_DIR}/editor-ui"
"${TEST_DIR}/editor-ui"

swiftc "${COMMON[@]}" "${SOURCES}/Annotation/"*.swift \
  "${SOURCES}/UI/NativeScreenshotRememberedTool.swift" \
  "${TESTS}/NativeScreenshotRememberedToolRegression.swift" -o "${TEST_DIR}/remembered-tool"
"${TEST_DIR}/remembered-tool"

swiftc "${COMMON[@]}" "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/UI/NativeScreenshotToolbarConfiguration.swift" "${TESTS}/NativeScreenshotToolbarConfigurationRegression.swift" -o "${TEST_DIR}/toolbar-config"
"${TEST_DIR}/toolbar-config"

swiftc "${COMMON[@]}" "${SOURCES}/UI/NativeScreenshotSelectionPresets.swift" \
  "${TESTS}/NativeScreenshotSelectionPresetsRegression.swift" -o "${TEST_DIR}/selection-presets"
"${TEST_DIR}/selection-presets"

swiftc "${COMMON[@]}" "${SOURCES}/UI/NativeScreenshotSelectionChrome.swift" \
  "${TESTS}/NativeScreenshotSelectionChromeRegression.swift" -o "${TEST_DIR}/selection-chrome"
"${TEST_DIR}/selection-chrome"

swiftc "${COMMON[@]}" "${SOURCES}/UI/NativeScreenshotSelectionInputState.swift" \
  "${TESTS}/NativeScreenshotSelectionInputRegression.swift" -o "${TEST_DIR}/selection-input"
"${TEST_DIR}/selection-input"

swiftc "${COMMON[@]}" -Xlinker -weak_framework -Xlinker Translation \
  "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" \
  "${SOURCES}/Annotation/"*.swift "${SOURCES}/Recognition/"*.swift \
  "${TESTS}/NativeScreenshotRecognitionRegression.swift" \
  "${TESTS}/NativeScreenshotTranslatedAnnotationRegression.swift" -o "${TEST_DIR}/recognition"
"${TEST_DIR}/recognition"

swiftc "${COMMON[@]}" -D NATIVE_SCREENSHOT_THUMBNAIL_FILE_TEST \
  "${SOURCES}/Delivery/NativeScreenshotThumbnailPresenter.swift" \
  "${TESTS}/NativeScreenshotThumbnailFileRegression.swift" -o "${TEST_DIR}/thumbnail-file"
"${TEST_DIR}/thumbnail-file"

swiftc "${COMMON[@]}" -D NATIVE_SCREENSHOT_RECORDING_TESTS "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/Capture/NativeScreenshotCaptureGeometry.swift" "${SOURCES}/Capture/NativeScreenshotStaticCapture.swift" "${SOURCES}/Recording/"*.swift "${TESTS}/NativeScreenshotRecordingRegression.swift" -o "${TEST_DIR}/recording"
"${TEST_DIR}/recording"

swiftc "${COMMON[@]}" "${SOURCES}/Coordinator/NativeScreenshotSessionHUDGeometry.swift" \
  "${SOURCES}/Recording/NativeScreenshotRecordingPanelPlacement.swift" \
  "${TESTS}/NativeScreenshotSessionHUDGeometryRegression.swift" -o "${TEST_DIR}/session-hud-geometry"
"${TEST_DIR}/session-hud-geometry"

swiftc "${COMMON[@]}" "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/Delivery/NativeScreenshotVideoSegmentExporter.swift" "${TESTS}/NativeScreenshotVideoSegmentRegression.swift" -o "${TEST_DIR}/video-segment"
"${TEST_DIR}/video-segment"

swiftc "${COMMON[@]}" "${SOURCES}/UI/NativeScreenshotSettingsCompatibility.swift" "${TESTS}/NativeScreenshotSettingsCompatibilityRegression.swift" -o "${TEST_DIR}/settings"
"${TEST_DIR}/settings" "${REPO_ROOT}/clipy_macos/Sources/UI/ScreenshotSettingsView.swift"
