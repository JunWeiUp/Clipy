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

swiftc "${COMMON[@]}" "${SOURCES}/Annotation/"*.swift "${SOURCES}/Capture/NativeScreenshotCaptureGeometry.swift" "${SOURCES}/Capture/NativeScreenshotStaticCapture.swift" "${TESTS}/NativeScreenshotCaptureRegression.swift" -o "${TEST_DIR}/capture"
"${TEST_DIR}/capture"

swiftc "${COMMON[@]}" "${SOURCES}/Editor/"*.swift "${TESTS}/NativeScreenshotImageEditorRegression.swift" -o "${TEST_DIR}/image-editor"
"${TEST_DIR}/image-editor"

swiftc "${COMMON[@]}" -D EDITOR_STANDALONE_TEST "${SOURCES}/Annotation/"*.swift "${SOURCES}/Editor/"*.swift "${SOURCES}/UI/NativeScreenshotEditorController.swift" "${SOURCES}/UI/NativeScreenshotCanvasGeometry.swift" "${SOURCES}/UI/NativeScreenshotLocalization.swift" "${TESTS}/NativeScreenshotEditorUIRegression.swift" -o "${TEST_DIR}/editor-ui"
"${TEST_DIR}/editor-ui"

swiftc "${COMMON[@]}" -Xlinker -weak_framework -Xlinker Translation "${SOURCES}/Recognition/"*.swift "${TESTS}/NativeScreenshotRecognitionRegression.swift" -o "${TEST_DIR}/recognition"
"${TEST_DIR}/recognition"

swiftc "${COMMON[@]}" -D NATIVE_SCREENSHOT_RECORDING_TESTS "${SOURCES}/Recording/"*.swift "${TESTS}/NativeScreenshotRecordingRegression.swift" -o "${TEST_DIR}/recording"
"${TEST_DIR}/recording"

swiftc "${COMMON[@]}" "${SOURCES}/Coordinator/NativeScreenshotUserText.swift" "${SOURCES}/Delivery/NativeScreenshotVideoSegmentExporter.swift" "${TESTS}/NativeScreenshotVideoSegmentRegression.swift" -o "${TEST_DIR}/video-segment"
"${TEST_DIR}/video-segment"

swiftc "${COMMON[@]}" "${SOURCES}/UI/NativeScreenshotSettingsCompatibility.swift" "${TESTS}/NativeScreenshotSettingsCompatibilityRegression.swift" -o "${TEST_DIR}/settings"
"${TEST_DIR}/settings" "${REPO_ROOT}/clipy_macos/Sources/UI/ScreenshotSettingsView.swift"
