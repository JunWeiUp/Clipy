#!/bin/bash

# 配置变量
APP_NAME="ClipyClone"
BUNDLE_ID="com.yourdomain.ClipyClone"
EXECUTABLE_NAME="ClipyClone"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🚀 开始构建 ${APP_NAME}.app..."

# 1. 清理旧版本
rm -rf "${APP_BUNDLE}"

# 2. 创建目录结构
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 3. 编译源代码
echo "🔨 正在编译 Swift 源代码..."
swiftc \
    Sources/ClipboardManager.swift \
    Sources/MenuController.swift \
    Sources/PreferencesManager.swift \
    Sources/SnippetManager.swift \
    Sources/SyncManager.swift \
    Sources/HotKeyManager.swift \
    Sources/SettingsWindow.swift \
    Sources/SnippetEditorWindow.swift \
    Sources/LogManager.swift \
    Sources/LogWindow.swift \
    Sources/main.swift \
    -o "${MACOS_DIR}/${EXECUTABLE_NAME}" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Carbon

if [ $? -ne 0 ]; then
    echo "❌ 编译失败！"
    exit 1
fi

# 4. 生成 Info.plist
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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
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
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

echo "✅ 构建完成: ${APP_BUNDLE}"
echo "💡 你可以双击 ${APP_BUNDLE} 来运行程序，或者在终端输入: open ${APP_BUNDLE}"
