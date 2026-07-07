#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_PROJECT_DIR="${SCRIPT_DIR}/clipy_macos"
cd "${MACOS_PROJECT_DIR}"

# 配置变量
APP_NAME="ClipyClone"
BUNDLE_ID="com.yourdomain.ClipyClone"
EXECUTABLE_NAME="ClipyClone"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

SWIFT_SOURCES=(
    Sources/Localization.swift
    Sources/HistoryMediaStore.swift
    Sources/HistoryThumbnailCache.swift
    Sources/AppDatabase.swift
    Sources/HistoryRepository.swift
    Sources/ClipboardManager.swift
    Sources/HistorySearchRanker.swift
    Sources/HistorySearchTypes.swift
    Sources/HistorySearchIndexBuilder.swift
    Sources/HistorySearchStateStore.swift
    Sources/SearchGlobalHotKeyManager.swift
    Sources/ScreenshotTypes.swift
    Sources/ScreenCapturePermissionManager.swift
    Sources/ScreenshotCaptureService.swift
    Sources/ImageOCRService.swift
    Sources/CaptureOverlayWindow.swift
    Sources/CaptureSelectionToolbar.swift
    Sources/CaptureAnnotationPanel.swift
    Sources/ScreenshotExport.swift
    Sources/UIElementDetector.swift
    Sources/CaptureMagnifierView.swift
    Sources/ScreenshotSaveService.swift
    Sources/ScreenshotImageProcessor.swift
    Sources/ScreenshotCoordinator.swift
    Sources/ScreenshotEditorViewModel.swift
    Sources/ScreenshotGlobalHotKeyManager.swift
    Sources/PinPanelController.swift
    Sources/SecureStorageCrypto.swift
    Sources/HistoryKeychain.swift
    Sources/MenuController.swift
    Sources/PreferencesManager.swift
    Sources/SnippetManager.swift
    Sources/SyncManager.swift
    Sources/NotificationManager.swift
    Sources/NotificationRepository.swift
    Sources/NotificationWindow.swift
    Sources/DeviceCollectorTypes.swift
    Sources/DeviceCollectorRepository.swift
    Sources/DeviceCollectorManager.swift
    Sources/CollectorWindow.swift
    Sources/HotKeyManager.swift
    Sources/SettingsWindow.swift
    Sources/ScreenshotSettingsWindow.swift
    Sources/SnippetEditorWindow.swift
    Sources/ShortcutRecorderView.swift
    Sources/SearchWindow.swift
    Sources/WindowSession.swift
    Sources/LogManager.swift
    Sources/LogWindow.swift
    Sources/LaunchAtLoginManager.swift
    Sources/AccessibilityManager.swift
    Sources/UI/DesignTokens.swift
    Sources/UI/AppLanguageObserver.swift
    Sources/UI/HostingWindow.swift
    Sources/UI/AppWindowLayout.swift
    Sources/UI/AppToolbar.swift
    Sources/UI/StatusBarView.swift
    Sources/UI/EmptyStateView.swift
    Sources/UI/CountBadge.swift
    Sources/UI/RelativeTimeFormatter.swift
    Sources/UI/ShortcutRecorderRepresentable.swift
    Sources/UI/LeftAlignedTextInput.swift
    Sources/UI/SettingsView.swift
    Sources/UI/ScreenshotSettingsView.swift
    Sources/UI/SearchView.swift
    Sources/UI/ScreenshotToolbarView.swift
    Sources/UI/AnnotationCanvasView.swift
    Sources/UI/HighlightedText.swift
    Sources/UI/HistoryPreviewView.swift
    Sources/UI/HistoryPreviewRepresentables.swift
    Sources/UI/NotificationView.swift
    Sources/UI/CollectorView.swift
    Sources/UI/SnippetEditorViewModel.swift
    Sources/UI/SnippetEditorSidebarRepresentable.swift
    Sources/UI/SnippetEditorView.swift
    Sources/main.swift
)

echo "🚀 开始构建 ${APP_NAME}.app..."

# 1. 清理旧版本
rm -rf "${APP_BUNDLE}"

# 2. 创建目录结构
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 3. 编译源代码
# 先复制到临时目录再编译，避免编译过程中 IDE/自动保存修改源文件导致 swiftc 报
# "input file '...' was modified during the build"
echo "🔨 正在编译 Swift 源代码..."
BUILD_SRC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipybuild.XXXXXX")"
trap 'rm -rf "${BUILD_SRC_DIR}"' EXIT
mkdir -p "${BUILD_SRC_DIR}/Sources/UI"
for src in "${SWIFT_SOURCES[@]}"; do
    dest="${BUILD_SRC_DIR}/${src}"
    mkdir -p "$(dirname "${dest}")"
    cp "${src}" "${dest}"
done

BUILD_SRC_PATHS=()
for src in "${SWIFT_SOURCES[@]}"; do
    BUILD_SRC_PATHS+=("${BUILD_SRC_DIR}/${src}")
done

swiftc \
    "${BUILD_SRC_PATHS[@]}" \
    -whole-module-optimization \
    -o "${MACOS_DIR}/${EXECUTABLE_NAME}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreGraphics \
    -framework Carbon \
    -framework UserNotifications \
    -framework ServiceManagement \
    -framework ApplicationServices \
    -framework Security \
    -framework Vision \
    -framework CoreImage \
    -framework ScreenCaptureKit \
    -framework UniformTypeIdentifiers \
    -framework PDFKit \
    -framework WebKit

# 4. 准备资源文件
echo "📦 准备资源文件..."
rm -rf AppIcon.iconset AppIcon.icns
if [ -f "Clipy/Resources/AppIcon.png" ]; then
    echo "🎨 生成 AppIcon.icns..."
    if sips -s format icns Clipy/Resources/AppIcon.png --out AppIcon.icns >/dev/null && [ -f "AppIcon.icns" ]; then
        cp AppIcon.icns "${RESOURCES_DIR}/"
    else
        echo "⚠️ AppIcon.icns 生成失败，跳过图标复制。"
    fi
    rm -rf AppIcon.iconset AppIcon.icns
fi

# 5. 生成 Info.plist
echo "📝 生成 Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Clipy needs local network access to sync clipboard content with your other devices.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Clipy needs screen recording permission to capture screenshots.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_clipy-sync._tcp</string>
    </array>
</dict>
</plist>
EOF

# 5. 设置权限
if [ ! -f "${MACOS_DIR}/${EXECUTABLE_NAME}" ]; then
    echo "❌ 可执行文件不存在: ${MACOS_DIR}/${EXECUTABLE_NAME}"
    exit 1
fi
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

# 6. 代码签名（TCC 权限绑定 Bundle ID + 证书；ad-hoc 签名每次编译都会变，导致需反复授权）
resolve_sign_identity() {
    if [ -n "${SIGN_IDENTITY}" ] && [ "${SIGN_IDENTITY}" != "-" ] && [ "${SIGN_IDENTITY}" != "adhoc" ]; then
        echo "${SIGN_IDENTITY}"
        return
    fi

    local identity
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" \
        | head -1 \
        | sed -E 's/.*"([^"]+)"/\1/')
    if [ -n "${identity}" ]; then
        echo "${identity}"
        return
    fi

    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/.*"([^"]+)"/\1/')
    if [ -n "${identity}" ]; then
        echo "${identity}"
        return
    fi

    echo "-"
}

sign_app_bundle() {
    local app_path="$1"
    codesign --force --sign "${SIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        --timestamp=none \
        "${app_path}/Contents/MacOS/${EXECUTABLE_NAME}"
    codesign --force --sign "${SIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        --timestamp=none \
        "${app_path}"
}

SIGN_IDENTITY="$(resolve_sign_identity)"
INSTALLED_APP="/Applications/${APP_BUNDLE}"

if command -v codesign >/dev/null 2>&1; then
    if [ "${SIGN_IDENTITY}" = "-" ]; then
        echo "⚠️ 未找到开发证书，使用 ad-hoc 签名（每次编译后屏幕录制等权限可能失效）"
        echo "   可在 Xcode 中登录 Apple ID 以自动获取 Apple Development 证书"
    else
        echo "🔏 正在签名 ${APP_BUNDLE} (identity: ${SIGN_IDENTITY})..."
    fi
    sign_app_bundle "${APP_BUNDLE}" || {
        echo "⚠️ 签名失败，将尝试 ad-hoc 签名 (-)"
        SIGN_IDENTITY="-"
        sign_app_bundle "${APP_BUNDLE}" || true
    }
    codesign --verify --deep --strict "${APP_BUNDLE}" 2>/dev/null || {
        echo "⚠️ 签名验证未通过，权限可能无法保持"
    }
fi

# 7. 安装到 /Applications（固定路径 + 稳定证书签名，TCC 权限才能跨编译保持）
echo "📦 正在安装到 ${INSTALLED_APP}..."
rm -rf "${INSTALLED_APP}"
ditto "${APP_BUNDLE}" "${INSTALLED_APP}"

if [ ! -d "${INSTALLED_APP}" ]; then
    echo "❌ 安装失败: ${INSTALLED_APP}"
    exit 1
fi

echo "✅ 构建完成: ${INSTALLED_APP}"
echo "💡 请始终从 /Applications 运行，不要从 build 目录直接启动"
if [ "${SIGN_IDENTITY}" = "-" ]; then
    echo "💡 当前为 ad-hoc 签名，每次编译后请在 系统设置 > 隐私与安全性 > 屏幕录制 中重新授权"
else
    echo "💡 使用开发证书签名，首次请在 系统设置 > 隐私与安全性 > 屏幕录制 中授权 ClipyClone，之后重编译无需重复授权"
    echo "   若仍反复要求授权，可执行: tccutil reset ScreenCapture ${BUNDLE_ID} 后重新授权一次"
fi

open "${INSTALLED_APP}"
