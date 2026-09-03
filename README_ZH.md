<p align="right"><a href="README.md">English</a> &nbsp; / &nbsp; <b>简体中文</b></p>

<div align="center">

<img src="Logo.png" alt="Clipy" width="96" height="96" />

# Clipy

**让 Mac 和 Android，共享你的剪贴板。**

找回复制过的内容，在另一台设备上继续使用。局域网同步，无需账号。

**[下载 macOS 版 →](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.15/ClipyClone-macOS-v1.0.15.zip)** &nbsp; · &nbsp; **[下载 Android 版 →](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.15/ClipyClone-Android-arm64-v8a-v1.0.15.apk)**

<sub>已发布 v1.0.15 · macOS 13+，Apple Silicon · Android arm64 · <a href="docs/GETTING_STARTED_ZH.md#下载与版本">其他安装包与版本说明</a></sub>

当前源码版本：**1.0.16** · [构建版本配置](clipy_android/pubspec.yaml)

[![Release](https://img.shields.io/github/v/release/JunWeiUp/Clipy?label=Release&logo=github&color=2ea44f)](https://github.com/JunWeiUp/Clipy/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/JunWeiUp/Clipy/ci.yml?branch=master&label=CI&logo=githubactions&logoColor=white)](https://github.com/JunWeiUp/Clipy/actions/workflows/ci.yml)
[![License review](https://img.shields.io/badge/license-review_required-orange)](THIRD_PARTY_NOTICES.md)

</div>

> **版本说明：**上方下载入口对应已发布的 v1.0.15，`master` 分支包含此后的更新。其中，私有配对密钥设置尚未包含在 v1.0.15 中；启用同步前请先阅读[同步版本差异](docs/GETTING_STARTED_ZH.md#同步版本差异)。

Release 徽章显示已公开发布的稳定版本，不代表当前源码版本，也不包含尚未发布的草稿。

> 发布前注意：截图模块移植自 macshot，需先完成[第三方许可核对](THIRD_PARTY_NOTICES.md)，再发布新的组合二进制。根目录的 MIT 文本不能代表该模块的完整许可条件。

## 看看实际界面

<p align="center">
  <img src="res/search.png" width="640" alt="Clipy 全局搜索的真实界面：剪贴板历史、内容预览，以及类型、来源应用和日期筛选。" />
</p>

<p align="center"><sub>按 <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>F</kbd> 找回之前复制的内容。截图来自真实应用，支持中英文界面。</sub></p>

## 让日常衔接更顺手

| 当你需要…… | Clipy 可以帮你…… |
| --- | --- |
| 找回之前复制的链接或文字 | 按类型、来源应用和日期搜索剪贴板历史。 |
| 在 Mac 和 Android 之间传递复制的内容 | 在可信局域网中跨设备同步。 |
| 重复使用常用回复或代码片段 | 在 macOS 上管理片段，并设置快捷键。 |

macOS 端使用原生 Swift / AppKit，Android 端使用 Flutter。截图标注、OCR 和通知镜像等功能见[完整功能说明](#完整功能说明)，同步的信任边界见[安全说明](SECURITY.md)。

## 三步开始使用

1. **安装对应版本。** macOS 解压后，将 `ClipyClone.app` 移到「应用程序」；Android 安装 APK。Mac 端入口在菜单栏。详见[平台与首次启动说明](docs/GETTING_STARTED_ZH.md)。
2. **试试剪贴板历史。** 复制一段无敏感信息的测试文字，打开菜单栏应用，再按 <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>F</kbd> 搜索。使用相关功能时，再按提示授予对应权限。
3. **连接另一台设备。** 按[对应版本的同步步骤](docs/GETTING_STARTED_ZH.md#连接-mac-与-android)设置，首次测试时保持两端应用打开，并分别开启向目标设备的剪贴板共享。

**[安装与常见问题](docs/GETTING_STARTED_ZH.md)** · **[反馈问题](https://github.com/JunWeiUp/Clipy/issues/new?template=bug_report.yml)** · **[建议新功能](https://github.com/JunWeiUp/Clipy/issues/new?template=feature_request.yml)**

如果 Clipy 帮到了你的日常工作，欢迎在 [GitHub 点个 ⭐](https://github.com/JunWeiUp/Clipy)，让更多人发现它。中文或英文反馈都欢迎。

## 完整功能说明

<details>
<summary><b>展开剪贴板、截图、同步与通知功能</b></summary>

### 📋 剪贴板历史
- 自动捕获**文本、RTF、HTML、PDF、图片、文件**。
- **SHA-256 去重** —— 重复复制会把内容重新置顶，而不是重复堆积。
- **文件感知** —— 显示源文件路径，并支持在 Finder 中定位。
- 可按 bundle id **排除指定 App**（密码管理器、钥匙串等）。
- 历史条数可配，菜单懒加载，内存占用极低。
- 历史媒体文件可选**静态加密**（密钥存于 macOS 钥匙串）。

### ✂️ 片段管理（macOS）
- 用**文件夹**组织常用文本/代码，支持拖拽排序。
- 每个片段/文件夹可绑定**全局快捷键**，内置快捷键录入器。
- 片段库支持 **XML 导入/导出**。

### 📸 截图与标注（macOS）
- 捕获模式：**区域 / 窗口 / 全屏 / 滚动长截图 / 屏幕录制（MP4 + GIF）**。
- **18 工具标注引擎**（移植自 [macshot](https://github.com/sw33tLie/macshot)），统一单全屏 OverlayView：画笔（压感 + 平滑）、直线、**6 种箭头**（曲线/虚线/手绘）、矩形、填充矩形、椭圆、**正片叠底荧光笔**、富文本（粗体/斜体/描边/背景）、自增**编号**、emoji/图片**图章**、**马赛克/模糊/纯色/擦除**遮挡、**放大镜**、**像素标尺**、**取色器**、**聚光灯**。
- 每工具**二级选项条** + 玻璃主工具条 + 颜色/emoji/字体/特效弹层。
- **美化**渐变包裹 + **图像特效**（亮度/对比度/饱和度/锐度）。
- **滚动长截图**带侧边实时预览（基于 Vision 的帧拼接）。
- **录屏**含系统音频 + 麦克风双轨、摄像头悬浮窗、鼠标点击高亮、按键显示。
- 基于 Apple Vision 的**端侧 OCR** + **二维码**；**自动遮挡**敏感信息；**Apple Translation** 翻译覆盖。
- **贴图到屏幕**（缩放/透明度/旋转/编辑）、**右下角浮动缩略图**反馈、**独立编辑器**窗口（裁剪/翻转/缩放）、另存为、复制。
- 保存目录可配、单键工具快捷键、全局快捷键。
- 完整本地化（英文 + 简体中文）。

### 🔍 全局搜索（macOS）
- 任意位置按 <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> 呼出。
- 支持**正则**，并可按**类型、来源 App、日期**筛选。
- 结果排序、多选、复制/粘贴，搜索结果中即可置顶。

### 🔄 加密局域网同步
- macOS 与 Android 之间全程 **AES-GCM 256 位**加密传输。
- 设备通过 **/24 子网扫描** 与 **手动 IP:端口** 互相发现（可跨 2.4G/5G 子网）—— 无需云端、无需账号。
- 剪贴板历史可靠投递（ack + 离线队列）。
- 稳健可靠：**离线对端队列**会在设备短暂断网后自动重投。
- 通过内容哈希**防止环路**，复制内容不会在设备间无限弹跳。

### 🔔 手机通知镜像（Android → macOS）
- 在 Mac 上直接查看 Android 手机的通知。
- **双向** dismiss 与一键清除；支持按 App **白名单**过滤。

### ⌨️ 全局快捷键 与 🌍 国际化
- 搜索、截图、每个片段均可绑定快捷键。
- 中/英文界面；macOS 原生端与 Flutter Android 端。iOS 为实验性目标，未纳入 CI 与真机验证，不能默认使用 Android 原生能力。

<details>
<summary><b>🔐 关于安全的说明</b></summary>

请只在可信网络中启用同步，并配置足够强的私有配对密钥。密钥留空会使用源码中公开的兼容密钥，**无法对知道源码的攻击者提供保密性**。授权设备列表不是密码学身份认证，单次文本与文件发送也有不同的授权规则。完整说明见 [SECURITY.md](SECURITY.md)。
</details>

</details>

<details>
<summary><b>开发者文档：构建、架构与同步协议</b></summary>

## 🛠️ 从源码构建

以下命令均在仓库根目录执行。如果网络需要代理，请先启用自己的终端代理配置（已配置 `proxy` 命令的本机可先执行 `proxy`）；构建脚本本身不依赖特定代理命令。

### macOS（Swift / AppKit）

环境要求：**Xcode 26+** 和 macOS 26 SDK；应用最低部署版本仍为 macOS 13。

```bash
./build_macos_app.sh
```

产物为 `clipy_macos/ClipyClone.app` 和 `clipy_macos/ClipyClone.app.dSYM`，默认**不安装、不启动**。如需构建后安装到 `/Applications` 并自动启动，请先退出正在运行的 Clipy，再执行：

```bash
INSTALL_APP=1 LAUNCH_APP=1 ./build_macos_app.sh
```

本地 macOS 构建使用 ad-hoc 签名，不含 Developer ID 签名或公证。详见[构建与签名选项](docs/DEVELOPMENT.md#macos)。

### Android（Flutter）

环境要求：Flutter **3.41.7**（见 `.fvmrc`）、JDK 17 与 Android SDK。

每台构建机器首次使用时，需按 [Android 签名指南](docs/DEVELOPMENT.md#android)配置固定发布密钥，使用 Git 忽略的 `clipy_android/android/key.properties` 或签名环境变量。配置完成后，直接运行：

```bash
./build_android_apk.sh
```

产物为 `dist/ClipyClone-Android-arm64-v8a-v<version>.apk` 和 `dist/ClipyClone-Android-armeabi-v7a-v<version>.apk`。脚本会解析锁定的依赖并使用已配置的密钥签名两个 Release APK。后续升级须保留同一份密钥，切勿提交签名文件或密码。

如果只需调试包，无需配置发布签名：

```bash
(
  cd clipy_android
  flutter pub get --enforce-lockfile
  flutter build apk --debug --no-pub
)
```

调试包位于 `clipy_android/build/app/outputs/flutter-apk/app-debug.apk`。调试包与发布包签名不同，不能假设可互相覆盖安装；如确需卸载重装，请先备份应用数据。

iOS 仍为实验性目标，尚未纳入本项目 CI 验证。

### 版本号与检查

两个根目录构建脚本默认读取 [`clipy_android/pubspec.yaml`](clipy_android/pubspec.yaml) 中的 `version: X.Y.Z+N`：`X.Y.Z` 为应用版本，`N` 为构建号；也可通过 `APP_VERSION`、`BUILD_NUMBER` 显式覆盖单次构建。版本变更时应在同一批改动中同步更新**中英文两份 README**，并保持构建号递增；若要覆盖更高构建号的 CI 包，本地需使用更高的 `BUILD_NUMBER`。

在仓库根目录运行 `bash scripts/check.sh all` 可执行质量检查。

## 🏗️ 架构

**macOS 应用** —— Swift + AppKit，原生菜单栏应用（`LSUIElement`，不占 Dock）：
- `MenuController` —— 状态栏菜单：历史、片段、设备与各项操作。
- `ClipboardManager` —— 剪贴板轮询、历史持久化、去重、同步分发。
- `SnippetManager` —— 文件夹、片段、快捷键、导入导出。
- `SyncManager` —— 子网/手动发现、带长度前缀的 TCP 同步（协议 v2）、AES-GCM 加密、可靠历史与通知投递。
- `Sources/Screenshot/` —— 完整的截图/录屏引擎（移植自 macshot）：统一 OverlayView、18 工具标注引擎、滚动长截图、录屏、美化/特效、OCR、贴图、浮动缩略图、编辑器窗口。由 `ScreenshotSessionCoordinator` 编排。
- `SearchWindow` —— 带筛选与排序的全局搜索。
- `NotificationManager` —— 手机通知镜像。
- `PreferencesManager`、`SettingsWindow`、`SnippetEditorWindow`、`LogWindow` —— 配置与编辑界面。

**Android/iOS 应用** —— Flutter/Dart：
- `lib/main.dart` —— 默认入口；`lib/app/` 负责初始化与无界面引擎桥接。
- `lib/features/` —— 设备、历史、设置、日志与文件页面。
- `lib/clipboard_manager.dart` —— 剪贴板监听、历史、同步协调。
- `lib/sync_manager.dart` —— 子网/手动发现、TCP 同步 v2、加密、历史与通知投递。
- `lib/notification_manager.dart` —— `NotificationListenerService` 集成。

## 🔁 同步协议

Clipy 使用面向局域网的协议 v2 处理剪贴板历史与通知：

- **设备发现** —— `/24` TCP 端口扫描 + 手动 `IP:端口`（可跨子网 / 双频段）。
- **传输方式** —— 原生 TCP，每条 JSON 信封带 4 字节大端长度前缀（`v: 2`，单帧上限 2 MB）。
- **消息类型** —— `history`、`history.fetch`、`notif.post` / `dismiss` / `clear` / `ack`、`hello` / `welcome`、`ping` / `pong`、`ack`。
- **加密** —— AES-GCM 256 位（配置配对密钥时走 HKDF）。
- **授权** —— 仅向本机授权列表中的设备推送剪贴板/通知。
- **可靠投递** —— 历史帧需在落库成功后 `ack`；有界离线队列 + 端点缓存用于重连。
- **环路防止** —— 内容哈希避免重复广播。

完整线协议、无 UI 保活通道规则与代码地图见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

## 📁 项目结构

```
clipy_macos/Sources/      # macOS Swift/AppKit 源码
clipy_android/lib/        # Android 与 iOS 的 Flutter/Dart 源码
build_macos_app.sh        # macOS 应用包构建脚本
build_android_apk.sh      # Android 分 ABI APK 构建脚本
.github/workflows/        # CI + reviewed release drafts
res/                      # README 图片资源
assets/                   # Logo 与应用图标
```

</details>

## 🤝 贡献

欢迎用中文或英文提交 Issue 和 Pull Request！先阅读[贡献规范](CONTRIBUTING.md)与[架构地图](docs/ARCHITECTURE.md)。贡献代码：

1. Fork 仓库并创建功能分支。
2. 运行 `bash scripts/check.sh all`，并构建受影响的原生平台。
3. 提交 Pull Request 描述你的改动。

## 📦 发布

配置发布签名后，先更新 `clipy_android/pubspec.yaml` 和中英文 README 并提交改动，再推送与源码版本一致的**全新、未使用过的版本标签**。这会执行 CI 并创建待人工审核的 **Release 草稿**：

```bash
VERSION="$(awk '/^version:/ {split($2, v, "+"); print v[1]; exit}' clipy_android/pubspec.yaml)"
git tag "v${VERSION}"
git push origin "v${VERSION}"
```

也可以手动触发 `Release` workflow，并输入与源码一致的 `X.Y.Z` 版本号。不要移动或覆盖已有版本标签。发布草稿前请完成[发布清单](docs/DEVELOPMENT.md#release-checklist)，尤其是许可与签名核对。

可使用[更新说明模板](docs/RELEASE_NOTES_TEMPLATE.md)，说明用户可见的变化、升级步骤与实际提供的平台版本。

## 📄 许可证

仓库目前保留 [MIT License](LICENSE) 文本，但 macshot 移植模块仍需单独核对许可与来源，不能将整个组合应用直接视为仅受 MIT 许可约束。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=JunWeiUp/Clipy&type=Date)](https://star-history.com/#JunWeiUp/Clipy&Date)

---

<div align="center">

如果 Clipy 帮到了你，欢迎给个 ⭐ —— 这能让更多人发现这个项目！

</div>
