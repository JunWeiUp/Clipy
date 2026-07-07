# Clipy macOS (Swift + AppKit)

macOS 剪贴板管理器，基于 Swift 与 AppKit 构建的菜单栏应用。

## 构建

要求：已安装 Xcode 命令行工具。

```bash
./build_macos_app.sh
```

产物：`clipy_macos/ClipyClone.app`

也可在 `clipy_macos` 目录执行 `./build_macos_app.sh`（会转发到仓库根目录）。

## 源码结构

- `Sources/`：Swift 源码
- `../build_macos_app.sh`：应用包构建脚本（仓库根目录）
