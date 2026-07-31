# Android 端：按需发现 + endpoint 持久化（省电方案收尾）

## 背景
父计划 [`on-demand-discovery-power-saving.md`](./on-demand-discovery-power-saving.md) 已批准，**Mac 端全部完成并 typecheck 通过**：
- `SyncManager.swift`：新增 `endpointCacheKey`/`loadPersistedPeerEndpoints`/`persistPeerEndpoints`/`removePersistedPeerEndpoint`（行 144/664/691/703），删除 `rescanTimer`/`startRescanTimer`，`start()` 调用 `loadPersistedPeerEndpoints()`（行 503），驱逐路径调用 `removePersistedPeerEndpoint`（行 804），`recordDiscoveredPeer` 调用 `persistPeerEndpoints`（行 1507），`peerLivenessInterval` 已降频到 120s。
- `MenuController.swift`：`refreshMenuForOpen`（行 142）已在行 150 追加 `SyncManager.shared.triggerCrossBandDiscovery()`。

**本计划仅覆盖 Android 端剩余对称实现**，与 Mac 端一一对应。

## 当前状态分析（已探索确认）
- `clipy_android/lib/sync_manager.dart`：
  - `DiscoveredPeer`（行 125-138）字段 `peerId`/`displayName`/`host`/`port`。
  - `_discoveredPeers` Map（行 152），`_peerMissCounts` Map（行 173）。
  - `_peerLivenessInterval = Duration(seconds: 45)`（行 193），`_peerLivenessMaxMisses = 3`（行 194）。
  - `port = 5566` 默认（行 205）。
  - `init()` 行 235，已用 `SharedPreferences`（行 236）；末尾在 `isEnabled` 时调用 `start()`（行 253-255），**未加载缓存 endpoint**。
  - `_recordDiscoveredPeer`（行 836）成功后只更新内存 Map + flush pendingQueue，**未持久化**。
  - `_recordPeerMiss`（行 455-472）：达到 3 次 miss 后从 `_discoveredPeers` 移除并广播，**未移除持久化、未触发回退扫描**。
  - `triggerCrossBandDiscovery`（行 867）已做 400ms 防抖，内部 `_connectManualPeers` + `_scanSubnets`。
  - `start()`（行 507-523）已触发一次 `triggerCrossBandDiscovery`（启动扫描保留）。
  - **无独立的周期性全 /24 重扫定时器**（Mac 的 `rescanTimer` 在 Android 不存在），故无需删除。
- `clipy_android/lib/main.dart`：三个目标 initState 均存在，目前均不触发扫描：
  - `SyncTargetDeviceList._SyncTargetDeviceListState.initState`（行 142）
  - `MacSettingsTab._MacSettingsTabState.initState`（行 691）
  - `SettingsPage._SettingsPageState.initState`（行 1296）
  - 唯一既有的 `triggerCrossBandDiscovery()` 调用在行 344（手动刷新按钮），与本计划无关。

## 改动方案

### 一、新增 endpoint 持久化（对称 Mac UserDefaults → Android SharedPreferences）
**文件**：`clipy_android/lib/sync_manager.dart`

- 新增私有常量与 TTL（紧邻 `_peerLivenessMaxMisses` 行 194 之后）：
  ```dart
  /// Persisted cache of discovered peer endpoints (peerId → {host,port,name,ts}).
  /// Loaded in init() so data transfer works immediately after launch without
  /// waiting for a subnet scan. The full /24 rescan was removed to save power;
  /// discovery is on-demand (UI open / endpoint-failure fallback). Entries
  /// expire after _endpointCacheTtl. Keep aligned with macOS side.
  static const String _endpointCacheKey = 'peerEndpoints';
  static const Duration _endpointCacheTtl = Duration(hours: 24);
  ```
- 新增方法 `_loadPersistedPeerEndpoints()`（异步）：从 `SharedPreferences` 读取 key=`peerEndpoints` 的 JSON 字符串，反序列化为 `Map<String, Map<String, dynamic>>`；过滤 `ts` 早于 `now - _endpointCacheTtl` 的条目；对每个有效条目构造 `DiscoveredPeer` 并在 `_discoveredPeers[peerId] == null` 时填入（同时 `_peerMissCounts[peerId] = 0`）；加载到则 `_notifyPeersChanged()`。
- 新增方法 `_persistPeerEndpoints()`（异步）：快照 `availablePeers`，序列化为 `Map<peerId, {host,port,name,ts: now}>` → JSON 字符串 → `prefs.setString(_endpointCacheKey, ...)`。
- 新增方法 `_removePersistedPeerEndpoint(String peerId)`（异步）：读出 JSON Map → `remove(peerId)` → 写回；若 Map 已为空则 `prefs.remove(_endpointCacheKey)`。
- 序列化用 `dart:convert` 的 `jsonEncode`/`jsonDecode`（项目已使用，行 825 `_handleHandshakeHi` 即用 `jsonDecode`）。`ts` 以 ISO-8601 字符串（`DateTime.toIso8601String()` / `DateTime.parse`）存储。

**调用点**：
1. `init()` 末尾（行 255 之后、`if (isEnabled) start()` 之前或之后均可，建议在 `start()` 之前以便首屏列表即时展示）：追加 `await _loadPersistedPeerEndpoints();`。
2. `_recordDiscoveredPeer`（行 848 `_notifyPeersChanged();` 之后）：追加 `unawaited(_persistPeerEndpoints());`（异步不阻塞握手路径）。
3. `_recordPeerMiss` 驱逐路径（行 464 `_discoveredPeers.remove(peerId);` 之后）：追加 `unawaited(_removePersistedPeerEndpoint(peerId));`。

### 二、探活降频 45s → 120s（对称 Mac）
**文件**：`clipy_android/lib/sync_manager.dart` 行 193
- 改 `_peerLivenessInterval = Duration(seconds: 45);` → `Duration(seconds: 120);`。
- 顺带更新行 191-192 的注释，说明 120s × 3 ≈ 6 min grace window，可吸收 Doze / Wi-Fi 漫游 / AppNap（Android 端无 AppNap，但保留对齐注释）。

### 三、驱逐路径回退扫描（对称 Mac）
**文件**：`clipy_android/lib/sync_manager.dart` `_recordPeerMiss`（行 464-471 驱逐分支）
- 在驱逐日志（行 466-469）之后、广播（行 470-471）之前或之后，追加一次 `triggerCrossBandDiscovery();`。
- 注意：`_recordPeerMiss` 在 `_probeDiscoveredPeers`（行 431）循环中被调用；`triggerCrossBandDiscovery` 自带 400ms 防抖，连续多次驱逐会合并为一次扫描，无风暴风险。

### 四、UI 按需触发扫描（对称 Mac `menuNeedsUpdate`）
**文件**：`clipy_android/lib/main.dart`
- 在以下三个 initState 末尾追加 `SyncManager.instance.triggerCrossBandDiscovery();`：
  - `SyncTargetDeviceList._SyncTargetDeviceListState.initState`（行 142 起，super.initState() 之后）
  - `MacSettingsTab._MacSettingsTabState.initState`（行 691 起）
  - `SettingsPage._SettingsPageState.initState`（行 1296 起）
- 保留下拉刷新（行 160-164 等处）与现有 `onPeersChanged` 监听不变。
- 说明：三个页面是用户查看设备列表的入口；进入即触发一次扫描，扫描完成后通过 `onPeersChanged` 流自动刷新列表。首次进入页面也可立即从 `_loadPersistedPeerEndpoints` 已填充的内存 Map 展示缓存。

## 假设与决策
| 项 | 决策 |
|---|---|
| 存储 key | `peerEndpoints`（SharedPreferences，JSON 字符串） |
| 序列化格式 | `Map<peerId, {"host","port","name","ts"}>`，`ts` 为 ISO-8601 |
| TTL | 24h（与 Mac 对齐，DHCP 续租量级） |
| 首屏展示 | 从内存缓存 `_discoveredPeers` 即时展示，扫描结果通过流刷新 |
| 防抖复用 | 直接调用既有 `triggerCrossBandDiscovery()`（已带 400ms 防抖） |
| Android 无周期全扫定时器 | 故无需删除任何定时器；只新增持久化 + 降频探活 + 回退扫描 |
| 安全 | 不变（endpoint 仅用于 connect，身份仍由加密握手校验） |

## 验证步骤
1. **静态检查**：在 `clipy_android/` 下执行 `flutter analyze`，确认无新增 error/warning（既有无关警告可忽略）。
2. **功能实测**：
   - 首次启动 + 完成一次同步后，kill 进程再启动：无需等扫描即可在设置页看到 peer（缓存生效）。
   - 进入设置页 / Mac 同步设置 tab：1-2s 内列表刷新到最新。
   - 模拟 peer 换 IP（改对端 IP）：连续探活失败驱逐后，观察日志出现一次 `triggerCrossBandDiscovery` 扫描并恢复。
   - Android 后台 10 分钟：logcat 无周期性全 /24 扫描，仅 120s 一次的轻量探活。
