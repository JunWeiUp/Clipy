# 跨频段（2.4G / 5G）数据同步修复方案

## 摘要

当前 Android 与 Mac 之间的剪贴板/通知同步依赖 mDNS / Bonjour 多播做服务发现。家用路由器在双频段（2.4G 与 5G）之间默认不转发多播/广播包，导致跨频段时双方发现不到彼此，TCP 传输虽可达却无法发起。本方案在不破坏现有 mDNS 路径的前提下，新增两条「不依赖多播」的发现通道：

1. **子网扫描发现**（自动、无感）：枚举本机所在 IPv4 /24 子网，并发 TCP 探测同步端口，连上后通过加密握手帧交换身份，覆盖 80%+ 的「同子网、多播隔离」场景。
2. **手动添加设备**（兜底）：设置界面允许用户显式录入对端 `IP:端口`，覆盖跨子网/严格隔离场景。

两条新通道复用现有 AES-GCM 加密、`authorizedPeerIds` 授权模型、离线重投递队列与存活探测，确保已授权的扫描/手动 peer 与 mDNS peer 行为完全一致。

---

## 根因分析

| 维度 | 现状 | 影响 |
|---|---|---|
| 服务发现 | 仅 mDNS / Bonjour（`_clipy-sync._tcp`，域 `local.`），多播地址 `224.0.0.251` | 多播工作在 L2 广播域；路由器 2.4G↔5G 多播隔离 → 跨频段发现失败 |
| 传输层 | TCP `0.0.0.0:5566` 全接口监听（[sync_manager.dart:749](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/sync_manager.dart)） | 跨频段 TCP 单播**本身可达**，问题只在「拿不到对端 IP」 |
| 网络感知 | `NWPathMonitor` / `connectivity_plus` 仅感知本机网络变化 | 无法绕过多播隔离，只是重跑 mDNS 浏览，仍失败 |
| 兜底机制 | 无 IP 扫描、无手动 IP 配置、无子网定向探测 | 多播一旦隔离即无解 |

**结论**：传输层无故障，缺陷在发现层。修复方向 = 增加不依赖多播的发现通道。

---

## 解决方案设计

### 核心思路

保留 mDNS 为首选发现（同频段/正常多播环境下零成本可用），在其之上叠加：
- **子网扫描**：自动发现同子网内运行 Clipy 的设备
- **手动添加**：用户显式指定对端地址

两种新通道产出的 peer 统一注入现有 `discoveredPeers` 字典（以 `peerId` 为 key，天然与 mDNS 结果合并去重），后续的 `dispatchBroadcast` fan-out、存活探测、离线队列、授权校验全部复用现有逻辑，**不改变同步语义**。

### 握手协议（关键新增）

子网扫描与手动添加只能拿到「裸 IP:端口」，没有 peerId。新增两条握手消息，复用现有 `SyncMessage` 结构 + AES-GCM 加密，不引入明文风险：

- `handshake/hello`：`content` = 加密的 `{"name":"<displayName>","port":<自己的监听端口>}`，`deviceId` = 自己的 peerId
- `handshake/hi`：`content` = 加密的 `{"name":"<displayName>","port":<监听端口>}`，`deviceId` = 自己的 peerId

**流程**：
1. 发起方 TCP 连上对端 `IP:port`
2. 发起方发 `handshake/hello`
3. 接收方收到 → 解密校验（密钥错误则静默关闭，等同于现有未授权连接处理）→ 取对端 `NWConnection.endpoint` / `Socket.remoteAddress` + content 里的 port 构造 endpoint → 以 `deviceId` 为 key 写入 `discoveredPeers` → 回 `handshake/hi`
4. 发起方收到 `hi` → 同样记录对端 → 触发 `peersChanged` 通知 + `flushPendingQueue` + `_backfillPendingNotifications`

握手帧与现有数据帧走同一 TCP 连接、同一分帧协议（4 字节大端长度前缀），复用 `ingestReceivedData` / `_handleClient` 的接收路径，无需新开监听端口。

> 兼容性：旧版本不识别 `handshake/*` 类型，会走「未知类型忽略」分支（现有代码已对未知 type 做忽略），不会崩溃。新版本对旧版本不会主动发握手（mDNS 路径不变），仅扫描/手动路径发。

### 子网扫描发现（双端对称）

**子网枚举**（标准档位，用户已确认）：
- 枚举本机所有非环回、非 VPN 的 IPv4 地址
- 每个地址假设 `/24` 前缀（覆盖 95%+ 家用场景），计算 `x.y.z.1 ~ x.y.z.254`，排除自己的最后一段
- 多接口（如同时有以太网 + Wi-Fi）合并扫描

**探测参数**：
- 并发上限：16
- 单连接超时：300ms
- 端口：本机配置的 `syncPort`（默认 5566）——假设对端也用默认端口；非默认端口由「手动添加」兜底
- 总耗时：约 5 秒（/24 ≈ 254 IP）

**触发时机**：
- `start()` 启动后
- `refreshDiscovery()` / `refreshBrowsing()`（网络变化、系统唤醒、App 恢复、2 分钟看门狗）
- 与 mDNS 浏览并行，互不阻塞

**实现要点**：
- macOS：用 `getifaddrs()` 精确获取 IPv4 + 掩码（可超越 /24 假设）；并发用 `DispatchQueue.concurrentPerform` 或受控的 `DispatchSemaphore`
- Flutter：用 `NetworkInterface.list(type: InternetAddressType.IPv4)` 拿地址（dart:io 不直接暴露掩码，采用 /24 假设，代码注释标注限制）；并发用 `Pool` 或手写信号量

### 手动添加设备（双端）

**存储**：
- macOS `PreferencesManager`：新增 key `manualSyncPeers`，存 `[String]`（格式 `host:port`，如 `192.168.1.20:5566`）
- Flutter `SharedPreferences`：同 key `manualSyncPeers`

**连接**：启动/刷新时对每个 manualPeer 走握手流程，成功则加入 `discoveredPeers`，失败静默（用户可删除重添）。

**UI**：设置界面「同步」分区下新增：
- 「添加设备」按钮 → 弹窗输入 IP + 端口（端口默认 5566，带校验：合法 IPv4 + 1~65535）
- 已添加设备列表（显示 `host:port` + 在线状态指示），支持左滑/点击删除

### 融入现有同步流程（零侵入）

| 现有机制 | 对扫描/手动 peer 的处理 |
|---|---|
| `discoveredPeers` 字典 | 以 `peerId` 为 key 合并，覆盖 mDNS 结果（同一 peer 多源发现只保留一份） |
| `availablePeers` getter | 自动包含，UI 设备列表自动显示 |
| `authorizedPeerIds` | 扫描/手动发现的 peer 同样需用户在设备列表勾选授权后才接收/发送数据 |
| `dispatchBroadcast` fan-out | 无需改动，自动向所有已授权在线 peer 发送 |
| 存活探测（45s × 3） | 对扫描/手动 peer 同样生效，连续失败驱逐 |
| 离线重投递队列 | peer 重新上线（再次扫描到/握手成功）时 `flushPendingQueue` |
| 加密 | 握手帧与数据帧均走 AES-GCM，未授权方解密失败被静默拒绝 |

---

## 具体改动清单（文件级）

### macOS 端

**1. `clipy_macos/Sources/SyncManager.swift`**
- `processReceivedData`（约 line 983）新增 `handshake/hello` / `handshake/hi` 分支：
  - 收到 hello → 解密 → 构造 `DiscoveredPeer`（endpoint 取自当前 `NWConnection.endpoint`，转 `NWEndpoint.hostPort`）→ 写入 `discoveredPeers` → 回 hi → 触发 `syncAvailableDevicesDidChange` + `flushPendingQueue` + 通知回填
  - 收到 hi → 解密 → 记录 peer → 触发 peersChanged
- 新增 `SubnetScanner`（可内联为私有方法或独立 struct）：
  - `enumerateLocalSubnets()`：`getifaddrs()` 遍历，过滤 AF_INET、非环回、接口名前缀 `en`/`wlan`，返回 `[(network: in_addr, mask: in_addr)]`
  - `scanSubnets()`:对每个 CIDR 并发 TCP 探测 5566，成功则发 `handshake/hello`
- 新增 `manualPeers` 加载（从 `PreferencesManager.manualSyncPeers`）+ `connectManualPeers()`：对每个 `host:port` 建连并发 hello
- `start()`（line 461）、`refreshDiscovery()`（line 549）中并行触发 `scanSubnets()` + `connectManualPeers()`
- 新增 `sendHandshake(to endpoint:)`：构造 hello `SyncMessage`（加密 content）→ 复用 `sendSync` 发送

**2. `clipy_macos/Sources/PreferencesManager.swift`**
- 新增 `manualSyncPeers: [String]`（get/set，key `"manualSyncPeers"`，默认 `[]`）
- 新增 `addManualPeer(_:)` / `removeManualPeer(_:)` 便捷方法

**3. `clipy_macos/Sources/UI/SettingsView.swift`**
- 「同步」分区新增「手动添加设备」子区：
  - 添加按钮 + 弹窗（IP 文本框 + 端口数字框，默认 5566，提交前格式校验）
  - 已添加设备 `List`（`host:port` + 在线状态），支持删除

### Flutter 端

**1. `clipy_android/lib/sync_manager.dart`**
- `DiscoveredPeer`（line 125）新增可选字段 `String? host` / `int? port`，保持 `service` 可空化（nsd 来源与直连来源二选一）
- `_connectToService(Service)` 泛化为 `_connectToPeer(DiscoveredPeer)`：若 peer.host != null → `Socket.connect(host, port)`；否则走原 nsd `resolve(service)` 路径
- `_sendSync(jsonData, peer.service)` → `_sendSync(jsonData, DiscoveredPeer)`，内部调用 `_connectToPeer`；同步更新 `_dispatchBroadcast`（line 328）、`_flushPendingQueue`（line 380）调用点
- 消息分发（line 849 附近）新增 `handshake/hello` / `handshake/hi` 处理：对称于 macOS，用 `socket.remoteAddress` + content.port 构造 peer
- 新增子网扫描：
  - `_enumerateLocalSubnets()`：`NetworkInterface.list(type: InternetAddressType.IPv4)`，过滤环回，按 /24 生成候选 IP 列表
  - `_scanSubnets()`：并发（信号量 16）`Socket.connect(ip, port, timeout: 300ms)`，成功则发 hello
- 新增 `manualPeers` 加载（SharedPreferences `manualSyncPeers`）+ `_connectManualPeers()`
- `start()`（line 530）、`refreshBrowsing()`（line 701）并行触发扫描 + 手动连接
- `init()`（line 247）读取 `manualSyncPeers`

**2. `clipy_android/lib/main.dart`**
- Settings 页（同步分区，约 line 659/1030/1202 附近）新增「手动添加设备」UI，结构对齐 macOS 端：添加弹窗 + 设备列表 + 删除

### 不需要改动的部分

- `notification_manager.dart`：通知同步出口/入口完全走 `SyncManager`，peer 来源透明，无需改动
- 加密、分帧、文件传输、存活探测、离线队列：均复用，无改动
- iOS `Info.plist` / macOS `Info.plist`：不新增权限（仍是局域网 + Bonjour 声明，扫描走出站 TCP 连接，无需额外授权）

---

## 兼容性测试计划

### 环境矩阵

| # | 场景 | Android | Mac | 预期 |
|---|---|---|---|---|
| T1 | 同频段 2.4G | 2.4G | 2.4G | mDNS 正常，扫描冗余但不冲突 |
| T2 | 同频段 5G | 5G | 5G | 同上 |
| T3 | **跨频段（目标场景）** | 2.4G | 5G | 子网扫描发现，同步正常 |
| T4 | **跨频段（反向）** | 5G | 2.4G | 同 T3 |
| T5 | 跨频段 + AP 隔离开启 | 2.4G | 5G | 扫描发现（TCP 单播不受多播隔离影响） |
| T6 | 跨子网（2.4G/5G 不同网段） | 192.168.0.x | 192.168.1.x | 扫描失败，手动添加成功 |
| T7 | 旧版本互通 | 新版 Android | 旧版 Mac（无握手） | mDNS 路径正常；扫描连上旧版后握手被忽略，不崩溃 |
| T8 | 未授权对端 | 扫描到陌生设备 | — | 不在 `authorizedPeerIds` 内，不收发数据 |
| T9 | 企业网络（IDS 监控） | /24 扫描 | — | 验证扫描流量可接受，无异常告警 |
| T10 | DHCP 续约导致 IP 变化 | IP 变更 | — | 下次刷新重新扫描发现，旧 peer 被存活探测驱逐 |

### 功能测试点

- [ ] 跨频段下文本剪贴板双向同步
- [ ] 跨频段下文件传输（分块传输）
- [ ] 跨频段下通知镜像（post/dismiss/clear_all + ACK 回填）
- [ ] 跨频段下离线重投递：A 离线时 B 复制 → A 上线后收到
- [ ] 手动添加：IP/端口格式校验（非法 IPv4、超范围端口、重复添加）
- [ ] 手动添加设备删除后立即停止同步
- [ ] 扫描发现的 peer 需用户授权后才生效
- [ ] 同一 peer 被 mDNS + 扫描同时发现时无重复、无抖动
- [ ] 扫描期间 CPU/内存/耗电在可接受范围（< 5% CPU 峰值，扫描 < 5s）

### 回归测试

- [ ] 同频段下原有 mDNS 同步无回归
- [ ] iOS ↔ macOS（Flutter iOS 端）同步无回归
- [ ] Android ↔ Android 同步无回归

---

## 上线验证标准

### 必达（P0）
1. T3/T4 跨频段场景下，双方设备列表在 **10 秒内**互相出现（扫描 + 握手完成）
2. 跨频段下文本/文件/通知三类数据双向同步成功率 ≥ 99%
3. 同频段场景无回归（T1/T2 与改动前行为一致）
4. 旧版本互通无崩溃（T7）

### 重要（P1）
5. 手动添加设备在跨子网场景（T6）下 100% 可用
6. 扫描期间无可感知的性能劣化（菜单响应、复制延迟）
7. 未授权陌生设备无法触发任何数据收发（T8）

### 监控（P2）
8. 扫描日志可观测（记录发现的 peer 来源：mDNS/scan/manual）
9. 用户反馈渠道收集中，跨频段相关投诉归零

---

## 假设与决策

1. **`/24` 子网假设**：用户已选「标准:仅本机子网」。macOS 端用 `getifaddrs()` 精确拿掩码；Flutter 端因 dart:io 不暴露掩码，采用 `/24` 假设并注释。覆盖 95%+ 家用场景，企业非 /24 网络由手动添加兜底。
2. **端口假设**：子网扫描探测本机配置的 `syncPort`（默认 5566），假设对端同端口。非默认端口由手动添加指定。两端都改了非默认端口的极少数场景，扫描可能漏发现，可接受。
3. **握手帧加密**：复用 AES-GCM + 预共享密钥，不引入明文身份泄漏，且未授权方解密失败被静默拒绝（与现有数据帧一致）。
4. **向后兼容**：旧版本不识别 `handshake/*`，走未知类型忽略；新版本不会经 mDNS 路径对旧版本发握手，仅扫描/手动路径发起。零破坏性。
5. **保留 mDNS 为首选**：同频段/正常多播环境下仍走 mDNS，扫描为补充而非替代，避免对已稳定环境产生任何回归风险。
6. **安全权衡**：子网扫描本质是主动 TCP 连接探测，在企业受管网络可能触发 IDS 告警。通过限制为 /24、并发 16、超时 300ms 将扫描强度降到常规局域网发现量级，可接受。

---

## 实施顺序建议

1. macOS 端 `PreferencesManager.manualSyncPeers` + `SettingsView` 手动添加 UI（先打通最小可用链路）
2. macOS 端 `SyncManager` 握手协议 + 手动 peer 连接 + 子网扫描
3. Flutter 端 `DiscoveredPeer` 重构 + `_connectToPeer` 泛化 + 握手协议
4. Flutter 端子网扫描 + 手动 peer 连接
5. Flutter 端 `main.dart` 手动添加 UI
6. 按「兼容性测试计划」逐项验证
