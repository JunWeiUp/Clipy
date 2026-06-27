#!/bin/bash
set -euo pipefail

# Rust macOS .app build script (GPUI).
# Separate from build_macos_app.sh (Swift) and build_android_apk.sh (Flutter).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="${SCRIPT_DIR}/clipy_macos"
DIST_DIR="${SCRIPT_DIR}/dist"

APP_NAME="${APP_NAME:-Clipy}"
BUNDLE_ID="${BUNDLE_ID:-com.yourdomain.ClipyClone}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
PACKAGE_ZIP="${PACKAGE_ZIP:-1}"

echo "Starting Rust macOS app build for ${APP_NAME}..."

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script must run on macOS (GPUI requires Metal)."
    exit 1
fi

if [ ! -d "${RUST_DIR}" ]; then
    echo "Rust project directory does not exist: ${RUST_DIR}"
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo command not found. Install Rust from https://rustup.rs/ and add it to PATH."
    exit 1
fi

mkdir -p "${DIST_DIR}"

cd "${RUST_DIR}"

echo "Building release binary..."
cargo build --release

echo "Creating app bundle..."
export APP_NAME BUNDLE_ID APP_VERSION BUILD_NUMBER
chmod +x scripts/build_app.sh
./scripts/build_app.sh

APP_BUNDLE="${RUST_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "Expected app bundle was not generated: ${APP_BUNDLE}"
    exit 1
fi

EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
if [ ! -x "${EXECUTABLE}" ]; then
    echo "Executable missing or not executable: ${EXECUTABLE}"
    exit 1
fi

DIST_APP="${DIST_DIR}/${APP_NAME}-Rust-macOS-v${APP_VERSION}.app"
rm -rf "${DIST_APP}"
ditto "${APP_BUNDLE}" "${DIST_APP}"

echo "Build complete:"
echo "  ${DIST_APP}"

if [ "${PACKAGE_ZIP}" = "1" ]; then
    DIST_ZIP="${DIST_DIR}/${APP_NAME}-Rust-macOS-v${APP_VERSION}.zip"
    rm -f "${DIST_ZIP}"
    ditto -c -k --keepParent "${DIST_APP}" "${DIST_ZIP}"
    echo "  ${DIST_ZIP}"
fi
