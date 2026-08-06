# 删除手机采集功能（保留通知同步）设计

**日期：** 2026-07-15  
**状态：** 待用户确认  
**决策：** 方案 A — 彻底删除采集，通知改走专用协议

## 背景

Clipy 当前有两套相关能力：

1. **手机采集（Collector）**：Android 前台服务采集短信/通话/通话记录/位置/系统等，经 `collector/event` 同步到 macOS，在「手机采集」窗口展示。
2. **通知同步（Notification Sync）**：Android 通知监听同步到 macOS「通知同步」窗口。

现状耦合点：Android 通知实际上通过 `CollectorEvent` + `collector/event` 上报，macOS 的 `DeviceCollectorManager` 再桥接到 `NotificationManager`。删除采集时必须先解耦，否则通知同步会断。

## 目标

- 删除手机采集（短信/通话/通话记录/剪贴板采集通道/位置/系统）的全部功能、UI、权限与存储。
- **完整保留**通知同步。
- 剪贴板历史同步（`text/plain` 等）不受影响。

## 非目标

- 不改动截图（Screenshot / ScreenCapture）功能。
- 不做采集数据迁移或导出。
- 不保留对旧版 `collector/event` 的兼容接收（删除后直接忽略/移除 handler）。

## 架构变更

### 通知传输解耦（关键路径）

| 方向 | 现状 | 目标 |
|------|------|------|
| Android → Mac 通知上报 | `collector/event` + `CollectorEvent` JSON | `notification/post` + `NotificationEntry` JSON |
| dismiss / clear_all / config | 已是 `notification/*` | 不变 |
| Mac 接收通知 | `DeviceCollectorManager` 桥接 + `notification/post` | 仅 `NotificationManager` 处理 `notification/post` |

Android 改动点：`NotificationManager._broadcastToSync` 改为调用已有的 `SyncManager.broadcastNotificationMessage(type: 'notification/post', ...)`，内容为 `NotificationEntry.toJson()`。

### UI

**Android**

- 移除底部「采集」Tab。
- 底部导航变为：历史 + 设置（若现有还有其它固定入口则保持）。
- 「通知同步」保留现有独立入口（如设置/工具栏中的入口与 `NotificationSyncPage`）。
- 删除 `CollectorPage` 及其子页（status / events / permissions）。

**macOS**

- 移除菜单「手机采集」及 `CollectorWindow` / `CollectorView`。
- 保留「通知同步」菜单与窗口。
- Settings 移除采集相关 Toggle；保留通知同步相关开关。

## 删除清单

### Android — 删除文件

- `lib/collector_manager.dart`
- `lib/collector_page.dart`
- `lib/collector_events_page.dart`
- `lib/collector_status_page.dart`
- `lib/collector_permissions_page.dart`
- `lib/database/collector_repository.dart`
- `android/.../CollectorForegroundService.kt`
- `android/.../CollectorEventBridge.kt`
- `android/.../SmsReceiver.kt`
- `android/.../SmsContentObserver.kt`
- `android/.../CallStateReceiver.kt`
- `android/.../CallLogObserver.kt`

### Android — 修改

- `lib/main.dart`：去掉采集 Tab、采集 init、采集设置项
- `lib/notification_manager.dart`：改用 `notification/post` 广播；去掉对 `CollectorEvent` 依赖
- `lib/models.dart`：删除 `CollectorEvent` / `CollectorCategories`（及 `toCollectorPayload` 若仅服务采集）
- `lib/sync_manager.dart`：删除 `broadcastCollectorEvent` 与 `collector/event` 处理
- `lib/clipboard_manager.dart`：删除 `collectorClipboardOnly`
- `lib/database/app_database.dart` / `legacy_migration.dart`：去掉 collector 表创建与迁移导入（或保留表但不读写，优先删除 schema 创建逻辑）
- `lib/notification_health_monitor.dart`：去掉对 `CollectorManager` / 采集类别的依赖
- `lib/app_localizations.dart`：删除采集文案
- `AndroidManifest.xml`：删除 SMS/电话/通话记录权限与 `CollectorForegroundService` 声明
- `MainActivity.kt`：删除 collector MethodChannel / 启停服务逻辑
- `BootReceiver.kt`：删除启动采集服务逻辑（若 BootReceiver 仅服务采集则整文件删除）
- `FlutterPrefs.kt`：清理仅采集使用的 prefs 键（可选）

### macOS — 删除文件

- `DeviceCollectorManager.swift`
- `DeviceCollectorRepository.swift`
- `DeviceCollectorTypes.swift`
- `CollectorWindow.swift`
- `UI/CollectorView.swift`

### macOS — 修改

- `MenuController.swift`：移除采集菜单项与窗口
- `SyncManager.swift`：移除 `collector/event` case
- `PreferencesManager.swift`：移除采集 prefs
- `UI/SettingsView.swift`：移除采集 Toggle 区块
- `Localization.swift`：移除采集文案
- `AppDatabase.swift`：移除 `collector_events` 表相关（若存在）
- Xcode / Package 源文件列表：确保上述文件不再被编译（若为 SPM 自动收录则删文件即可）

### 文档

- `README.md` / `AGENTS.md`：去掉采集描述；保留通知同步说明
- `Kim_AGENTS.md`：记录本次变更上下文

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 通知同步因协议切换中断 | 先改 Android 广播为 `notification/post`，再删 Mac 桥接；两端均已有 `notification/post` handler |
| 残留危险权限 | Manifest 明确删除 SMS/通话相关权限 |
| 旧设备仍发 `collector/event` | Mac 删除 handler 后忽略；可接受（用户确认不兼容旧协议） |
| `notification_health_*` 依赖采集状态 | 改为仅依赖 `NotificationManager` |

## 验收标准

1. Android 无「采集」Tab / 采集设置 / 采集前台服务。
2. Android 不再请求或声明 SMS/通话相关权限。
3. 通知同步：手机通知仍可出现在 Mac「通知同步」窗口，dismiss/clear 仍可用。
4. macOS 菜单无「手机采集」；设置无采集开关。
5. 剪贴板历史同步、截图功能行为不变。
6. 工程可编译（不要求本次跑 simulator）。

## Self-review

- [x] 无 TBD / 占位符
- [x] 目标与非目标清晰；与「保留通知同步」一致
- [x] 协议解耦路径明确，避免删采集后通知断链
- [x] 删除/修改文件清单覆盖两端
- [x] 范围不含截图与剪贴板历史同步
