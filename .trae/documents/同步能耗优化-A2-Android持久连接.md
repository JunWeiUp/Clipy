# 同步能耗优化 · A-2：Android `sync_manager.dart` 持久连接改造

> 本计划是已批准的 `同步能耗优化方案-v2.md` 的 **A-2 子步骤**（A-1 macOS 已完成）。
> 用户已明确指示"开始执行吧，不要再计划了"，故本文件只锁定 A-2 的最小可执行变更，不重新讨论 A/B/C 总体设计。

## 目标（Why）
- 降低能耗：**移除 300s 周期性探活定时器**（`_startPeerPresenceProbing`），设备在线状态改由持久连接存活状态推导，设备列表改为打开页面时按需刷新。
- 提高投递可靠性：握手成功后**复用** TCP 连接（避免每条消息一次 connect/close），连接断开时**指数退避自愈重连**，失败仍走现有 pendingQueue。
- 与 macOS 端拓扑对称：双向独立出站，每对设备最多 2 条连接。

## 现状确认（已读代码，Phase 1）
文件：`clipy_android/lib/sync_manager.dart`
- L185-198：`_pendingQueue`（30s 内存队列，per-peer cap 50）、`_peerPresenceInterval=300s`。
- L462-472：`_startPeerPresenceProbing` / `_stopPeerPresenceProbing`，`Timer.periodic` 跑 `_probeDiscoveredPeers`。
- L476-497：`_probeDiscoveredPeers` 逐个 `_connectToPeer` 探活。
- L557-573 `start()`：L562 调 `_startPeerPresenceProbing()`（**待删除**）。
- L575-592 `stop()`：清理点。
- L728-793 `_handleConnection`：入站连接的 `await for (data in socket)` 循环 + `finally{socket.destroy()}` —— 持久出站接收循环的复用蓝本。
- L886-906 `_recordDiscoveredPeer`：发现 peer 钩子，已调用 `_flushPendingQueue`。
- L1138-1173 `_performHandshake`：成功后 `finally{socket.destroy()}`（**破坏复用，需改**）。peerId 从握手响应 `message.deviceId` 获得。
- L1683-1699 `_sendSync`：每次 `_connectToPeer` → write → close（**改为命中持久连接直写**）。
- 关键约束：Dart 单线程事件循环 → `_persistentConnections` 等 Map **无需加锁**（与 macOS `syncQueue` 不同）。

## 变更清单（What / How）

### 1. 新增状态字段（约 L198 `_peerPresenceInterval` 之后）
```dart
/// peerId → 本端出站持久连接。握手成功后复用，避免每条消息一次 TCP 建连。
final Map<String, Socket> _persistentConnections = {};
/// peerId → 当前退避秒数；成功后清零，失败翻倍至上限。
final Map<String, int> _reconnectBackoffSec = {};
/// 进行中的重连 Future 去重，避免重复调度。
final Map<String, Future<void>> _activeReconnects = {};
static const int _keepaliveIdleSec = 60;
static const int _keepaliveIntervalSec = 30;
static const int _maxReconnectBackoffSec = 30;
```

### 2. 改造 `_performHandshake`（L1138-1173）
- 成功读到握手响应并 `_handleSyncMessage` 后，**不再** `finally destroy`。
- 由 `message.deviceId` 取 `peerId`：
  - 若 `_persistentConnections[peerId]` 已存在且未关闭 → 销毁新重复 socket，返回 true（幂等）。
  - 否则：启用 keepalive（best-effort，见 §6）、存入 `_persistentConnections[peerId]`、`_reconnectBackoffSec[peerId]=0`、启动持久接收循环 `_runPersistentReceive(peerId, socket)`。
- 失败路径（连接失败/读超时/解析异常）保留 `socket.destroy()` 并返回 false。
- 连接失败（catch 到 connect 异常）不变。

### 3. 新增持久接收循环 `_runPersistentReceive(peerId, socket)`
- 复用 `_handleConnection` 的分帧逻辑（4 字节大端长度前缀），每帧 `await _handleSyncMessage(message, socket: socket)`。
- `await for` 正常结束或抛错 → 调用 `_onPersistentSocketDown(peerId)`。

### 4. 新增 `_onPersistentSocketDown(peerId)` / `_teardownPersistentConnection(peerId)` / `_scheduleReconnect(peerId)`
- `_teardownPersistentConnection`：从 Map 移除、`socket.destroy()`（try/catch）。
- `_onPersistentSocketDown`：teardown → `_scheduleReconnect(peerId)`。
- `_scheduleReconnect`：若 `!isEnabled` 或 peer 未授权或已有活跃重连或已有 live 连接 → 跳过；否则取 `backoff = min((_reconnectBackoffSec[peerId] ?? 1), _maxReconnectBackoffSec)`，`Future.delayed(backoff s)` 后：仍无 live 连接则按已知 endpoint（`_discoveredPeers[peerId]`）定向握手；endpoint 缺失则 `triggerCrossBandDiscovery()`。成功→清零 backoff；失败→`backoff*2`（上限 30）。

### 5. 改造 `_sendSync`（L1683-1699）
- 命中 `_persistentConnections[peer.peerId]` 且未 done → 直接 `_writeFrame` + flush（**不 close**）；写失败 → `_teardownPersistentConnection` + 返回 false（由 `_dispatchBroadcast`/`_rescanThenRetry` 走重扫/排队，与现状一致）。
- 未命中 → 保留现有 one-shot `_connectToPeer` → write → close 路径（向下兼容；持久连接由发现扫描建立，`_rescanThenRetry` 的 on-demand 扫描负责在 send 失败时 promote）。

### 6. keepalive（best-effort，Android=Linux 常量）
```dart
void _tryEnableKeepalive(Socket socket) {
  if (!Platform.isAndroid) return;
  try {
    // Linux: SOL_SOCKET=1, SO_KEEPALIVE=9, IPPROTO_TCP=6,
    //        TCP_KEEPIDLE=4, TCP_KEEPINTVL=5
    socket.setRawOption(RawSocketOption.fromInt(1, 9, 1));
    socket.setRawOption(RawSocketOption.fromInt(6, 4, _keepaliveIdleSec));
    socket.setRawOption(RawSocketOption.fromInt(6, 5, _keepaliveIntervalSec));
  } catch (_) { /* 平台差异时静默降级：依赖前台服务 + send 失败检测自愈 */ }
}
```

### 7. 移除周期探活定时器
- `start()`（L562）：删除 `_startPeerPresenceProbing();` 调用。
- 保留 `_startPeerPresenceProbing`/`_stopPeerPresenceProbing`/`_probeDiscoveredPeers` 方法本体（供 UI 页面打开时按需手动触发刷新，见 A-3）；`stop()` 仍调用 `_stopPeerPresenceProbing()` 清理定时器（幂等）。

### 8. 更新 `stop()`（L575-592）
- 清理 `_persistentConnections`：逐个 destroy + clear；清空 `_reconnectBackoffSec` / `_activeReconnects`。
- 其余清理保持不变。

### 9. 网络变更钩子（`_startConnectivityMonitoring` 回调内，已有）
- 在现有网络恢复回调里：遍历 `_persistentConnections` 的 peerId，对无 live 连接的授权 peer 调 `_scheduleReconnect`（已具备去重）。

## 不在本次范围（明确排除）
- ❌ A-3 设备列表按需刷新的双端 UI 改动（独立步骤）。
- ❌ 改动 C（`clipboard_manager.dart` / `notification_health_monitor.dart` 去定时器）。
- ❌ 改动 B（`message/ack` + 持久化投递）。
- ❌ iOS / 桌面 keepalive（仅 Android `Platform.isAndroid` 生效）。
- ❌ 文件传输路径（`_sendFileSync` 等保持 one-shot，与 macOS 一致）。

## 假设与决策
1. **Dart 单线程** → 持久连接 Map 无锁；与 macOS `syncQueue` 串行隔离设计不同，无需 queue hop。
2. **`_sendSync` 复用而非建连**：发现扫描（含 `_rescanThenRetry` 的 on-demand 扫描）负责建立持久连接；send 命中即复用，未命中走 one-shot。这是相对 macOS "send 即建连" 的有意简化，降低改动面，功能等价（失败仍有 rescan 兜底）。
3. **keepalive 常量硬编码 Linux 值**：仅 Android 生效，try/catch 容错；半开检测兜底为 send 失败 → teardown → 重连。
4. **`_probeDiscoveredPeers` 方法保留**：A-3 将改为 UI 打开页面时手动调用，本次仅停掉周期触发。

## 验证步骤
1. `cd clipy_android && flutter analyze lib/sync_manager.dart` —— 0 error。
2. `flutter build apk --debug` —— 构建通过。
3. 手动联调（如条件允许）：Mac 复制 → Android 后台秒级收到；Android 杀掉 Mac 端 → Android 侧连接 teardown 并在 backoff 后自愈重连；Android 灭屏期间前台服务保持，复制仍可达。
