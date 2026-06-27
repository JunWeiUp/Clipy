#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$PROJECT_DIR")"

APP_NAME="${APP_NAME:-Clipy}"
BUNDLE_ID="${BUNDLE_ID:-com.yourdomain.ClipyClone}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="$PROJECT_DIR/target/release"
APP_BUNDLE="$PROJECT_DIR/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${APP_NAME}.app (Rust + GPUI)..."
cd "$PROJECT_DIR"

if [ ! -f "${BUILD_DIR}/clipy" ]; then
    echo "Release binary not found. Run: cargo build --release"
    exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "${BUILD_DIR}/clipy" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

ICON_FILE=""
ICON_BASENAME=""
if [ -f "${REPO_ROOT}/Clipy/Resources/AppIcon.png" ]; then
    ICON_SRC="${REPO_ROOT}/Clipy/Resources/AppIcon.png"
elif [ -f "${PROJECT_DIR}/assets/logo.png" ]; then
    ICON_SRC="${PROJECT_DIR}/assets/logo.png"
else
    ICON_SRC=""
fi

if [ -n "${ICON_SRC}" ]; then
    ICON_TMP="$(mktemp "${TMPDIR:-/tmp}/clipy-icon.XXXXXX.icns")"
    if sips -s format icns "${ICON_SRC}" --out "${ICON_TMP}" >/dev/null 2>&1; then
        cp "${ICON_TMP}" "${RESOURCES_DIR}/AppIcon.icns"
        ICON_FILE="AppIcon.icns"
        ICON_BASENAME="AppIcon"
    else
        cp "${ICON_SRC}" "${RESOURCES_DIR}/logo.png"
        ICON_FILE="logo.png"
        ICON_BASENAME="logo"
    fi
    rm -f "${ICON_TMP}"
fi

ICON_PLIST=""
if [ -n "${ICON_BASENAME}" ]; then
    ICON_PLIST=$'    <key>CFBundleIconFile</key>\n    <string>'"${ICON_BASENAME}"$'</string>\n'
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
${ICON_PLIST}    <key>LSUIElement</key>
    <true/>
    <key>NSBonjourServices</key>
    <array>
        <string>_clipy-sync._tcp</string>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Clipy uses the local network to sync clipboard with other devices.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Done: ${APP_BUNDLE}"
