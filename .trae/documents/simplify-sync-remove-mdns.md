# Plan: 移除 mDNS，简化通讯逻辑

## Summary

彻底移除 mDNS (Bonjour/NSD) 发布与浏览，以 /24 子网扫描 + 手动添加 host:port 作为唯一设备发现机制。消除跨频段 (2.4G/5G) 多播隔离导致的 `Resolve failed` 噪音。发现策略改为事件驱动 + 按需重扫（点击"重新发现"时再扫一次），不加周期发现定时器。

## 用户决策

1. **mDNS 策略**：彻底移除 mDNS，只用子网扫描 + 手动添加
2. **发现频率**：事件驱动 + 按需重扫（点击按钮时再扫一次，不加周期定时器）

## Current State Analysis

### 问题根因
- 路由器在 2.4G ↔ 5G 频段间不转发多播包，导致 NSD/Bonjour resolve 必然失败
- Android `_connectToService()` 调用 `resolve(service)` 失败后打印 `Resolve failed for milo ... NsdError(internalError)` 警告
- 当前存在双发现路径（mDNS + 子网扫描）+ 双表（discoveredPeers + injectedPeers）+ NSD watchdog + resolve 重试，复杂度高

### 已有的跨频段基础设施（保留）
- macOS POSIX IPv4 监听器（`startPosixIPv4Listener`，绑定 0.0.0.0）
- Android IPv4 ServerSocket（`startServer`，绑定 0.0.0.0）
- 两端 /24 子网扫描 + 加密 TCP 握手协议（handshake/hello → handshake/hi）
- 两端 peer 活性探测（45s/3 驱逐）

---

## Proposed Changes

### Part A: macOS 端 (`clipy_macos/Sources/SyncManager.swift`)

#### A1. 移除 mDNS 发布
- **删除** `netService` 属性 (L85)
- **删除** `republishNetService()` 方法 (L612-629)
- **删除** `NetServiceDelegate` 协议方法 (L1123-1134): `netServiceDidPublish`, `netService(_:didNotPublish:)`, `netServiceDidStop`
- **修改** class 声明 (L77): `class SyncManager: NSObject, NetServiceDelegate` → `class SyncManager: NSObject`
- **修改** `stop()` (L490-554): 移除 `netService` 清理代码 (L500-505, L510)
- **修改** `startListening()` (L884-937): 移除 `DispatchQueue.main.async { self.republishNetService() }` (L903-905)
- **修改** `refreshDiscovery()` (L568-610): 移除 `self.republishNetService()` 调用 (L594)

#### A2. 移除 mDNS 浏览
- **删除** `browser` 属性 (L83)
- **删除** `serviceType` 常量 (L167)
- **删除** `startBrowsing()` 方法 (L641-715) — 整个 NWBrowser 设置
- **删除** `peerId(from:serviceName:)` 辅助方法 (L632-639)
- **修改** `start()` (L476-488): 移除 `startBrowsing()` 调用 (L483)，改为直接调 `triggerCrossBandDiscovery()`
- **修改** `stop()` (L490-554): 移除 `browser` 清理代码 (L492-496)
- **修改** `refreshDiscovery()` (L568-610): 移除 browser 取消逻辑 (L576-580) 和 `startBrowsing()` 调用 (L605)

#### A3. 双表合并为单表
- **删除** `injectedPeers` 属性 (L88-90)
- **修改** `recordDiscoveredPeer()` (L1503-1517): 移除 `injectedPeers[peerId] = peer` 行 (L1512)
- **修改** `recordPeerMiss(peerId:)` (L835-865): 移除 `injectedPeers.removeValue(forKey: peerId)` 行 (L849)
- **修改** `stop()` (L490-554): 移除 `injectedPeers.removeAll()` 行 (L531)
- **修改** `refreshDiscovery()` (L568-610): 移除 `injectedPeers.removeAll()` 行 (L587)

#### A4. 简化 DiscoveredPeer 结构
- **修改** `DiscoveredPeer` 结构体 (L21-27): 删除 `browseResult: NWBrowser.Result?` 字段
- **修改** `recordDiscoveredPeer()` (L1503-1517): 构造 `DiscoveredPeer` 时移除 `browseResult: nil` 参数

#### A5. refreshDiscovery 语义改为"清表 + 子网扫描"
修改 `refreshDiscovery()` (L568-610) 逻辑为：
1. guard sync enabled + not already refreshing
2. 清空 `discoveredPeers` + `peerMissCounts`
3. 通知 UI（空列表）
4. 调用 `triggerCrossBandDiscovery()` 执行子网扫描 + 手动 peer 连接
5. 清除 `isRefreshingDiscovery` 标志

移除所有 mDNS 重启逻辑、`DispatchQueue.main.async` republishNetService、0.35s 延迟重启 browsing。

#### A6. 保留不动的部分
- POSIX IPv4 监听器 (`startPosixIPv4Listener` 及所有 `posix*` 方法)
- 子网扫描 (`scanSubnets`, `candidateScanIPs`, `enumerateLocalIPv4s`)
- 手动 peer 连接 (`connectManualPeers`)
- 握手协议 (`performHandshake`, `makeHandshakeFrame`, `handleHandshakeHello`, `handleHandshakeHi`)
- 活性探测 (`startPeerLivenessProbing`, `probeDiscoveredPeers`, `probePeer`, `recordPeerMiss`)
- NWPathMonitor 网络变化监控 (`startPathMonitoring`, `stopPathMonitoring`)
- `triggerCrossBandDiscovery()` (L1281-1287)

---

### Part B: Android 端 (`clipy_android/lib/sync_manager.dart`)

#### B1. 移除 nsd 发布/浏览
- **删除** `import 'package:nsd/nsd.dart';` (L7)
- **删除** `_registration` 属性 (L147)
- **删除** `_discovery` 属性 (L148)
- **删除** `_serviceType` 常量 (L229)
- **删除** `startPublishing()` 方法 (L644-658)
- **删除** `startBrowsing()` 方法 (L660-719)
- **删除** `_peerIdFromService()` 方法 (L231-237)
- **修改** `start()` (L541-554): 移除 `startPublishing()`, `startBrowsing()`, `_startDiscoveryWatchdog()` 调用；改为调 `triggerCrossBandDiscovery()`
- **修改** `stop()` (L556-588): 移除 `_registration`/`unregister` 和 `_discovery`/`stopDiscovery` 代码块 (L563-578)

#### B2. 移除 NSD 看门狗与重试延时
- **删除** `_discoveryWatchdogTimer` 属性 (L172)
- **删除** `_discoveryWatchdogInterval` 常量 (L194)
- **删除** `_discoveryRestartDelay` 常量 (L207)
- **删除** `_startDiscoveryWatchdog()` 方法 (L434-446)
- **删除** `_stopDiscoveryWatchdog()` 方法 (L448-451)

#### B3. 简化连接路径（消除 Resolve failed 噪音）
- **删除** `_connectToService()` 方法 (L1620-1659) — 这是 `Resolve failed` 日志的唯一来源
- **修改** `_connectToPeer()` (L1601-1618): 移除 `service` 分支 (L1615-1617)，只保留 host:port 直连

#### B4. 双表合并 + 简化 DiscoveredPeer 模型
- **修改** `DiscoveredPeer` 类 (L125-141): 删除 `final Service? service` 字段及构造参数
- **删除** `_injectedPeers` 属性 (L155)
- **修改** `_recordDiscoveredPeer()` (L961-981): 移除 `_injectedPeers[peerId] = peer` 行 (L970)
- **修改** `_recordPeerMiss()` (L491-509): 移除 `_injectedPeers.remove(peerId)` 行 (L501)
- **修改** `stop()` (L556-588): 移除 `_injectedPeers.clear()` 行 (L585)
- **修改** `refreshBrowsing()`/`refreshDiscovery()` (L721-763): 移除 `_injectedPeers.clear()`

#### B5. refreshBrowsing → refreshDiscovery 重命名
- **重命名** `refreshBrowsing()` (L721-763) 为 `refreshDiscovery()`，简化逻辑为：
  1. guard enabled + not already refreshing
  2. 清空 `_discoveredPeers` + `_peerMissCounts`
  3. 通知 UI（空列表）
  4. 调用 `triggerCrossBandDiscovery()` 执行子网扫描 + 手动 peer 连接
  5. 清除 `_isRefreshingDiscovery` 标志
- 移除所有 mDNS 重启逻辑（stopDiscovery, unregister, Future.delayed, startPublishing, startBrowsing）

#### B6. 保留不动的部分
- `startServer()` (L766-801) — IPv4 ServerSocket
- `triggerCrossBandDiscovery()` (L988-994)
- 子网扫描 (`_scanSubnets`, `_candidateScanIPs`, `_enumerateLocalIPv4s`)
- 手动 peer 连接 (`_connectManualPeers`)
- 握手协议 (`_performHandshake`, `_makeHandshakeJson`, `_handleHandshakeHello`, `_handleHandshakeHi`, `_readOneFrame`, `_writeFrame`)
- 活性探测 (`_startPeerLivenessProbing`, `_probeDiscoveredPeers`, `_recordPeerMiss`, `_stopPeerLivenessProbing`)
- 连接监控 (`_startConnectivityMonitoring`, `_stopConnectivityMonitoring`) — 但内部调 refreshDiscovery 而非 refreshBrowsing

---

### Part C: UI 调用点更新

#### C1. Android `main.dart` (`clipy_android/lib/main.dart`)
- **修改** L162: `SyncManager.instance.refreshBrowsing()` → `SyncManager.instance.refreshDiscovery()`
- 其他调用点（`triggerCrossBandDiscovery()` at L344, `start()`/`stop()` at L805/L1175/L1347）无需改动

#### C2. macOS UI (`clipy_macos/Sources/UI/SettingsView.swift`)
- 刷新按钮已调 `refreshDiscovery()`，手动添加已调 `triggerCrossBandDiscovery()`，无需改动

---

## Assumptions & Decisions

1. **NWListener 保留**：macOS 端 NWListener 仍保留（POSIX IPv4 监听器在并行运行处理实际 IPv4 连接），只是不再在其上注册 mDNS 服务 (`listener?.service = nil` 改为不设置 service)
2. **pubspec.yaml**：Android 端移除 `nsd` 依赖后需更新 `pubspec.yaml`（移除 `nsd` 和 `nsd_android` 包依赖）
3. **活性探测保留**：45s/3 驱逐的 peer 活性探测保留，用于清理不可达 peer（非发现用途）
4. **连接监控保留**：网络变化时触发 `refreshDiscovery()`（重扫描），生命周期 resume 时同理
5. **无周期发现定时器**：用户明确要求事件驱动 + 按需重扫

## Verification Steps

1. **macOS 编译**：执行 `bash build_macos_app.sh`，确认 swiftc 编译通过（无 NetServiceDelegate/NWBrowser 相关错误）
2. **Android 编译**：执行 `cd clipy_android && flutter build apk --debug`，确认无 nsd 相关编译错误
3. **功能验证**：
   - Mac (5G) + Android (2.4G) 同时开启同步
   - 点击"重新发现"按钮，确认双方能在 ~5s 内发现对方
   - 确认无 `Resolve failed` 警告日志
   - 确认手动添加 peer (host:port) 能正常连接
   - 确认复制内容能跨频段同步
4. **日志检查**：确认日志中不再出现 `NsdError`、`Resolve failed`、`mDNS browse` 相关条目
