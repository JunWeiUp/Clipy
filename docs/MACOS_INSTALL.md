# macOS installation / macOS 安装

These builds use **ad-hoc signing** and are **not notarized by Apple**. No Apple
Developer account or signing certificate is needed to build or install them.
They support **Apple Silicon (M-series), macOS 13+**; Intel Macs are not supported
by these packages.

1. For Actions downloads, sign in to GitHub, download the artifact and extract it.
   Then unzip the application ZIP, not the `-symbols.zip` archive. `BUILD.txt`
   identifies the version, build, architecture and source commit.
2. Quit any running copy of Clipy. Move `ClipyClone.app` to **Applications**, then
   open it. Clipy appears in the menu bar, with no Dock icon.
3. If macOS blocks it because the developer or app cannot be verified, and you
   trust the download, go to **System Settings → Privacy & Security → Open Anyway**
   after the first launch attempt. Follow [Apple's instructions](https://support.apple.com/en-us/102445)
   for your actual alert; managed Macs may restrict this exception.
4. Grant **Accessibility** for simulated paste and **Screen Recording** for
   screenshots/recording when using those features. Ad-hoc updates may require
   granting these permissions again because the app's signing identity changes.

Optional integrity check: in the extracted artifact directory, run
`shasum -a 256 -c SHA256SUMS.txt`. Keep the symbols ZIP when reporting a crash.

这些构建使用 **ad-hoc 临时签名**，**未经过 Apple 公证**。构建或安装均不需要 Apple
开发者账号或签名证书。支持 **Apple Silicon（M 系列）、macOS 13+**；这些包不支持 Intel Mac。

1. 从 Actions 下载时，先登录 GitHub，下载并解压 artifact，再解压其中的应用 ZIP，
   不要选 `-symbols.zip`。`BUILD.txt` 记录版本、构建号、架构和源码提交。
2. 退出正在运行的 Clipy，将 `ClipyClone.app` 移到「**应用程序**」后打开。
   应用入口在菜单栏，不显示 Dock 图标。
3. 首次打开若提示无法验证开发者或应用，确认信任下载来源后，进入
   「**系统设置 → 隐私与安全 → 仍要打开**」并确认。具体提示以
   [Apple 官方指引](https://support.apple.com/zh-cn/102445)为准；受管理的 Mac 可能限制此操作。
4. 使用对应功能时，为模拟粘贴授予「**辅助功能**」，为截图/录屏授予「**屏幕录制**」。
   临时签名更新后身份会变化，可能需要重新授予这些权限。

可在解压后的 artifact 目录运行 `shasum -a 256 -c SHA256SUMS.txt` 校验下载文件。
反馈崩溃时，请保留同次构建的 symbols ZIP。
