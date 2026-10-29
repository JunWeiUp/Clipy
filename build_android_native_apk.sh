#!/bin/bash
set -euo pipefail

# Native Kotlin/Compose Android APKs (kept alternative; releases use the Flutter
# build_android_apk.sh). Same application ID and signer as the Flutter app.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/build_common.sh
source "${REPO_ROOT}/scripts/lib/build_common.sh"
resolve_android_build_version
export APP_VERSION BUILD_NUMBER
ANDROID_DIR="${REPO_ROOT}/clipy_android_native"
DIST_DIR="${REPO_ROOT}/dist"
APP_NAME="ClipyClone"
TARGET_PLATFORM="${TARGET_PLATFORM:-android-arm,android-arm64}"
SPLIT_PER_ABI="${SPLIT_PER_ABI:-1}"
validate_boolean SPLIT_PER_ABI "${SPLIT_PER_ABI}"
if [ "${SPLIT_PER_ABI}" = 1 ] && [ "${TARGET_PLATFORM}" != android-arm,android-arm64 ]; then
    fail "Split packaging supports TARGET_PLATFORM=android-arm,android-arm64; use SPLIT_PER_ABI=0 for a custom target"
fi

# Preserve the public Flutter-era target names, without calling Flutter.
ABIS=()
case "${TARGET_PLATFORM}" in
    ,*|*,|*,,*) fail "TARGET_PLATFORM contains an empty target" ;;
esac
IFS=, read -r -a TARGETS <<< "${TARGET_PLATFORM}"
for target in "${TARGETS[@]}"; do
    case "${target}" in
        android-arm) ABIS+=(armeabi-v7a) ;;
        android-arm64) ABIS+=(arm64-v8a) ;;
        android-x64) ABIS+=(x86_64) ;;
        *) fail "Unsupported TARGET_PLATFORM: ${target}" ;;
    esac
done
[ "${#ABIS[@]}" -gt 0 ] || fail "TARGET_PLATFORM must not be empty"
[ -f "${ANDROID_DIR}/gradlew" ] || fail "Native Android Gradle wrapper is missing"
require_command java
mkdir -p "${DIST_DIR}"
cd "${ANDROID_DIR}"
OUTPUT_APK="${ANDROID_DIR}/app/build/outputs/apk/release/app-release.apk"
printf 'Building native production Android %s (actual versionCode %s)...\n' "${APP_VERSION}" "${BUILD_NUMBER}"

build_apk() {
    bash ./gradlew --no-daemon :app:assembleRelease -PnativeProduction=true "$1"
    [ -s "${OUTPUT_APK}" ] || fail "Expected signed release APK was not generated: ${OUTPUT_APK}"
    cp "${OUTPUT_APK}" "$2"
    printf 'Build complete: %s\n' "$2"
}

if [ "${SPLIT_PER_ABI}" = 1 ]; then
    for abi in "${ABIS[@]}"; do
        build_apk "-PnativeAbi=${abi}" "${DIST_DIR}/${APP_NAME}-Android-${abi}-v${APP_VERSION}.apk"
    done
else
    ABI_LIST="$(IFS=,; printf '%s' "${ABIS[*]}")"
    build_apk "-PnativeAbis=${ABI_LIST}" "${DIST_DIR}/${APP_NAME}-Android-v${APP_VERSION}.apk"
fi
