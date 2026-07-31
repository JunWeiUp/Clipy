# 降低 Mac ↔ Android 通信频次 & 优化端间协议

## Summary

当前 Mac 与 Android 之间存在严重的重复发现/重复建链问题：同一对端在 200ms 内被发现了 3 次（用户日志 17:42:41.127 / 41.160 / 41.313，fd=6 反复出现）。根因是两端同时触发了多种并行的发现机制（subnet scan、lifecycle resume、connectivity change、scheduleReconnect、probeDiscoveredPeers），且任一方发现对端后仍会独立发起 outbound 持久连接，造成双向同时建链 + 重复握手。

本次改造在不破坏协议兼容（length-prefixed JSON + AES-GCM）的前提下，通过"幂等抑制 + 跳过已连对端 + 单一发现入口 + 抬升稳态 keepalive"四个方向，把空载请求频次降到最低。

## Current State Analysis

### 当前架构（两侧对齐）
- **持久出站连接**：`persistentConnections[peerId] = NWConnection/Socket`，双向独立 outbound（一对 peer 至多 2 条连接）
- **发现机制**：`triggerCrossBandDiscovery()` → `connectManualPeers()` + `scanSubnets()` + `reprobeEvictedPeers()`，debounce 400ms
- **探活机制**：`probeDiscoveredPeers()`（周期定时器已移除，但仍由 lifecycle / connectivity 触发）
- **重连机制**：`scheduleReconnect(peerId)` 指数退避 1→30s
- **通信协议**：4 字节大端长度前缀 + JSON `SyncMessage`，AES-GCM 加密 content；握手 `handshake/hello` → `handshake/hi` 交换 peerId/name/port
- **keepalive**：Mac 60s/60s，Android 60s/30s

### 问题点（基于代码 + 用户日志）

1. **Android `didChangeAppLifecycleState`**（[sync_manager.dart:315-329](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L315-329)）回前台一次触发 3 件事：
   - `refreshDiscovery()` → `triggerCrossBandDiscovery()` → `_scanSubnets()`（对 /24 全扫，每 IP 一次握手）
   - 对每个 peer 调 `_scheduleReconnect(peerId)` → `_performHandshake()` 又一次握手
   - `_probeDiscoveredPeers()` → 对每个 peer 又一次 `_connectToPeer()`
   - 这 3 路并行，同一对端被并发握手 3 次 → 这就是日志里 200ms 3 次发现的直接来源

2. **Android `_startConnectivityMonitoring`**（[sync_manager.dart:284-307](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L284-307)）：网络事件触发 `refreshDiscovery()` + 对每个 peer `_scheduleReconnect()`，2 路并发。

3. **Mac `startPathMonitoring`**（[SyncManager.swift:565-591](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L565-591)）：网络变化触发 `refreshDiscovery()`，与 Android 侧对称。

4. **两侧同时 subnet scan**：Mac 扫 Android，Android 扫 Mac，同一时刻双向握手，2N 次连接。

5. **Mac `scanSubnets`**（[SyncManager.swift:1460-1487](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1460-1487)）64 并发握手，不检查目标 IP 是否已是已连对端。

6. **`probeDiscoveredPeers` / `_probeDiscoveredPeers`** 对已有持久连接的对端仍单独打开一条 TCP 做探活（[SyncManager.swift:829-862](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L829-862), [sync_manager.dart:544-565](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L544-565)）。

7. **`recordPeerMiss` → `triggerCrossBandDiscovery`**（[SyncManager.swift:925](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L925), [sync_manager.dart:587](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L587)）：一次探活失败立即触发 /24 全扫，与 `scheduleReconnect` 指数退避叠加。

8. **`_performHandshake` 成功后** 仍可能在 `_recordDiscoveredPeer` 里再次触发 `_flushPendingQueue`，但 `recordPeerMiss` 之后的 eviction 也会触发 `triggerCrossBandDiscovery`，产生级联。

## Proposed Changes

### 阶段 1：抑制重复发现触发（最关键，直接解决日志里的 3×握手）

#### 1.1 Android `didChangeAppLifecycleState` 合并为单一发现路径
- **文件**：`clipy_android/lib/sync_manager.dart` line 315-329
- **改动**：回前台时**只调用一次** `_probeDiscoveredPeers()`，且该方法内部跳过已持久连接的 peer（见 1.4）。删除：
  - `unawaited(refreshDiscovery())`
  - `for (final peerId in _discoveredPeers.keys.toList()) { if (!_persistentConnections.containsKey(peerId)) _scheduleReconnect(peerId); }`
- **原因**：`_probeDiscoveredPeers()` 已能探活并触发 eviction；eviction 内部会调 `triggerCrossBandDiscovery()`，无需前台再主动扫一遍 /24。

#### 1.2 Android `_startConnectivityMonitoring` 合并
- **文件**：`clipy_android/lib/sync_manager.dart` line 284-307
- **改动**：网络恢复时只调用 `refreshDiscovery()`；删除 `for ... _scheduleReconnect()` 循环。
- **原因**：`refreshDiscovery()` 会清空 peers 并触发新一轮 `triggerCrossBandDiscovery()`，对所有 peer 都会重新建链，单独 scheduleReconnect 是重复劳动。

#### 1.3 Mac `startPathMonitoring` + wake 依赖 refreshDiscovery 内部去重
- **文件**：`clipy_macos/Sources/SyncManager.swift` line 549-591, 550-558
- **改动**：保持现状调用 `refreshDiscovery()`，但 `refreshDiscovery()` 内部增加"已有持久连接的 peer 跳过"语义（见 1.5）。无需新增探活路径。

#### 1.4 `probeDiscoveredPeers` / `_probeDiscoveredPeers` 跳过已持久连接的 peer
- **macOS**：`SyncManager.swift` `probeDiscoveredPeers` (line 829-862)
- **Android**：`sync_manager.dart` `_probeDiscoveredPeers` (line 544-565)
- **改动**：循环里增加
  - macOS: `if persistentConnection(for: peer.peerId) != nil { peerMissCounts[peer.peerId] = 0; continue }`
  - Android: `if (_persistentConnections.containsKey(peer.peerId)) { _peerMissCounts.remove(peer.peerId); continue; }`
- **原因**：持久连接本身就是 liveness 证明，再开一条 TCP 探活纯浪费。

#### 1.5 `scanSubnets` 跳过已连对端的 IP
- **macOS**：`SyncManager.swift` `scanSubnets` (line 1460-1487) — 在循环里先查 `availablePeers` 的 endpoint host；若该 IP 已是已发现 peer 且对它持有持久连接，则跳过 handshake。
- **Android**：`sync_manager.dart` `_scanSubnets` (line 1183-1215) 同理。
- **实现**：构造 `connectedHosts: Set<String>`，从 `availablePeers` 中 filter 出 `persistentConnection(for: peerId) != nil` 的，取其 host。
- **进一步**：增加 `lastHandshakeAt: [String: Date]` 短期缓存（5s TTL），同一 IP 在 5s 内不重复握手，避免 scan + manual peer + reprobe 三路同时命中同一 IP。

#### 1.6 `recordPeerMiss` 不要立即触发 `triggerCrossBandDiscovery`
- **macOS**：[SyncManager.swift:925](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L925)
- **Android**：[sync_manager.dart:587](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L587)
- **改动**：eviction 后只把 peer 加入 `evictedPeerEndpoints`，由 `reprobeEvictedPeers` 在下一次自然 `triggerCrossBandDiscovery` 周期内重试；删除 `triggerCrossBandDiscovery()` 立即调用。
- **原因**：`scheduleReconnect` 已带指数退避重连，立即全扫是冗余。evicted peer 的 endpoint 仍被缓存 10 分钟（`evictedPeerRetention=600`），会在下次任何 trigger 时被 `reprobeEvictedPeers` 命中。

### 阶段 2：优化握手协议（减少握手表数）

#### 2.1 `handshake/hi` 后不再触发独立的 `_scheduleReconnect`
- **文件**：Android `sync_manager.dart` line 322-325（lifecycle resume 里）+ Mac `recordDiscoveredPeer`
- **改动**：发现 peer 后只调用 `_flushPendingQueue` + `_backfillPendingNotifications`；不再主动 `scheduleReconnect`（连接已经存在或正在建立）。
- **注**：1.1 已经把 lifecycle 的 scheduleReconnect 删了，这里补 Mac 侧的 `recordDiscoveredPeer` 不要再走 `flushPendingQueue` 之外的额外重连路径。

#### 2.2 在 hello/hi 里带 `hasOutbound` 标志，去重双向同时建链
- **字段**：`HandshakePayload` 增加 `hasOutbound: Bool`（默认 false 兼容旧版）
- **macOS**：`SyncManager.swift` `HandshakePayload` (line 1307) + `makeHandshakeFrame` (line 1709) + `handleHandshakeHello` (line 1727)
- **Android**：`sync_manager.dart` `_makeHandshakeJson` (line 1455) + `_handleHandshakeHello` (line 948)
- **语义**：
  - 发起方发 `handshake/hello`，payload 设 `hasOutbound = (self.persistentConnection(for: remotePeerId) != nil)`（其实首次发 hello 时为 false，但保留字段以便后续扩展）
  - 响应方收到 hello 后，若自己已对 hello 发起方持有 outbound 持久连接，则在 `handshake/hi` 里设 `hasOutbound=true`
  - 发起方收到 hi 后，若 `hasOutbound=true`，则**销毁本次新建连接**（不 promote），保留已存在的 outbound
- **兼容**：旧版对端不识别该字段（Decodable 默认 false），行为不变；新版发起方单边决策即可减少一半重复。

#### 2.3 连接 tie-breaking（可选，较复杂，建议作为 2.1/2.2 之后观察效果再决定是否上）
- 规则：peerId 字典序较小的一方"拥有"outbound 连接所有权；另一方收到 inbound 后不再发起 outbound。
- 文件：两端的 `recordDiscoveredPeer` / `_recordDiscoveredPeer`
- **本次计划标记为可选**，待 1.x + 2.1 + 2.2 上线观察日志再决定。

### 阶段 3：降低稳态 keepalive 频率

#### 3.1 keepalive 间隔抬升
- **macOS**：`SyncManager.swift` line 176-177
  - `keepaliveIdle: 60 → 120`, `keepaliveInterval: 60 → 120`
- **Android**：`sync_manager.dart` line 213-214
  - `_keepaliveIdleSec: 60 → 120`, `_keepaliveIntervalSec: 30 → 60`
- **原因**：LAN 连接极稳定，60s 探活纯冗余；120s 仍能在 ~5min 内检测半开连接（keepaliveIdle + 3×keepaliveInterval）。

#### 3.2 subnet scan debounce 抬升
- **macOS**：[SyncManager.swift:1326](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1326) `0.4 → 0.8`
- **Android**：[sync_manager.dart:1112](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L1112) `400ms → 800ms`
- **原因**：避免抖动期连续触发；不影响首次发现延迟感受（用户主动操作一般在秒级）。

## Assumptions & Decisions
- **不破坏协议兼容**：所有协议字段用默认值或可选字段，旧端不识别时行为不变
- **不动加密/分片协议**（length-prefixed JSON + AES-GCM）
- **不动文件传输流程**（独立连接 + 阻塞发送，与持久连接解耦）
- **优先级**：阶段 1（1.1-1.6）→ 阶段 2.1+2.2 → 阶段 3 → 阶段 2.3（可选）
- **测试设备**：用户的 redme Android (192.168.31.85:5566) + Mac，重现日志里的 3×握手场景

## Verification

1. **日志验证（主要）**：重启两端，对端在 1s 内只应出现 1 条 `Discovered peer via handshake` 日志，不再有 200ms 内 3 次重复。
2. **连接数验证**：
   - Mac: `lsof -i :5566` 应显示每对 peer 至多 2 条 ESTABLISHED 连接（一进一出）
   - Android: `netstat -an | grep 5566` 同理
3. **功能验证**：
   - 复制文本：Mac→Android、Android→Mac 都能正常同步
   - 文件传输：100MB 文件能完整传输（独立连接不受影响）
   - 通知同步：Android 通知能正常镜像到 Mac
   - 离线恢复：一端离线 30s 后恢复，pending 队列能正确 flush
4. **能耗验证**：Android 后台 10 分钟，网络流量应接近 0（只有 keepalive）。
5. **回归验证**：
   - Mac 端编译：`cd clipy_macos && swift build`（或 Xcode build）
   - Android 端编译：`cd clipy_android && flutter analyze` + `flutter build apk`

## Implementation Order（建议执行顺序）

1. 阶段 1.4（probeDiscoveredPeers 跳过已连 peer）— 最简单，立即减少探活流量
2. 阶段 1.1 + 1.2（Android lifecycle/connectivity 合并）— 直接解决日志里的 3×握手
3. 阶段 1.5（scanSubnets 跳过已连 IP + 5s 短期缓存）— 消除 subnet scan 重复
4. 阶段 1.6（recordPeerMiss 不立即全扫）— 消除 eviction 级联
5. 阶段 3.1 + 3.2（keepalive + debounce 抬升）— 一行常量改动
6. 阶段 2.1（hi 后不 scheduleReconnect）— 小改动
7. 阶段 2.2（hasOutbound 标志去重双向建链）— 协议改动，需双端同步上线
8. （可选）阶段 2.3 tie-breaking — 观察后再决定
