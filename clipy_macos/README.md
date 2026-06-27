# Clipy macOS (Rust + GPUI)

macOS 剪贴板管理器，基于 Rust 与 [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) 重写，参考 [Ropy](https://github.com/StudentWeis/ropy) 架构。

## 功能

- 托盘 Agent + 全局热键（默认 `Cmd+Shift+V`）弹出历史面板
- 剪贴板历史：文本 / 图片 / 文件 / 富文本，去重后重插并保留 Pin/用量
- 搜索与过滤（DSL：`type:image app:Chrome pin` 等）
- 片段管理、传输站、Android 通知镜像、Device Collector
- LAN 同步（`_clipy-sync._tcp`，与现有 Android 端协议兼容）

## 构建

需要 Rust stable、Xcode（含 Metal Toolchain）：

```bash
# 若 GPUI Metal 编译失败，先安装 Metal 工具链
xcodebuild -downloadComponent MetalToolchain

cd clipy_macos
cargo build --release
./scripts/build_app.sh
```

产物：`clipy_macos/Clipy.app`

## 数据目录

`~/Library/Application Support/ClipyClone/`（与 Swift 版共用，支持从 `history_v2.json` 迁移）

## 配置

`~/Library/Application Support/ClipyClone/config.toml`
