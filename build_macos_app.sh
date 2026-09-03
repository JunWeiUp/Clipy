#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/build_common.sh
source "${REPO_ROOT}/scripts/lib/build_common.sh"
resolve_build_version

MACOS_PROJECT_DIR="${REPO_ROOT}/clipy_macos"
APP_NAME="ClipyClone"
APP_BUNDLE="${APP_NAME}.app"
# Preserve the existing identifier: changing it invalidates existing TCC grants.
BUNDLE_ID="${BUNDLE_ID:-com.yourdomain.ClipyClone}"
GENERATE_DSYM="${GENERATE_DSYM:-1}"
INSTALL_APP="${INSTALL_APP:-0}"
LAUNCH_APP="${LAUNCH_APP:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MACOS_ARCH="${MACOS_ARCH:-arm64}"

validate_boolean GENERATE_DSYM "${GENERATE_DSYM}"
validate_boolean INSTALL_APP "${INSTALL_APP}"
validate_boolean LAUNCH_APP "${LAUNCH_APP}"
[ "${LAUNCH_APP}" != 1 ] || [ "${INSTALL_APP}" = 1 ] || fail "LAUNCH_APP=1 requires INSTALL_APP=1"
[[ "${BUNDLE_ID}" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "Invalid BUNDLE_ID"
case "${MACOS_ARCH}" in
  arm64|x86_64) ;;
  *) fail "MACOS_ARCH must be arm64 or x86_64" ;;
esac
[ "$(uname -s)" = Darwin ] || fail "The macOS app must be built on macOS"
for tool in swiftc codesign plutil sips iconutil ditto; do require_command "${tool}"; done
if [ "${GENERATE_DSYM}" = 1 ]; then require_command dsymutil; fi
if [ "${INSTALL_APP}" = 1 ] && pgrep -x "${APP_NAME}" >/dev/null; then
  fail "Quit ${APP_NAME} before installing; the build never terminates a running app"
fi

# Build in isolation. A compile/signing failure leaves the previous bundle intact.
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipy-build.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT
STAGED_APP="${BUILD_DIR}/${APP_BUNDLE}"
mkdir -p "${STAGED_APP}/Contents/MacOS" "${STAGED_APP}/Contents/Resources"
cp -R "${MACOS_PROJECT_DIR}/Sources" "${BUILD_DIR}/Sources"

SWIFT_SOURCES=()
while IFS= read -r -d '' source_path; do
  SWIFT_SOURCES+=("${source_path}")
done < <(find "${BUILD_DIR}/Sources" -type f -name '*.swift' -print0)
[ "${#SWIFT_SOURCES[@]}" -gt 0 ] || fail "No Swift sources found"

# An array with zero elements trips Bash 3.2's nounset; use conditional expansion.
DEBUG_FLAGS=()
if [ "${GENERATE_DSYM}" = 1 ]; then DEBUG_FLAGS+=(-g); fi
printf 'Building %s %s (%s) for %s...\n' "${APP_NAME}" "${APP_VERSION}" "${BUILD_NUMBER}" "${MACOS_ARCH}"
swiftc "${SWIFT_SOURCES[@]}" ${DEBUG_FLAGS[@]+"${DEBUG_FLAGS[@]}"} \
  -whole-module-optimization -swift-version 5 -target "${MACOS_ARCH}-apple-macos13.0" -D OFFLINE \
  -emit-object -emit-module -module-name "${APP_NAME}" \
  -emit-module-path "${BUILD_DIR}/${APP_NAME}.swiftmodule" \
  -o "${BUILD_DIR}/${APP_NAME}.o"
# Retain the object/module until dsymutil finishes; swiftc's implicit temporary
# objects otherwise disappear before debug symbols can be extracted.
swiftc "${BUILD_DIR}/${APP_NAME}.o" -target "${MACOS_ARCH}-apple-macos13.0" \
  -o "${STAGED_APP}/Contents/MacOS/${APP_NAME}" \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework Carbon \
  -framework UserNotifications -framework ServiceManagement -framework ApplicationServices \
  -framework Security -framework Vision -framework CoreImage -framework ScreenCaptureKit \
  -framework UniformTypeIdentifiers -framework PDFKit -framework WebKit -framework Quartz \
  -framework AVFoundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
  -lcompression

PLIST="${STAGED_APP}/Contents/Info.plist"
cp "${MACOS_PROJECT_DIR}/Resources/Info.plist" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"
plutil -lint "${PLIST}"

ICON_SOURCE="${REPO_ROOT}/Clipy/Resources/AppIcon.png"
[ -f "${ICON_SOURCE}" ] || fail "App icon source is missing: ${ICON_SOURCE}"
ICONSET="${BUILD_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "${retina_size}" "${retina_size}" "${ICON_SOURCE}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${STAGED_APP}/Contents/Resources/AppIcon.icns"
cp "${REPO_ROOT}/LICENSE" "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "${STAGED_APP}/Contents/Resources/"

if [ "${GENERATE_DSYM}" = 1 ]; then
  dsymutil "${STAGED_APP}/Contents/MacOS/${APP_NAME}" -o "${BUILD_DIR}/${APP_BUNDLE}.dSYM"
fi

# Use only the explicitly requested identity. Never silently switch certificates.
codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" \
  --timestamp=none "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"
if [ "${SIGN_IDENTITY}" = "-" ]; then
  printf 'Ad-hoc signed local build; not Developer ID signed or notarized.\n'
fi

OUTPUT_APP="${MACOS_PROJECT_DIR}/${APP_BUNDLE}"
rm -rf "${OUTPUT_APP}" "${OUTPUT_APP}.dSYM"
mv "${STAGED_APP}" "${OUTPUT_APP}"
if [ "${GENERATE_DSYM}" = 1 ]; then
  mv "${BUILD_DIR}/${APP_BUNDLE}.dSYM" "${OUTPUT_APP}.dSYM"
fi
printf 'Built: %s\n' "${OUTPUT_APP}"

if [ "${INSTALL_APP}" = 1 ]; then
  INSTALLED_APP="/Applications/${APP_BUNDLE}"
  # Explicit opt-in installation retains a recoverable copy of the old app.
  if [ -e "${INSTALLED_APP}" ]; then
    BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipy-install-backup.XXXXXX")"
    mv "${INSTALLED_APP}" "${BACKUP_DIR}/${APP_BUNDLE}"
    printf 'Previous installation saved at: %s\n' "${BACKUP_DIR}/${APP_BUNDLE}"
  fi
  ditto "${OUTPUT_APP}" "${INSTALLED_APP}"
  printf 'Installed: %s\n' "${INSTALLED_APP}"
  if [ "${LAUNCH_APP}" = 1 ]; then open "${INSTALLED_APP}"; fi
fi
