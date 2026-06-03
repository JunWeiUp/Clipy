#!/bin/bash
set -euo pipefail

# Flutter Android APK build script.
# This is separate from build_macos_app.sh, which builds the macOS .app bundle.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_DIR="${SCRIPT_DIR}/clipy_android"
DIST_DIR="${SCRIPT_DIR}/dist"

APP_NAME="ClipyClone"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TARGET_PLATFORM="${TARGET_PLATFORM:-android-arm,android-arm64}"
SPLIT_PER_ABI="${SPLIT_PER_ABI:-1}"

echo "Starting Android APK build for ${APP_NAME}..."

if [ ! -d "${ANDROID_DIR}" ]; then
    echo "Android project directory does not exist: ${ANDROID_DIR}"
    exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
    echo "flutter command not found. Please install Flutter and add it to PATH."
    exit 1
fi

mkdir -p "${DIST_DIR}"

cd "${ANDROID_DIR}"

echo "Resolving Flutter dependencies..."
flutter pub get

BUILD_ARGS=(
    build
    apk
    --release
    --target-platform
    "${TARGET_PLATFORM}"
    --build-name
    "${APP_VERSION}"
    --build-number
    "${BUILD_NUMBER}"
)

if [ "${SPLIT_PER_ABI}" = "1" ]; then
    BUILD_ARGS+=(--split-per-abi)
fi

echo "Building release APK..."
flutter "${BUILD_ARGS[@]}"

OUTPUT_DIR="${ANDROID_DIR}/build/app/outputs/flutter-apk"

if [ "${SPLIT_PER_ABI}" = "1" ]; then
    ARMV7_APK="${OUTPUT_DIR}/app-armeabi-v7a-release.apk"
    ARM64_APK="${OUTPUT_DIR}/app-arm64-v8a-release.apk"

    if [ ! -f "${ARMV7_APK}" ] || [ ! -f "${ARM64_APK}" ]; then
        echo "Expected split APK files were not generated in: ${OUTPUT_DIR}"
        exit 1
    fi

    cp "${ARMV7_APK}" "${DIST_DIR}/${APP_NAME}-Android-armeabi-v7a-v${APP_VERSION}.apk"
    cp "${ARM64_APK}" "${DIST_DIR}/${APP_NAME}-Android-arm64-v8a-v${APP_VERSION}.apk"

    echo "Build complete:"
    echo "  ${DIST_DIR}/${APP_NAME}-Android-armeabi-v7a-v${APP_VERSION}.apk"
    echo "  ${DIST_DIR}/${APP_NAME}-Android-arm64-v8a-v${APP_VERSION}.apk"
else
    UNIVERSAL_APK="${OUTPUT_DIR}/app-release.apk"

    if [ ! -f "${UNIVERSAL_APK}" ]; then
        echo "Expected APK file was not generated: ${UNIVERSAL_APK}"
        exit 1
    fi

    cp "${UNIVERSAL_APK}" "${DIST_DIR}/${APP_NAME}-Android-v${APP_VERSION}.apk"

    echo "Build complete:"
    echo "  ${DIST_DIR}/${APP_NAME}-Android-v${APP_VERSION}.apk"
fi
