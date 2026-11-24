# macOS Sync Module (`clipy_macos/Sources/Sync/`)

> L1 领域胶囊 · 负责 LAN 直连发现、Protocol v3 帧编解码、AES-GCM 加密、落库后 ACK、文件/文件夹传输与 Common Relay v1 接入。

## 文件分工

- `SyncManager.swift`：门面（生命周期、广播编排、入站分发、LAN/Relay 3s 快速切换）。
- `SyncProtocol.swift` & `SyncCrypto.swift`：Protocol v3 `SyncEnvelope` / `SyncType` / 4 字节大端长度帧 + 内置 AES-GCM。
- `SyncDiscovery.swift` & `SyncTransport.swift`：`/24` 子网发现、手动 IP、非阻塞 TCP 会话管理。
- `SyncReliability.swift` & `PendingSyncRepository.swift`：先落库再 ACK、离线持久化待发队列。
- `SyncFileTransfer.swift` & `FolderTransferArchive.swift`：1 MiB 分块文件传输、SHA-256 校验、流式 `zip-store-v1` 文件夹还原。
- `SyncRelayClient.swift` / `SyncRelayGroups.swift` / `SyncRelaySettings.swift`：对接 `packages/relay-swift`（`JunWeiUp/common-relay` SDK）。

## 必须守住的边界

- **线程与锁**：Socket 读写在 `syncQueue`，文件收发走独立队列（接收完成走 `fileReceiveQueue` 防双向发送互锁）。
- **协议同步**：修改帧类型或字段必须同步更新 `clipy_flutter/lib/sync/protocol.dart`、`docs/architecture/PROTOCOL.md` 与共享契约 `scripts/fixtures/protocol_v3_fixtures.json`。
- **验证**：`bash scripts/check.sh repo`（自动跑 `ProtocolV3ContractRegression`）+ `bash scripts/test_macos_core.sh`。
