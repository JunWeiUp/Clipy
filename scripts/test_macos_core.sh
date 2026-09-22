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
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("${source}"); done < <(find "${TEST_DIR}/Sources" -name '*.swift' -print0)
swiftc "${SOURCES[@]}" "${TEST_DIR}/CoreRegression.swift" "${TEST_DIR}/WordLookupRegression.swift" "${TEST_DIR}/SmartSwitchRegression.swift" "${TEST_DIR}/SmartSwitchVoiceRegression.swift" "${TEST_DIR}/SmartSwitchActionRegression.swift" "${TEST_DIR}/FolderTransferRegression.swift" \
  -swift-version 5 -target "$(uname -m)-apple-macos13.0" -D OFFLINE -D CLIPY_CORE_TESTS \
  -lcompression -o "${TEST_DIR}/core-tests"
"${TEST_DIR}/core-tests"
