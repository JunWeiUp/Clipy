#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

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
    Sources/UI/SearchView.swift
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

echo "✅ 构建完成: ${APP_BUNDLE}"
echo "💡 你可以双击 ${APP_BUNDLE} 来运行程序，或者在终端输入: open ${APP_BUNDLE}"
