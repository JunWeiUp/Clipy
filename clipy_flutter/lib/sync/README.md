# Flutter Sync Module (`clipy_flutter/lib/sync/`)

> L1 领域胶囊 · 负责 Android / Windows / iOS 共享的 Protocol v3 同步引擎与 Common Relay v1 接入。

## 结构（`../sync_manager.dart` + `part` 拆分）

- `../sync_manager.dart`：门面、状态字段、启停生命周期、配置更新与中继装配。
- `discovery.dart` / `discovery_scan.dart` / `discovery_refresh.dart`：`/24` 子网扫描、缓存探测、刷新合并。
- `session.dart` / `session_policy.dart`：TCP 会话建立、握手与冲突仲裁。
- `network_recovery.dart` / `network_handoff.dart`：网络变化监听、3s 心跳探测、LAN/Relay 快速切换。
- `frame_dispatch.dart`：入站帧路由、历史 catch-up 批量合并、ACK 与广播。
- `reliability.dart` / `text_delivery_receipts.dart`：落库后 ACK、待发队列重试与显式发送回执。
- `file_transfer.dart` / `file_receive_flow_control.dart` / `file_send_cancellation.dart`：1 MiB 分块流式加解密、双槽背压防 OOM、取消清理。
- `protocol.dart` & `crypto.dart`：Protocol v3 线协议与 AES-GCM（Android 经 `nativeAesGcm` 钩子走硬件加速）。
- `relay_client.dart` / `relay_groups.dart` / `relay_configuration.dart` / `relay_identity.dart`：对接官方 `common_relay` Dart SDK。

## 必须守住的边界

- **禁止重放死循环**：远端入站内容必须先持久化再 ACK，且不得再次触发本机广播。
- **目录约束**：同步新增逻辑一律放在 `lib/sync/`，禁止在 `lib/` 根目录新增散落文件。
- **验证**：`bash scripts/check.sh flutter`（包含 `test/protocol_v3_contract_test.dart` 与全部同步单测）。
