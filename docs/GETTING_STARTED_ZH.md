# 开始使用 Clipy

[English](GETTING_STARTED.md) · **简体中文** · [返回项目](../README_ZH.md)

## 下载与版本

打开[最新正式版](https://github.com/JunWeiUp/Clipy/releases/latest)（当前为 [v1.0.29](https://github.com/JunWeiUp/Clipy/releases/tag/v1.0.29)），按设备选择对应附件。最新正式版入口随公开发布自动更新，不包含草稿；具体应用版本和构建号以发布说明为准。

| 设备 | 发布页中的附件名称 |
| --- | --- |
| Apple Silicon Mac，macOS 13+ | `ClipyClone-macOS-v<version>.zip` |
| Android，arm64 | `ClipyClone-Android-arm64-v8a-v<version>.apk` |
| Windows 10/11 x64（从 v1.0.23 起） | `ClipyClone-Windows-x64-v<version>.zip` |

正式版只上传这三个安装包；GitHub 会在每个附件旁显示 SHA-256 摘要，并另行自动生成源码压缩包。当前本地源码为 **v1.0.30**，默认构建号 **10221**；CI 会再加上工作流运行序号。如需用本地构建覆盖正式 APK，应使用相同签名密钥和高于已安装包的构建号，不要在未备份数据时卸载应用。

macOS ZIP 中是 **arm64** 应用，不是 Intel 或通用架构版本。Android 正式版 APK 仅面向 arm64，本地构建脚本仍可生成 32 位 APK。更早的公开版本可能没有 Windows 附件。iOS 没有公开安装包，CI 仅构建无签名源码。开发版构建方法见[开发指南](DEVELOPMENT.md)。

## 安装并试用剪贴板历史

1. **Mac：**解压下载文件，把 `ClipyClone.app` 移到「应用程序」并打开。入口在菜单栏，不显示 Dock 图标。替换旧版前先退出运行中的应用。**Android：**选择对应架构的 APK，按安装程序提示授予本次安装所需的权限。
2. 在 Mac 复制 `Hello from Clipy` 这样的无敏感信息测试文字，打开菜单栏应用，再按 **⇧⌘F** 搜索。先体验本地历史时，保持局域网同步关闭即可。
3. 使用对应功能时再授予权限：macOS 的**辅助功能**用于模拟粘贴，**屏幕录制**用于截图，系统提示的**本地网络**权限用于同步。Android 的通知读取权限用于通知镜像，体验 Mac 本地历史不需要先配置它。

### macOS 首次启动被拦截怎么办？

项目当前的构建流程没有完成应用公证。核对下载来源，并根据具体提示查看 [Apple 官方说明](https://support.apple.com/en-us/102445)。对于无法验证开发者的提示，在确认信任该应用后，可按 Apple 指引使用「系统设置 → 隐私与安全性 → 仍要打开」为该应用单独放行。损坏或恶意软件警告属于其他情况，不要套用同一处理方式，也无需全局关闭系统保护。

## 同步版本差异

当前源码使用无需配对的协议 v3；v1.0.25 及更早版本使用 v2。两端须一起升级到 v3 构建，旧版会显示版本不兼容。默认 AES-GCM 密钥内置于应用，旧配对码不再使用；安全边界见[安全说明](../SECURITY.md)。

macOS 包含修改过的 macshot 代码，按 [GPLv3](../LICENSE.GPL-3.0) 分发；Clipy 自有代码仍采用 [MIT](../LICENSE)。详见[来源与源码获取方式](../THIRD_PARTY_NOTICES.md)。

## 连接 Mac 与 Android

1. 两台设备连接可信局域网，首次测试时保持两端应用打开，尽量使用相同版本。
2. 两端启用局域网同步并刷新设备列表，无需设置配对码。设备页可直接发送文本或文件。
3. 启用局域网同步，在各自的设备列表中，打开向目标设备共享剪贴板的开关。这是发送方向的设置，需要双向自动共享时，两端都要配置。通知共享是独立选项。
4. 在 Mac 复制无敏感信息的测试文字，到 Android 历史中检查。测试反向传输时，保持 Android 应用在前台，按需使用应用内的剪贴板导入操作，再查看 Mac 历史。Android 后台剪贴板捕获会受到系统版本和设备权限限制。

### 找不到另一台设备

确认两端都启用了同步、监听端口相同（默认 **5566**），且设备之间可以互访。访客 Wi-Fi 可能隔离设备，VPN 路由或防火墙也可能影响本地连接。如果设备可达但扫描遗漏，可在应用中手动添加 **IP:端口**。连接不同 Wi-Fi 频段本身，不能说明两台设备是否互通。

### 能看到设备，但文字没有传过去

主动发送无需共享开关；自动同步先检查**发送端**的剪贴板共享开关。确认两端都运行协议 v3 构建；旧版需要升级。保持两端应用可见，再用无敏感信息的文字测试。Android 通知权限影响的是通知镜像，应与剪贴板共享分别排查。

### 怎么切换语言？

在应用设置中选择 English 或简体中文。GitHub README 的语言入口只切换文档，不会改变应用设置。

## 反馈问题

[提交问题](https://github.com/JunWeiUp/Clipy/issues/new?template=bug_report.yml)或[建议功能](https://github.com/JunWeiUp/Clipy/issues/new?template=feature_request.yml)时，说明应用版本、系统版本、发送与接收设备，以及已尝试的步骤。分享诊断信息前，请移除剪贴板内容、配对密钥、通知、账号和局域网地址。安全问题请按[安全说明](../SECURITY.md)中的流程反馈。

如果 Clipy 帮到了你，欢迎在 [GitHub 点个 Star](https://github.com/JunWeiUp/Clipy)，让更多人发现它。
