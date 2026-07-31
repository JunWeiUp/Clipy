# 设备发现策略分析：是否在主动扫描时跳过已知 peer

## 背景

用户提出：既然对方主动扫描并连接到我时，我已经能被动记录对方（四要素齐全），那么在主动扫描时是否应该跳过这些"已确认存在"的设备，以省电、减少网络噪音？

## 结论：不建议增加该逻辑，保持现状

核心诉求（被连接即发现对方）**已经实现**，无需改动即可满足。而"扫描时跳过已知 peer"的优化**收益微乎其微，但显著增加代码复杂度和出错风险**。

## 现状分析（基于代码探索）

### 被动发现已完整实现（两端对称）
当设备 X 主动连到我，我在收到 `handshake/hello` 的瞬间即记录 X：
- **Mac** [SyncManager.swift:1282-1301](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L1282-L1301)：从 accept 得到的对端 IP + 信封 deviceId + payload(name/port) → `recordDiscoveredPeer`
- **Android** [sync_manager.dart:758-776](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L758-L776)：从 `socket.remoteAddress.address` + deviceId + payload → `_recordDiscoveredPeer`

### 主动扫描 vs 保活探测 职责分离
| 机制 | 触发时机 | 职责 |
|------|---------|------|
| 主动扫描（scanSubnets） | 启动/刷新/网络变化/唤醒 | **发现新设备**（全 /24 子网枚举 1-254） |
| 保活探测（probeDiscoveredPeers） | 每 45s 定时 | **验证已知 peer 是否存活**，连续 3 次失败驱逐 |

- Mac 保活：[SyncManager.swift:625-715](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift#L625-L715)
- Android 保活：[sync_manager.dart:414-435](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart#L414-L435)

关键点：**已知 peer 的存活检测由保活探测独立负责，不依赖主动扫描。** 因此跳过已知 peer 的 IP 不会影响保活。

## 为什么不建议加"跳过已知 IP"逻辑

### 1. 收益微乎其微
- 子网扫描并发 16、超时 1s，扫完 254 个 IP 约 16 批 × 1s ≈ 16s。
- 跳过 2-3 个已知 peer 仅省 1-2 秒，用户无感知。
- 省电效果同样可忽略（16 个并发短连接的总能耗极低，且扫描频率本就很低：仅在启动/网络变化/唤醒时触发）。

### 2. 代码复杂度与出错风险显著
要正确实现"跳过已知 IP"，需要：
- 维护 `{peerId -> host}` 映射，扫描时实时计算"已知 IP 集合"并从候选列表剔除。
- peer 被驱逐时同步移除其 IP（否则换 IP 的设备无法被重新发现）。
- peer 的 IP 由 DHCP 分配，会变化（续约/重连）。若因"已知该 peerId"而跳过其**旧 IP**，则新设备用新 IP 入网时反而漏扫——逻辑反直觉。
- 扫描时只认 IP 不认 peerId，必须握手后才知道某 IP 对应哪个 peer。所谓"跳过已知 peer 的 IP"本质是"跳过已知 IP"，而 IP 与 peerId 的映射随时间漂移，维护成本高。

### 3. 主动扫描的不可替代价值
主动扫描的目标是发现"**还没连过我的新设备**"。它是网络冷启动时唯一的发现手段。保持全量扫描能确保：
- 新入网设备能被发现。
- 长时间不主动连我的设备（如另一台 Android 后台静默）仍能被我唤醒发现。
- 单向 NAT/防火墙场景下（对方连不到我，但我能连到对方）仍能建立连接。

## 验证方式（无需改代码，直接验证现状即可满足诉求）

1. 设备 A、B、C 三台，B 先主动扫描发现 A 并建立握手 → A 应已记录 B（无需 A 主动扫描）。
2. 检查日志：A 端应出现 `Discovered peer via handshake: ... B`，且时间戳早于 A 的下一次 `Subnet scan`。
3. Mac 菜单「局域网设备」、Android 授权设备列表应即时显示 B。

## 建议

**保持现状，不改动任何代码。** 被动发现已满足"被连接即发现对方"的诉求；主动扫描维持全量枚举，确保新设备可发现性与代码简洁性。若后续出现明显的电量/性能问题（目前未观察到），再针对性优化。
