# 双授权开关：通知 / 剪贴板独立推送

**日期：** 2026-07-31  
**状态：** 已批准（用户确认：仅本机向外推送；迁移时两开关都开；开始实现）

## 目标

1. 安卓离线时通知入本地持久化队列，连上授权对端后补发未 ACK 消息（现有队列保留并按通知授权过滤）。
2. 授权设备列表拆成两个独立开关：**同步剪贴板**、**同步通知**；仅本机勾选控制向外推送，对端无需勾选即可接收。

## 非目标

- 不改为双向同意模型。
- 不改动同步协议帧格式。
- 不把全局「启用局域网同步」拆掉（仍作连接/发现总开关；通知 fanout 可在总开关开启时按通知列表推送）。

## 数据模型

| Key | 含义 |
|-----|------|
| `clipboardSyncPeerIds` | 允许本机向其推送剪贴板/历史的 peerId 列表 |
| `notificationSyncPeerIds` | 允许本机向其推送通知的 peerId 列表 |
| `authorizedPeerIds` | **兼容派生**：两列表并集（读写时优先写新 key；旧 key 仅作迁移源） |

### 迁移

一次性：`clipboardSyncPeerIds` / `notificationSyncPeerIds` 均复制自现有 `authorizedPeerIds`（两开关都开），打迁移标记后不再覆盖用户后续修改。

## 推送规则

- `history` / 剪贴板：`targets ⊆ clipboardSyncPeerIds`
- `notif.post` / `notif.dismiss` / `notif.clear` / `notif.config`：`targets ⊆ notificationSyncPeerIds`
- `notif.ack`：不要求授权列表（保持现有）
- 离线入队：剪贴板帧按 clipboard 列表；通知帧按 notification 列表（及现有 SQLite `pending_notification_sync`）
- 重连 flush：仅向对应能力列表中的 peer 补发

## UI

每台发现设备一行展示两个开关（剪贴板 / 通知），文案更新说明「仅本机勾选即可向外推」。离线已授权设备：任一开关曾开过（在并集中）即可显示并可删除（从两列表同时移除）。

## 平台范围

Android（设置页授权区）+ macOS（SettingsView 授权区）+ 两侧 SyncManager / Preferences。
