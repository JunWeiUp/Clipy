# 按需发现 + endpoint 持久化缓存（省电导向）

## 目标
把当前「每 30s 全 /24 子网扫描维护设备列表」改为「设备列表按需扫描 + endpoint 持久化保证数据传输」。**常态零全 /24 扫描**，仅在打开 UI 或 endpoint 失效时才触发一次扫描。两端对称实现。

核心洞察：设备列表只有用户打开 Mac 菜单栏 / Android 设置页时才展示；其余时间只需能向已知 peer 传数据。定期全 /24 扫描的唯一价值是"刷新列表"，却让 Android 后台被反复唤醒——本方案把这个开销移到"按需"时刻。

## 当前状态分析（已探索确认）
- **耗电主因**：`rescanTimer` 每 30s → `triggerCrossBandDiscovery` → 全 /24 扫描（探测数十 IP，并发 64）。Android `ServerSocket` 被动接收大量入站握手 → 无线芯片反复唤醒。
- **数据传输强依赖发现列表**：`dispatchBroadcast`（Mac `SyncManager.swift:1678` / Android `sync_manager.dart:320`）从 `availablePeers` 筛选在线已授权 peer 直连；空列表 → 数据进 `pendingQueue`，无人触发 flush。
- **endpoint 未持久化**：只有 `authorizedPeerIds` 存盘；peer 的 `host:port` 是运行时的。app 重启后 `discoveredPeers` 为空，必须扫描才有传输目标。
- **UI 当前不主动触发扫描**：
  - Mac `MenuController.menuNeedsUpdate`(877行)→`refreshMenuForOpen`(142行) 只刷新菜单内容，**不调用** `triggerCrossBandDiscovery`；只有手动「刷新设备」按钮(652行)才扫。
  - Android `SyncTargetDeviceList.initState`(142行)、`MacSettingsTab.initState`(691行)、`SettingsPage.initState`(1296行) 只读 `availablePeers` + 监听 `onPeersChanged` 流，**不调用** `triggerCrossBandDiscovery`。
- **已有探活**：`peerLivenessTimer`（45s×3 驱逐），仅对已知 peer 做 TCP connect，开销极小。
- **已有离线队列**：`pendingQueue`（30s TTL / 50 条上限），peer 重新出现时 flush。
- **已有握手复用**：`performHandshake`/`_performHandshake` → `recordDiscoveredPeer`/`_recordDiscoveredPeer`。

## 改动方案（两端对称）

### 一、新增：endpoint 持久化缓存
**Mac — `SyncManager.swift`**
- 新增 `persistPeerEndpoints()`：把 `discoveredPeers` 序列化为 `[peerId: {host, port, name, ts}]` 存入 `UserDefaults`（key `clipy.peerEndpoints`）。在 `recordDiscoveredPeer` 成功后异步调用。
- 新增 `loadPersistedPeerEndpoints()`：`start()` 中加载 → 用缓存的 endpoint 填充 `discoveredPeers`（数据传输立即可用，无需等待扫描）。缓存设过期（如 24h），过期不加载。
- peer 被探活驱逐时同步从持久化缓存移除该 endpoint。

**Android — `sync_manager.dart`**
- 对称实现，用 `SharedPreferences` key `peerEndpoints`（JSON 字符串存 Map）。
- `_recordDiscoveredPeer` 成功后异步持久化；`start()` 加载填充 `_discoveredPeers`；驱逐时移除。

> 作用：app 重启 / 长时间后台后，无需扫描即可向已知 peer 传数据。

### 二、移除定期全 /24 重扫（省电核心）
**Mac — `SyncManager.swift`**
- 删除 `rescanTimer`、`startRescanTimer()`、其在 `start()`/`stop()` 的调用。
- 保留 `evictedPeerEndpoints` + `reprobeEvictedPeers`（精准重探，开销极小），但从 `triggerCrossBandDiscovery` 的 work 中保留即可，随按需扫描触发。
- **保留**启动时一次扫描（`start()` 已有）、网络变化一次扫描（`startPathMonitoring` 已有）。

**Android — `sync_manager.dart`**
- 当前无独立的定期全扫定时器（靠启动 + 网络变化 + UI 触发），无需删除；确认 `start()` 中仅触发一次 `triggerCrossBandDiscovery`，不引入周期定时器。

### 三、设备列表 UI 按需触发扫描
**Mac — `MenuController.swift`**
- `menuNeedsUpdate`(877行) / `refreshMenuForOpen`(142行) 中追加：调用 `SyncManager.shared.triggerCrossBandDiscovery()`（异步，不阻塞菜单展示；扫描完成后通过 `onPeersChanged` 回调刷新菜单）。
- 菜单先用缓存列表即时展示，扫描命中后通过现有 `onDevicesChanged`(113行) 回调更新。
- 保留手动「刷新设备」按钮(652行)。

**Android — `main.dart`**
- `SyncTargetDeviceList._SyncTargetDeviceListState.initState`(142行) 末尾追加 `SyncManager.instance.triggerCrossBandDiscovery()`。
- `MacSettingsTab`(691行) / `SettingsPage`(1296行) 同理（这两个 state 也展示设备列表）。
- 保留下拉刷新(160-164行)。

### 四、保留并降频探活（维护 endpoint 有效性 + flush pendingQueue）
**两端**
- `peerLivenessTimer` 间隔 45s → **120s**（仅对已知 peer TCP connect，开销极小；作用：及时驱逐失效 endpoint、对端恢复后 flush 积压的 `pendingQueue`）。
- 探活驱逐时同步更新持久化缓存（移除过期 endpoint）。

### 五、数据传输连接失败回退（endpoint 失效时自动重新发现）
**两端**
- 在 `recordPeerMiss`/驱逐路径中：当 peer 因连续 miss 被驱逐后，触发一次 `triggerCrossBandDiscovery()`（按需重新发现失效 endpoint）。
- 这样 DHCP 换 IP / endpoint 过期后，下一次数据传输会自动重发现而非永久进队列。

## 常态行为对比
| 场景 | 改造前 | 改造后 |
|---|---|---|
| 后台常态 | 每 30s 全 /24 扫描（Android 被动唤醒） | **零全 /24 扫描**；仅 120s 轻量探活已知 peer |
| 打开设备列表 UI | 读缓存（可能过时） | 触发一次扫描，几秒内更新到最新 |
| 复制内容触发同步 | 依赖扫描维护的列表 | 直连缓存 endpoint；失败则回退一次扫描 |
| app 重启 | 列表空，须等扫描 | 缓存 endpoint 立即可用 |

## 关键设计决策
| 项 | 决策 |
|---|---|
| endpoint 缓存 key | `peerId` → `{host, port, name, ts}` |
| 缓存过期 | 24h（局域网 DHCP 续租周期量级） |
| 缓存存储 | Mac UserDefaults `clipy.peerEndpoints` / Android SharedPreferences `peerEndpoints` |
| 全 /24 扫描触发时机 | 仅：启动一次、网络变化、UI 打开、endpoint 失效回退 |
| 探活保留 | 是，降频 120s，仅已知 peer |
| 离线队列 | 不变（30s TTL / 50 上限） |
| 安全 | 不变（endpoint 仅用于 connect，身份认证仍由加密握手） |

## 假设
- 局域网 DHCP 续租周期 >> 24h（endpoint 缓存有效期内 IP 基本稳定）。
- endpoint 失效（换网/换IP）由「连接失败回退扫描」自动恢复。
- 已授权 peer 的 peerId 已持久化（现状），endpoint 缓存与之配合。
- 打开 UI 触发扫描的 1-2s 延迟可被用户接受（菜单/列表先用缓存即时展示）。

## 验证步骤
1. **Mac**：`bash /tmp/clipy_typecheck.sh`，EXIT_CODE=0。
2. **Android**：`flutter analyze`（clipy_android/）无新增错误。
3. **功能实测**：
   - app 重启后无需等待，立即能向已授权 peer 发送复制内容（endpoint 缓存生效）。
   - 打开 Mac 菜单栏 / Android 设置页，设备列表在 1-2s 内刷新到最新。
   - Android 进后台 10 分钟，观察日志：无周期性全 /24 扫描，仅低频探活；唤醒次数显著下降。
   - 模拟 endpoint 失效（改 peer IP）：发数据失败后自动重扫并恢复。

## 落地顺序
1. Mac: endpoint 持久化（load/persist）→ 删除 rescanTimer → menuNeedsUpdate 触发扫描 → 探活降频 → 驱逐回退扫描 → typecheck。
2. Android: endpoint 持久化 → initState 触发扫描 → 探活降频 → 驱逐回退扫描 → flutter analyze。
3. 联调实测。
