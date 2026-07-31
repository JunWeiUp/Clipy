# 发现层改造：mDNS/NSD 主力 + 低频 unicast 兜底（省电导向）

## 目标
把当前「纯 unicast TCP 子网扫描」发现模型，升级为「mDNS/NSD 主力发现 + 低频 unicast 子网扫描兜底」的混合模型，**核心诉求是降低 Android 后台被探测唤醒次数、显著省电**，同时保留跨频段兜底能力。两端对称实现。

## 为什么不加 UDP 组播(5566)（结论）
从省电角度排序（最省电 → 最耗电）：
1. **mDNS/NSD（采用）**：Android 上由系统级 `NsdManager` 调度，被动监听，几乎零 app 主动发包；macOS 由 `NetService`/`NetServiceBrowser` 维护。最省电。
2. **UDP 组播心跳（不采用）**：需 app 每 N 秒主动发包，比 mDNS 耗电；且与 mDNS 受**完全相同的多播路由隔离限制**，跨频段场景同样失效、同频段又与 mDNS 功能重叠——加了复杂度但收益≈0。
3. **纯 unicast 扫描（现状，降频保留为兜底）**：最耗电，但跨频段唯一可靠。

> 即：UDP 组播在省电上劣于 mDNS、在多播可达性上又不优于 mDNS，故舍弃。

## 当前状态分析
- 两端**均已移除 mDNS**（见 `SyncManager.swift:799-805`、`sync_manager.dart:796-799` 注释：mDNS 多播在 2.4G/5G 频段间常被路由器隔离）。
- 现状：纯 unicast TCP /24 扫描（端口 `5566/TCP`，默认）+ 手动 peer + 加密握手；Mac 30s 重扫 + 45s×3 探活驱逐；Android 对称。
- **耗电主因**：Mac 每 30s 向数十个候选 IP 发 TCP SYN（并发 64），Android 端被动接收大量入站握手 → 无线芯片反复从休眠唤醒。这是 Android 后台耗电的核心来源。
- 上一轮已加 `evictedPeerEndpoints` 精准重探（Mac）+ `PARTIAL_WAKE_LOCK`（Android FGS）。

## 改动方案（两端对称）

### 一、macOS 端 — `clipy_macos/Sources/SyncManager.swift`
引入 Bonjour 层，**只做服务注册/发现，不接数据**（数据仍由 POSIX IPv4 listener 处理，避免重蹈 NWListener 的 IPv6 socket 端口冲突问题）：

1. **服务注册（advertising）**：用 `NetService(domain:"", type:"_clipy._tcp.", name:<peerId>, port:<syncPort>)`，TXT 记录带 `peerId`/`name`/`port`。`start()` 时 `register()`，`stop()` 时 `stop()`。
2. **服务浏览（browse）**：用 `NetServiceBrowser`，`searchForServices(ofType:"_clipy._tcp.")`。delegate：
   - `netServiceBrowser(_:found:moreComing:)` → 对每个命中服务 `resolve()`（设置 delegate）。
   - `netServiceDidResolveAddress(_:)` → 取 `hostName` + `port`（TXT 读 `port` 兜底）→ 构造 `NWEndpoint.hostPort` → **复用现有 `performHandshake(to:)`** 完成加密握手与身份交换 → 成功后 `recordDiscoveredPeer`。
   - `netServiceBrowser(_:didNotSearch:)` / 失败 → 记日志，不阻塞 unicast 兜底。
3. **mDNS remove 事件**：`netServiceBrowser(_:didRemoveDomain:moreComing:)` → 仅作"可能离线"的早期提示，**不直接驱逐**（权威驱逐仍由 TCP 探活 `probeDiscoveredPeers` 判定，因为 mDNS remove 不可信）。
4. **unicast 子网扫描降频**：`rescanInterval` 30s → **120s**（mDNS 主力发现后，扫描仅作跨频段兜底，大幅减少 Android 被探测唤醒）。
5. POSIX listener、加密握手、探活、重探、手动 peer 全部不变。
6. `start()`/`stop()` 增加 NetService/NetServiceBrowser 生命周期；网络变化（`refreshDiscovery`）重启 browse。

### 二、Android 端
**新增原生 NSD 层**（系统调度，省电关键）：

1. **`MainActivity.kt`**：新增 MethodChannel `com.clipyclone.clipy_android/nsd`：
   - `startNsd(peerId, name, port)` → `NsdManager.registerService(NsdServiceInfo(_clipy._tcp, port))` + `discoverServices(_clipy._tcp)`。注册信息写 TXT（peerId/name/port）。
   - `stopNsd()` → 注销 listener/register。
   - 发现 → `resolveService` → 通过 `result.success()`/`EventChannel` 回传 `{host, port, name, peerId}`。
2. **`lib/sync_manager.dart`**：
   - `start()` 中通过 nsd channel 启动注册+发现，监听回传；命中后**复用现有 `_performHandshake(host, port)`** → `_recordDiscoveredPeer`。
   - `stop()` 中 `stopNsd`。
   - 重扫定时器（`_scanDebounceTimer` 触发周期）30s → **120s**，与 Mac 对称。
   - `ServerSocket`（数据通道）不变。
3. Android NsdManager 由系统维护，FGS + Wake Lock 下 maintenance window 仍可响应；零 app 主动发包 → 省。

### 三、安全模型不变
- mDNS/NSD **仅用于"找到 endpoint"**；身份认证、AES-GCM 密钥校验、peerId 校验仍由现有 TCP 加密握手完成。
- TXT 中不带任何敏感信息；`port` 仅作 connect 提示。

## 关键设计决策
| 项 | 决策 |
|---|---|
| 服务类型 | `_clipy._tcp.`（两端一致） |
| 服务名 | 用 `peerId`（保证唯一、可去重） |
| TXT 记录 | `peerId`、`name`、`port` |
| 发现后是否握手 | 是，复用 `performHandshake`/`_performHandshake`（安全 + 拿真实端口） |
| 离线判定 | 以 TCP 探活为准，mDNS remove 仅作提示 |
| 跨频段兜底 | 低频（120s）unicast 子网扫描 |
| 数据 socket | 不变（Mac POSIX / Android ServerSocket） |
| UDP 组播 | 不加 |

## 假设
- 同频段下 mDNS/NSD 可用（绝大多数家用/办公场景）。
- 跨频段由 120s unicast 扫描兜底（已验证可行）。
- Android NSD 在 FGS + Wake Lock 下，Doze maintenance window 可响应（比 app 层 socket 可靠）。

## 验证步骤
1. **Mac**：`swiftc -typecheck`（用 `/tmp/clipy_typecheck.sh`），退出码 0。
2. **Android**：`flutter analyze`（在 `clipy_android/`）无新增错误。
3. **功能实测**：
   - 同频段：设备互启后 mDNS 秒级发现出现在设备列表。
   - 跨频段（2.4G↔5G）：mDNS 失效后，120s 内由 unicast 扫描兜底发现。
   - Android 进后台数分钟再回前台：设备列表能自动恢复（mDNS browse + 重探 + 兜底扫描三重保障）。
4. **省电对比**：Android 后台 10 分钟，观察唤醒次数/电量下降是否较改造前明显减少（日志中入站握手频次应显著降低）。

## 落地顺序
1. Mac: 新增 NetService/NetServiceBrowser + 接入 recordDiscoveredPeer；rescanInterval→120s；typecheck。
2. Android: MainActivity NSD channel + sync_manager.dart 接入；重扫→120s；flutter analyze。
3. 联调实测。
