# 局域网设备扫描速度优化方案

## Summary

当前子网扫描采用「全 /24 枚举 + TCP connect 握手 + 16 并发 + 1s 超时」模型，单子网 253 个候选最坏需 ~16s，多子网场景会被 Android 30s 总超时截断。本方案通过四层优化将扫描时间从**秒级压到百毫秒级**：ARP 预筛 + 并发度提升 + 超时收紧 + 触发去抖。

## Current State Analysis（瓶颈定位）

基于代码探索，按影响排序：

| 瓶颈 | 位置 | 影响 |
|------|------|------|
| **并发度 16 偏小** | Android [sync_manager.dart:896](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L896)；Mac [SyncManager.swift:1170](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1170) | 253/16≈16 批 × 1s = ~16s |
| **无 ARP/ICMP 预筛** | 两端 `_candidateScanIPs` / `candidateScanIPs` | 对 254 个 IP 全做 TCP connect，含大量空号 |
| **Android 读 hi 无超时** | [sync_manager.dart:971](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L971) `await for` 无 timeout | 单个慢节点挂满 30s 总超时 |
| **connect 超时 1s 偏长** | Android [L939](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L939)；Mac [L1219](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1219) | 局域网 RTT <10ms，1s 过于保守 |
| **无触发去抖** | Android `setSyncTarget` 每次勾选都全量扫 [L473](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L473)；Mac 靠 scanQueue 串行堆积 | UI 操作反复触发，任务堆积 |

## Proposed Changes

### 优化 1：ARP 预筛（最大收益）⭐⭐⭐

同子网内，系统 ARP 表（`arp -a`）记录了近期通信过的 IP。只对 ARP 表中的活跃 IP 做 TCP 握手，跳过空号，可将候选从 253 个骤减到 5-30 个。

**macOS 端** — 读取系统 ARP 表：
- 文件：`SyncManager.swift`
- 新增 `readArpTable() -> Set<String>`：执行 `arp -a` 并解析 IP
- 修改 `candidateScanIPs()`（[L1140](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1140)）：先取 ARP 活跃 IP，仅对这些候选做握手；ARP 为空时回退到全量枚举（保底）
- 实现：用 `Process` 执行 `arp -a -n`，正则提取 `(\d+\.\d+\.\d+\.\d+)`

**Android 端** — `InetAddress.isReachable` 预筛：
- 文件：`sync_manager.dart`
- 修改 `_candidateScanIPs()`（[L868](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L868)）：对全量候选先用 `isReachable(150ms)` 并发预筛，只对可达 IP 做握手
- 回退策略：预筛全部失败时，保留全量候选走原有 TCP 路径

> ⚠️ ARP 仅对本子网有效。跨子网（2.4G/5G 不同网段）时 ARP 表无对端条目，此时回退到全量枚举 + 高并发（优化 2）。用户场景（192.168.31.x 同子网）下 ARP 预筛生效。

### 优化 2：提升并发度 + 收紧超时

| 参数 | 当前值 | 优化后 | 理由 |
|------|--------|--------|------|
| 扫描并发度 | 16 | **64** | 局域网 TCP SYN 并发完全可承受 |
| TCP connect 超时 | 1s | **400ms** | 局域网 RTT <10ms，400ms 足够覆盖跨频段路由 |
| Android 整体超时 | 30s | **8s** | 并发 64 + ARP 预筛后足够 |
| Android 读 hi 超时 | 无 | **500ms** | 防长尾节点挂满整批 |

**Android 端**（`sync_manager.dart`）：
- [L896](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L896) `concurrency = 16` → `64`
- [L939](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L939) `Duration(seconds: 1)` → `Duration(milliseconds: 400)`
- [L915](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L915) `Duration(seconds: 30)` → `Duration(seconds: 8)`
- [L952](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L952) `_readOneFrame(socket)` 包一层 `.timeout(Duration(milliseconds: 500))`

**Mac 端**（`SyncManager.swift`）：
- [L1170](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1170) `DispatchSemaphore(value: 16)` → `64`
- [L1219](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1219) `1.0` → `0.4`
- 新增整体超时兜底：`group.wait()` 前记录 deadline，超时则放弃剩余（防止慢节点永久挂起）

### 优化 3：触发去抖（防 UI 操作反复扫）

**Android 端**（`sync_manager.dart`）：
- `triggerCrossBandDiscovery()`（[L819](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L819)）加 **400ms debounce**
- 实现：用 `Timer`，多次调用只保留最后一次；`setSyncTarget`（[L473](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L473)）勾选时即时响应但合并扫描

**Mac 端**（`SyncManager.swift`）：
- `triggerCrossBandDiscovery()`（[L1089](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1089)）在 scanQueue 入队前加 **400ms debounce**
- 实现：`DispatchWorkItem` + `asyncAfter`，新调用取消前一个 workItem

### 优化 4：扫描观测性（辅助验证）

两端扫描结束日志补充耗时和命中数，便于验证优化效果：
- Android [L916](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L916)：`Subnet scan complete (${candidates.length} → ${hits} hits in ${elapsed}ms)`
- Mac [L1183](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1183)：同上

## Assumptions & Decisions

1. **ARP 预筛仅对本子网有效**：跨子网（不同网段）回退全量枚举 + 高并发，不依赖 ARP。
2. **不修改握手协议**：保持 hello/hi 双向握手，确保被动发现机制不变（上次确认的诉求）。
3. **不修改保活探测**（`probeDiscoveredPeers`）：45s 周期独立于扫描，不受影响。
4. **Android `isReachable` 受 ICMP 权限限制**：无 root 时走 TCP echo（端口 7），多数设备不通。因此 Android 预筛实际靠「快速 TCP connect 到 5566 端口」本身——即把 `_performHandshake` 的 connect 超时降到 400ms 即可实现等价预筛效果，**Android 不单独做 isReachable 预筛**，直接靠高并发 + 短超时。
5. **macOS 用 `arp -a`**：Process 执行有 ~50ms 开销，远小于节省的扫描时间，可接受。

## 修改文件清单

| 文件 | 改动 |
|------|------|
| `clipy_macos/Sources/SyncManager.swift` | ARP 预筛 + 并发度 64 + connect 400ms + 去抖 + 观测日志 |
| `clipy_android/lib/sync_manager.dart` | 并发度 64 + connect 400ms + 读超时 500ms + 去抖 + 观测日志 |

## Verification

1. **编译验证**：Mac 端 `bash build_macos_app.sh`，确认无 error。
2. **同子网场景**：两台设备同 192.168.31.x，观察扫描日志耗时从 ~16s 降到 <1s。
3. **跨子网场景**：2.4G/5G 不同网段，观察回退全量枚举 + 并发 64 的耗时（预期 <4s）。
4. **UI 去抖**：快速勾选/取消授权 checkbox，观察不会触发多轮扫描。
5. **长尾健壮性**：模拟对端 accept 但不回 hi，确认 500ms 读超时生效，不拖垮整批。
6. **日志确认**：看到 `Subnet scan complete (253 → 3 hits in 850ms)` 类输出。
