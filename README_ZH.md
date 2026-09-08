<div align="center">
  <img src="Logo.png" alt="Clipy" width="72" height="72" />
  <h1>Clipy</h1>
  <h3>在这里复制，在那里继续。</h3>
  <p>记住复制过的内容，连接你的 Mac 与 Android。</p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
  <img src="res/readme/connected-hero.webp" alt="Clipy 概念插画：文字、图片与链接在 Mac 和 Android 手机之间流动" width="1120" />
  <br /><br />

**[下载 macOS 版 ↗](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.18/ClipyClone-macOS-v1.0.18.zip)** &nbsp;&nbsp; · &nbsp;&nbsp; **[下载 Android 版 ↗](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.18/ClipyClone-Android-arm64-v8a-v1.0.18.apk)**

<sub>最新正式版：v1.0.18 · macOS 13+ / Apple Silicon · Android arm64 · <a href="docs/GETTING_STARTED_ZH.md#下载与版本">其他安装包与安装说明</a></sub>

[![Release](https://img.shields.io/github/v/release/JunWeiUp/Clipy?label=Release&logo=github&color=1262f3)](https://github.com/JunWeiUp/Clipy/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/JunWeiUp/Clipy/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white)](https://github.com/JunWeiUp/Clipy/actions/workflows/ci.yml)
[![License review](https://img.shields.io/badge/license-review_required-orange)](THIRD_PARTY_NOTICES.md)

**[看看界面](#从菜单栏开始)** · **[Android](#在-android-上也很顺手)** · **[开始使用](#三步开始使用)** · **[完整功能](#完整功能说明)**

</div>

<br />

<table>
<tr>
<td width="33%" valign="top">

### 复制过，就找得回。

刚才的链接、昨天的文字、临时复制的资料。留在历史里，需要时搜索一下。

</td>
<td width="33%" valign="top">

### 换台设备，接着用。

在可信局域网中共享剪贴板，互传文件。Mac 与 Android 连起来，无需注册账号。

</td>
<td width="33%" valign="top">

### 常用的话，少打一遍。

把回复和代码放进 Mac 片段库，分好文件夹，再配上快捷键。下次直接调用。

</td>
</tr>
</table>

## 从菜单栏开始

### 小小菜单，装下日常顺手的操作。

搜索、查词、截图和最近复制，都在 Mac 菜单栏里。原生 Swift / AppKit，无需让一个窗口一直占着 Dock。

<a href="res/screenshots/macos-menu-en.png"><img src="res/screenshots/macos-menu-showcase.webp" alt="Clipy 菜单栏：搜索、最近复制、片段与常用工具" width="1120" /></a>

<table>
<tr>
<td width="50%" valign="top">

### 给剪贴板，多一点记忆。

按内容类型、来源应用和日期筛选，先看完整预览，再复制使用。

<a href="res/screenshots/macos-history-en.png"><img src="res/screenshots/macos-history-showcase.webp" alt="剪贴板历史：搜索列表与完整内容预览" width="560" /></a>

</td>
<td width="50%" valign="top">

### 写过的好内容，值得再用一次。

左边选文件夹，中间找片段，右边编辑正文。查找、修改和复制，在同一处完成。

<a href="res/screenshots/macos-snippets-en.png"><img src="res/screenshots/macos-snippets-showcase.webp" alt="三栏片段库：文件夹、搜索与正文编辑器" width="560" /></a>

</td>
</tr>
</table>

**看到的灵感，也能留下。** 在 Mac 上截图、标注、OCR 提取文字，或直接贴到屏幕上。还有滚动长截图、录屏和单词查询。[看看这些工具 ↓](#完整功能说明)

## 在 Android 上，也很顺手

重新设计的 **历史 · 设备 · 通知 · 设置** 四个入口。搜索保存的内容，选择要共享的设备，自由切换浅色、深色和系统外观。短动效衔接页面，保留浏览位置，复制完成后给出明确反馈。

<p align="center">
  <a href="res/screenshots/android-history-en.png"><img src="res/screenshots/android-history-en.png" alt="Android 剪贴板历史：搜索、类型筛选和分组内容卡片" width="30%" /></a>&nbsp;
  <a href="res/screenshots/android-devices-en.png"><img src="res/screenshots/android-devices-en.png" alt="Android 设备页：局域网同步与连接设置" width="30%" /></a>&nbsp;
  <a href="res/screenshots/android-settings-dark-en.png"><img src="res/screenshots/android-settings-dark-en.png" alt="Android 深色外观下的设置页面" width="30%" /></a>
</p>

<sub>Android 展示当前工作区源码，以上 v1.0.18 下载包尚不包含本次改版；截图来自使用虚构数据的独立模拟器。Mac 美化展示图可点击查看原始捕获，顶部为概念插画。[图片来源与制作说明](res/screenshots/README.md)</sub>

<details>
<summary><b>再看一个细节：顺着浏览习惯的偏好设置</b></summary>

连续滚动浏览 Mac 设置，也可从侧边栏直接跳到对应分类。

<a href="res/screenshots/macos-preferences-en.png"><img src="res/screenshots/macos-preferences-showcase.webp" alt="Mac 偏好设置：连续滚动与侧边分类导航" width="920" /></a>

</details>

## 三步开始使用

1. **安装 Clipy。** Mac 解压后移入「应用程序」，Android 安装 APK。Mac 端入口在菜单栏。详见[安装指南](docs/GETTING_STARTED_ZH.md)与 [macOS 首次启动说明](docs/MACOS_INSTALL.md)。
2. **复制一段想留下的内容。** Android 首次测试时保持 Clipy 打开；在 Mac 上按 <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>F</kbd> 搜索历史。
3. **连接你的设备。** 连到同一个可信 Wi-Fi，设置相同的私有配对密钥，再开启向目标设备的共享。[按步骤连接](docs/GETTING_STARTED_ZH.md#连接-mac-与-android)。

**[安装与常见问题](docs/GETTING_STARTED_ZH.md)** · **[反馈问题](https://github.com/JunWeiUp/Clipy/issues/new?template=bug_report.yml)** · **[建议新功能](https://github.com/JunWeiUp/Clipy/issues/new?template=feature_request.yml)**

> **开始共享前：** 同步面向可信局域网，请设置足够强的私有配对密钥，并了解[安全边界](SECURITY.md)。macshot 截图移植模块仍需完成[第三方许可核对](THIRD_PARTY_NOTICES.md)，不能将整个组合应用直接视为仅受 MIT 许可约束。

<details>
<summary><b>版本、下载与源码构建</b></summary>

当前源码版本：**1.0.18** · 默认本地构建号 **10060** · [构建版本配置](clipy_android/pubspec.yaml)

最新公开发布版本为 [v1.0.18](https://github.com/JunWeiUp/Clipy/releases/tag/v1.0.18)，构建号 **10078**。源码截图可能包含尚未提交的新改动；Release 徽章只显示公开版本，不包含草稿。旧版升级请阅读[同步版本差异](docs/GETTING_STARTED_ZH.md#同步版本差异)。

</details>

## 完整功能说明

<details>
<summary><b>展开剪贴板、截图、同步与通知功能</b></summary>

### 📋 剪贴板历史
- 自动捕获**文本、RTF、HTML、PDF、图片、文件**。
- **SHA-256 去重** —— 重复复制会把内容重新置顶，而不是重复堆积。
- **文件感知** —— 显示源文件路径，并支持在 Finder 中定位。
- 可按 bundle id **排除指定 App**（密码管理器、钥匙串等）。
- 历史条数可配，菜单懒加载，内存占用极低。
- 历史媒体文件可选**静态加密**（密钥保存在仅所有者可读写的本地文件中，详见[安全说明](SECURITY.md)）。

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

### 📖 单词查询（macOS）
- 从剪贴板菜单栏进入，或按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> 打开；可在偏好设置中修改或关闭快捷键。
- 输入英文单词或短语，查看中文释义、词性、美式音标、词形变化、相关短语与双语例句；点击短语可继续查询。
- 支持美式发音播放；词典音频不可用时使用已安装的系统美式英语语音。词典缺少音标、短语或例句时会明确提示。
- 打开窗口时，若剪贴板内容是单个英文单词，会自动填入并聚焦输入框，按回车即可查询；句子、网址、文件和多个单词不会自动填入。仅在确认提交后联网查询有道词典，不保留查询历史；关闭窗口即取消请求、停止发音并释放结果。
- 使用无需 API Key 的有道网页词典接口，非有版本保障的公开 API，接口可能变化或暂时不可用；结果附词典来源链接。

### 🔄 加密局域网同步
- macOS 与 Android 之间全程 **AES-GCM 256 位**加密传输。
- 设备通过 **/24 子网扫描** 与 **手动 IP:端口** 互相发现（可跨 2.4G/5G 子网）—— 无需云端、无需账号。
- 剪贴板历史可靠投递（ack + 离线队列）。
- 稳健可靠：**离线对端队列**会在设备短暂断网后自动重投。
- 通过内容哈希**防止环路**，复制内容不会在设备间无限弹跳。

### 🔔 手机通知镜像（Android → macOS）
- 在 Mac 上直接查看 Android 手机的通知。
- **双向** dismiss 与一键清除；支持按 App **白名单**过滤。

### macOS 界面
- 原生标题栏、清晰的浅色/深色内容背景，以及统一的 SF Symbols、间距与控件样式。
- 紧凑菜单栏提供常用工具和最近六条复制内容；较早历史、片段与设备收纳到子菜单。
- 偏好设置与截图设置可连续滚动浏览各类选项，侧边分类随滚动高亮，也支持点击跳转。界面开发规范见 [macOS 设计标准](docs/MACOS_DESIGN.md)。

### ⌨️ 全局快捷键 与 🌍 国际化
- 搜索、单词查询、截图、每个片段均可绑定快捷键。
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

macOS、Android 和 iOS 的应用图标使用同一份设计母版。更新各平台尺寸及 README 标志的方法见[图标资源与导出说明](assets/branding/README.md)。

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

**在 GitHub 打包：**打开 [Actions → macOS Build](https://github.com/JunWeiUp/Clipy/actions/workflows/macos.yml)，点击 **Run workflow**，即可单独构建 Mac 应用，无需签名密钥或 Android 配置。推送到 `main`/`master` 和提交 PR 时，CI 也会调用同一 Mac 任务。

Mac 任务成功后，从运行摘要下载 artifact（需登录 GitHub，保留 30 天），内含 **Apple Silicon / macOS 13+** 应用 ZIP、调试符号 ZIP、SHA-256 校验文件和安装说明。

这些是临时签名的开发构建，不代表已正式发布；首次打开的「**隐私与安全 → 仍要打开**」操作和更新后授权说明见[安装指南](docs/MACOS_INSTALL.md)。版本标签仍创建现有双端 Release 草稿。

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

已发布的 v1.0.18 安装包使用构建号 **10078**（源码构建号 10060 + Release 运行序号 18）。如需用本地构建覆盖该 Android APK，须保留相同签名密钥，并显式设置更高的 `BUILD_NUMBER`；默认本地构建号并不是已发布安装包的构建号。

在仓库根目录运行 `bash scripts/check.sh all` 可执行质量检查。macOS 上还需运行 `bash scripts/test_macos_core.sh`，验证搜索、单词查询与 socket 回归用例；它使用临时测试程序，不安装或启动应用。

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

工作流明确设置了 `draft: true`，所以构建成功不会自动公开发布，也不会自动成为 Latest。审核完成后，在 GitHub 编辑草稿，不勾选 **This is a pre-release**，勾选 **Set as latest release**，再点击 **Publish release**，无需重新构建或覆盖标签。正式发布后，再同步更新中英文 README 和两份入门指南中的已发布版本及下载链接。详见 [GitHub 发布说明](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)。

可使用[更新说明模板](docs/RELEASE_NOTES_TEMPLATE.md)，说明用户可见的变化、升级步骤与实际提供的平台版本。

## 📄 许可证

仓库目前保留 [MIT License](LICENSE) 文本，但 macshot 移植模块仍需单独核对许可与来源，不能将整个组合应用直接视为仅受 MIT 许可约束。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=JunWeiUp/Clipy&type=Date)](https://star-history.com/#JunWeiUp/Clipy&Date)

---

<div align="center">

如果 Clipy 帮到了你，欢迎给个 ⭐ —— 这能让更多人发现这个项目！

</div>
