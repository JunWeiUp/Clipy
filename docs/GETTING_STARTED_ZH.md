# 开始使用 Clipy

[English](GETTING_STARTED.md) · **简体中文** · [返回项目](../README_ZH.md)

## 下载与版本

以下链接对应 **2026 年 8 月 5 日发布的 v1.0.15**，不会自动切换到未来版本。新版本及更新说明请查看[全部发布](https://github.com/JunWeiUp/Clipy/releases)。

| 设备 | 下载 |
| --- | --- |
| Apple Silicon Mac，macOS 13+ | [macOS ZIP](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.15/ClipyClone-macOS-v1.0.15.zip) |
| Android，arm64 | [64 位 APK](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.15/ClipyClone-Android-arm64-v8a-v1.0.15.apk) |
| Android，armeabi-v7a | [32 位 APK](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.15/ClipyClone-Android-armeabi-v7a-v1.0.15.apk) |

macOS ZIP 中是 **arm64** 应用，不是 Intel 或通用架构版本。本次发布没有 iOS 安装包，iOS 源码目标仍为实验性。开发版构建方法见[开发指南](DEVELOPMENT.md)。

## 安装并试用剪贴板历史

1. **Mac：**解压下载文件，把 `ClipyClone.app` 移到「应用程序」并打开。入口在菜单栏，不显示 Dock 图标。替换旧版前先退出运行中的应用。**Android：**选择对应架构的 APK，按安装程序提示授予本次安装所需的权限。
2. 在 Mac 复制 `Hello from Clipy` 这样的无敏感信息测试文字，打开菜单栏应用，再按 **⇧⌘F** 搜索。先体验本地历史时，保持局域网同步关闭即可。
3. 使用对应功能时再授予权限：macOS 的**辅助功能**用于模拟粘贴，**屏幕录制**用于截图，系统提示的**本地网络**权限用于同步。Android 的通知读取权限用于通知镜像，体验 Mac 本地历史不需要先配置它。

### macOS 首次启动被拦截怎么办？

项目当前的构建流程没有完成应用公证。核对下载来源，并根据具体提示查看 [Apple 官方说明](https://support.apple.com/en-us/102445)。对于无法验证开发者的提示，在确认信任该应用后，可按 Apple 指引使用「系统设置 → 隐私与安全性 → 仍要打开」为该应用单独放行。损坏或恶意软件警告属于其他情况，不要套用同一处理方式，也无需全局关闭系统保护。

## 同步版本差异

当前 `master` 源码与可下载的 v1.0.15 并不相同：

| 版本 | 配对行为 |
| --- | --- |
| 已发布的 v1.0.15 | 使用公开的兼容密钥，界面没有私有配对密钥设置；无法对已知该密钥的人提供保密性。 |
| 当前开发分支 | 已提供私有配对密钥设置。两端需配置相同、足够强且非空的私有值；留空仍会使用兼容模式。 |

同步面向可信局域网。用 v1.0.15 试用同步时，请只使用无敏感信息的示例文字，不要同步密码等秘密。开发版的私有密钥也不等于经过认证的设备身份，无法消除所有协议限制。启用前请阅读[安全说明](../SECURITY.md)。

新组合版 macOS 应用发布前还需完成已有的[第三方许可核对](../THIRD_PARTY_NOTICES.md)。本指南没有把开发分支描述为已发布的新版本。

## 连接 Mac 与 Android

1. 两台设备连接可信局域网，首次测试时保持两端应用打开，尽量使用相同版本。
2. 如果使用设置中带有「配对密钥」的开发版，先在两端保存相同、足够强的私有值，再启用局域网同步。v1.0.15 没有这个选项，请按上面的限制使用；不要把私有密钥模式与不支持该密钥的旧版混用。
3. 启用局域网同步，在各自的设备列表中，打开向目标设备共享剪贴板的开关。这是发送方向的设置，需要双向自动共享时，两端都要配置。通知共享是独立选项。
4. 在 Mac 复制无敏感信息的测试文字，到 Android 历史中检查。测试反向传输时，保持 Android 应用在前台，按需使用应用内的剪贴板导入操作，再查看 Mac 历史。Android 后台剪贴板捕获会受到系统版本和设备权限限制。

### 找不到另一台设备

确认两端都启用了同步、监听端口相同（默认 **5566**），且设备之间可以互访。访客 Wi-Fi 可能隔离设备，VPN 路由或防火墙也可能影响本地连接。如果设备可达但扫描遗漏，可在应用中手动添加 **IP:端口**。连接不同 Wi-Fi 频段本身，不能说明两台设备是否互通。

### 能看到设备，但文字没有传过去

先检查**发送端**是否打开了向目标设备共享剪贴板的开关。开发版还要确认两端配对密钥一致。保持两端应用可见，再用无敏感信息的文字测试。Android 通知权限影响的是通知镜像，应与剪贴板共享分别排查。

### 怎么切换语言？

在应用设置中选择 English 或简体中文。GitHub README 的语言入口只切换文档，不会改变应用设置。

## 反馈问题

[提交问题](https://github.com/JunWeiUp/Clipy/issues/new?template=bug_report.yml)或[建议功能](https://github.com/JunWeiUp/Clipy/issues/new?template=feature_request.yml)时，说明应用版本、系统版本、发送与接收设备，以及已尝试的步骤。分享诊断信息前，请移除剪贴板内容、配对密钥、通知、账号和局域网地址。安全问题请按[安全说明](../SECURITY.md)中的流程反馈。

如果 Clipy 帮到了你，欢迎在 [GitHub 点个 Star](https://github.com/JunWeiUp/Clipy)，让更多人发现它。
