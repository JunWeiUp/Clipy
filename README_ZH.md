# Clipy

一个适用于 macOS 和 Android 的跨平台剪贴板管理与同步工具。

## 功能特性

- **剪贴板历史**: 自动监控并保存您的剪贴板历史记录。
- **跨平台同步**: 在同一局域网内的 macOS 和 Android 设备之间同步剪贴板数据。
- **局域网文件传输**: 在设备间直接发送文件，macOS 支持悬停菜单操作，Android 支持实时进度追踪。
- **片段管理**: 管理并快速访问常用的文本片段或代码块。
- **安全通信**: 所有通过网络传输的数据均使用 AES-GCM 256 位加密。
- **实时日志**: 内置日志查看器，用于监控同步状态和调试。
- **自定义设备名称**: 为每台设备设置唯一名称，以便在同步时轻松识别。

## 项目架构

### macOS 应用 (Swift/AppKit)
- 原生实现，确保性能和系统集成度。
- 使用 SwiftUI 构建现代化的日志窗口界面。
- 利用苹果的 `Network` 框架实现可靠的 mDNS 服务发现和 TCP 通信。

### Android 应用 (Flutter/Dart)
- 使用 Flutter 实现跨平台移动客户端。
- 使用 `nsd` 进行 mDNS 服务发现，使用原生 `Socket` 进行 TCP 通信。
- 支持 IPv4 和 IPv6，确保最佳兼容性。

## 同步协议

Clipy 使用自定义的基于 TCP 的协议进行同步和文件传输：
- **服务发现**: 设备通过 mDNS 互相发现。
- **协议格式**: `[4字节大端序长度前缀] + [加密的 JSON 数据]`
- **文件传输**: 支持分块传输（512KB 分块），包含元数据头信息和实时进度反馈。
- **加密方式**: AES-GCM 256 位，使用预共享密钥。
- **环路防止**: 使用 `lastSyncHash` 校验机制防止设备间产生同步环路。

## 快速入门

### macOS
构建 macOS 应用：
1. 确保已安装 Xcode。
2. 运行构建脚本：
   ```bash
   ./build_app.sh
   ```
3. 生成的应用位于 `ClipyClone.app`。

### Android
构建 Android 应用：
1. 确保已安装 Flutter SDK 和 Android SDK。
2. 进入 `clipy_android` 目录：
   ```bash
   cd clipy_android
   ```
3. 运行 Flutter 构建命令：
   ```bash
   flutter build apk --debug
   ```

## 开发相关

- **macOS 源码**: 位于 `Sources/` 目录。
- **Android 源码**: 位于 `clipy_android/lib/` 目录。
- **任务日志**: 了解项目的详细开发历史。

## 许可证

内部项目。
