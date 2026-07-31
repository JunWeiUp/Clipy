# 完成 Android 端 hasOutbound 字段实现（与 macOS 对称）

## Summary

延续上一轮会话的工作。降低 Mac ↔ Android 通信频次与协议优化的主体改造（阶段 1.1-1.6、阶段 3.1-3.2、阶段 2.1、阶段 2.2 的 macOS 端）已全部完成。剩余仅阶段 2.2 的 Android 端镜像实现：在 `clipy_android/lib/sync_manager.dart` 的握手协议中加入 `hasOutbound` 字段，与 macOS 端对称，保持双端协议兼容。

完成后还需运行双端编译验证。

## Current State Analysis

### 已完成（来自上一轮会话）
- **阶段 1.1**：Android `didChangeAppLifecycleState` 合并为单一发现路径（只调 `_probeDiscoveredPeers()`），见 [sync_manager.dart:324-335](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L324-335)
- **阶段 1.2**：Android `_startConnectivityMonitoring` 只调 `refreshDiscovery()`，删除 `scheduleReconnect` 循环，见 [sync_manager.dart:296-316](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L296-316)
- **阶段 1.4**：`_probeDiscoveredPeers()` 跳过已持久连接的 peer
- **阶段 1.5**：`_scanSubnets` 构建 `connectedHosts` set 过滤 + 5s `_handshakeDedupTtl` 去重缓存，见 [sync_manager.dart:1214-1230](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L1214-1230)
- **阶段 1.6**：`_recordPeerMiss` 不立即触发 `triggerCrossBandDiscovery()`
- **阶段 3.1**：Android keepalive `60s/30s → 120s/60s`，见 [sync_manager.dart:225-226](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L225-226)
- **阶段 3.2**：Android subnet scan debounce `400ms → 800ms`
- **阶段 2.1**：Android lifecycle resume 已不再调 `scheduleReconnect`
- **阶段 2.2 macOS 端**：
  - `HandshakePayload` 增加 `hasOutbound: Bool` 字段，自定义 `init(from:)` 用 `decodeIfPresent` 默认 false（兼容旧端），见 [SyncManager.swift:1347-1365](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1347-1365)
  - `makeHandshakeFrame(type:hasOutbound:)` 增加 hasOutbound 参数（默认 false），见 [SyncManager.swift:1832](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1832)
  - `handleHandshakeHello` 计算 `alreadyConnected` 并在 hi 中传 `hasOutbound: alreadyConnected`，见 [SyncManager.swift:1854-1876](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1854-1876)
  - `handleHandshakeHi` 只记录日志，**不销毁连接**（拓扑安全考虑），见 [SyncManager.swift:1878-1898](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1878-1898)

### 待完成
- **阶段 2.2 Android 端**：`_makeHandshakeJson` / `_handleHandshakeHello` / `_handleHandshakeHi` 三个方法的 hasOutbound 字段镜像实现
- **双端编译验证**

### macOS 端关键偏离说明（已在上一轮会话中决定）
计划原文阶段 2.2 要求"发起方收到 hi 后，若 hasOutbound=true，则销毁本次新建连接"。但双向独立 outbound 拓扑要求**双方各持有自己的 outbound 连接**用于发送。如果发起方销毁新连接，则发起方将没有 outbound 连接；同时如果双方同时握手并都销毁，会导致 0 持久连接 + 双方重试的恶性循环。因此 macOS 端 `handleHandshakeHi` 只记录日志，不销毁连接。Android 端必须保持相同语义。

## Proposed Changes

### 改动 1：`_makeHandshakeJson` 增加 hasOutbound 参数
- **文件**：`/Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart`
- **位置**：[sync_manager.dart:1525-1537](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L1525-1537)
- **当前代码**：
  ```dart
  String _makeHandshakeJson(String type) {
    final payload = jsonEncode({'name': displayName, 'port': port});
    final encrypted = _encrypt(payload);
    if (encrypted == null) return '';
    final message = SyncMessage(
      deviceId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: type,
      content: encrypted,
      hash: '',
    );
    return jsonEncode(message.toJson());
  }
  ```
- **改动后**：
  ```dart
  /// Builds an encrypted handshake JSON frame. [hasOutbound] is included in
  /// the payload for forward compatibility with the macOS side: a responder
  /// that already holds an outbound link to the initiator sets it true so the
  /// initiator can log the simultaneous-connect case for diagnostics. It does
  /// NOT trigger connection teardown — see _handleHandshakeHi.
  String _makeHandshakeJson(String type, {bool hasOutbound = false}) {
    final payload = jsonEncode({
      'name': displayName,
      'port': port,
      'hasOutbound': hasOutbound,
    });
    final encrypted = _encrypt(payload);
    if (encrypted == null) return '';
    final message = SyncMessage(
      deviceId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: type,
      content: encrypted,
      hash: '',
    );
    return jsonEncode(message.toJson());
  }
  ```

### 改动 2：`_handleHandshakeHello` 在 hi 回复中传 hasOutbound
- **文件**：同上
- **位置**：[sync_manager.dart:967-985](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L967-985)
- **当前代码**：
  ```dart
  void _handleHandshakeHello(String decrypted, String remotePeerId, Socket? socket) {
    try {
      final info = jsonDecode(decrypted) as Map<String, dynamic>;
      final name = info['name'] as String? ?? remotePeerId;
      final portValue = (info['port'] as num?)?.toInt() ?? port;
      final host = socket?.remoteAddress.address;
      if (host == null) return;
      _recordDiscoveredPeer(remotePeerId, name, host, portValue);
      // Reply with hi on the same connection so the initiator learns our identity.
      if (socket != null) {
        final hiJson = _makeHandshakeJson('handshake/hi');
        if (hiJson.isNotEmpty) {
          unawaited(_writeFrame(socket, hiJson).then((_) => socket.flush()));
        }
      }
    } catch (e) {
      appLog('Failed to decode handshake/hello: $e', level: 'warning');
    }
  }
  ```
- **改动后**：
  ```dart
  void _handleHandshakeHello(String decrypted, String remotePeerId, Socket? socket) {
    try {
      final info = jsonDecode(decrypted) as Map<String, dynamic>;
      final name = info['name'] as String? ?? remotePeerId;
      final portValue = (info['port'] as num?)?.toInt() ?? port;
      final host = socket?.remoteAddress.address;
      if (host == null) return;
      _recordDiscoveredPeer(remotePeerId, name, host, portValue);
      // Reply with hi on the same connection so the initiator learns our identity.
      // Include hasOutbound so the initiator can detect a simultaneous-connect
      // scenario for diagnostics. We do NOT tear down our just-promoted
      // connection — see _handleHandshakeHi.
      if (socket != null) {
        final alreadyConnected = _persistentConnections.containsKey(remotePeerId);
        final hiJson = _makeHandshakeJson('handshake/hi', hasOutbound: alreadyConnected);
        if (hiJson.isNotEmpty) {
          unawaited(_writeFrame(socket, hiJson).then((_) => socket.flush()));
        }
      }
    } catch (e) {
      appLog('Failed to decode handshake/hello: $e', level: 'warning');
    }
  }
  ```

### 改动 3：`_handleHandshakeHi` 读取 hasOutbound，只记录日志不销毁
- **文件**：同上
- **位置**：[sync_manager.dart:987-998](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L987-998)
- **当前代码**：
  ```dart
  void _handleHandshakeHi(String decrypted, String remotePeerId, Socket? socket) {
    try {
      final info = jsonDecode(decrypted) as Map<String, dynamic>;
      final name = info['name'] as String? ?? remotePeerId;
      final portValue = (info['port'] as num?)?.toInt() ?? port;
      final host = socket?.remoteAddress.address;
      if (host == null) return;
      _recordDiscoveredPeer(remotePeerId, name, host, portValue);
    } catch (e) {
      appLog('Failed to decode handshake/hi: $e', level: 'warning');
    }
  }
  ```
- **改动后**：
  ```dart
  void _handleHandshakeHi(String decrypted, String remotePeerId, Socket? socket) {
    try {
      final info = jsonDecode(decrypted) as Map<String, dynamic>;
      final name = info['name'] as String? ?? remotePeerId;
      final portValue = (info['port'] as num?)?.toInt() ?? port;
      final host = socket?.remoteAddress.address;
      if (host == null) return;
      _recordDiscoveredPeer(remotePeerId, name, host, portValue);
      // Note: the bidirectional-independent-outbound topology requires BOTH
      // sides to hold their own outbound link for sending, so we do NOT
      // tear down our just-promoted connection when info['hasOutbound'] is
      // true. The hasOutbound flag is logged for diagnostic purposes only;
      // the 5s handshake dedup + scanSubnets skip-connected-hosts already
      // prevent the triple-handshake bug at the source. Keep aligned with
      // the macOS side's handleHandshakeHi.
      final hasOutbound = info['hasOutbound'] as bool? ?? false;
      if (hasOutbound) {
        appLog('Peer $remotePeerId reports it already has an outbound link to us; '
            'keeping our outbound (bidirectional topology)');
      }
    } catch (e) {
      appLog('Failed to decode handshake/hi: $e', level: 'warning');
    }
  }
  ```

### 改动 4：双端编译验证
- **macOS**：`cd clipy_macos && swift build`（或 Xcode build）
- **Android**：`cd clipy_android && flutter analyze`（如条件允许再加 `flutter build apk`）

## Assumptions & Decisions
- **协议兼容**：`hasOutbound` 字段在 Android JSON 中使用 `info['hasOutbound'] as bool? ?? false` 读取，旧 macOS 端不发送该字段时默认 false，行为不变
- **拓扑安全**：Android 端与 macOS 端保持一致，`_handleHandshakeHi` 收到 hasOutbound=true 时**只记录日志，不销毁连接**。原因：双向独立 outbound 拓扑要求双方各持自己的 outbound；若销毁会导致发起方无 outbound 可用，且双方同时销毁会陷入 0 连接 + 双方重试的恶性循环
- **去重依赖前置防线**：5s 握手去重缓存（`_handshakeDedupTtl`）+ `scanSubnets` 跳过 `connectedHosts` 已在阶段 1.5 实现，从源头消除 200ms 三次握手；hasOutbound 仅作为诊断信号保留
- **不动其他逻辑**：`_performHandshake` 中调用 `_makeHandshakeJson('handshake/hello')` 不传 hasOutbound（保持默认 false，因为发起 hello 时本端的 outbound 尚未 promote，符合原计划语义）
- **阶段 2.3 tie-breaking**：保持标记为可选，不实施

## Verification

1. **静态检查**：
   - `cd clipy_android && flutter analyze` 无新增 error/warning
   - `cd clipy_macos && swift build` 编译通过
2. **协议对称性**：grep 双端 `hasOutbound` 字段，确认 macOS `HandshakePayload` / `makeHandshakeFrame` / `handleHandshakeHello` / `handleHandshakeHi` 与 Android `_makeHandshakeJson` / `_handleHandshakeHello` / `_handleHandshakeHi` 字段名、默认值、语义一致
3. **回归验证**（用户在真实环境执行）：
   - 重启两端，复制文本 Mac→Android、Android→Mac 都能正常同步
   - 观察日志：同一对端在 1s 内只应出现 1 条 `Discovered peer via handshake` 日志
   - 同时握手时（双方同时 foreground）应看到 `reports it already has an outbound link to us; keeping our outbound` 日志，且连接不被销毁

## Implementation Order

1. 改动 1：`_makeHandshakeJson` 增加 hasOutbound 参数
2. 改动 2：`_handleHandshakeHello` 在 hi 中传 hasOutbound
3. 改动 3：`_handleHandshakeHi` 读取 hasOutbound，只记录日志
4. 改动 4：运行 `flutter analyze` + `swift build` 验证编译
5. 返回最终响应给用户，说明已完成 + hasOutbound 销毁逻辑偏离原计划的原因
