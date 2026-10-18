# Common Relay SDK 快照升级

当前依赖以 `JunWeiUp/common-relay` 提交 `ff5ed1f29c7af1734016ab77c5a85c61acdbecd0` 为基线，包含本地自动入组与加密邀请短链接扩展。各语言 `vendor/common-relay/<language>/SOURCE.json` 保存源提交及逐文件 SHA-256；构建不依赖相邻仓库。

所有接入端配置应用私有的持久化日志，重连复用日志；SDK 在启动和连接存续期间每小时分批清理，去重/终态保留7天。日志不含令牌、私钥或消息明文。Python原有状态数据库自动迁移，历史无有效期消息保留7天但不自动重发。

本次只升级传输实现，不启用离线控制或离线presence。ADB、远控及实时会话断开后仍需新建连接，不自动重放操作。离线文件接口与业务确认保持现有行为，不能把SDK升级理解为新增全部离线业务能力。

源码升级、构建验证和安装验收分开记录；具体结果由本次交付说明提供。

## LAN 与中继身份边界

局域网协议 v3 恢复内置默认 AES-GCM 密钥，无需登记公钥或配置中继即可主动发送文本/文件。中继身份、公钥信任列表和 SDK 的端到端流加密保持独立；导入中继配置不能改变 LAN 密钥或清空待发送队列。旧配置的 sync_key 字段仅为兼容已有配置保留。

从实验性私有 LAN 密钥构建升级时，仅首次清除旧密钥编码的 pending_sync 帧；用户历史、文件、自动共享开关和中继身份保留。未确认送达的旧文本需重新发送。默认 LAN 密钥公开，不提供设备身份认证或针对已知密钥 LAN 参与者的保密性。

设备页加载/重新挂载中继表单只读取设置，不触发保存；用户编辑后显式保存整组字段。重复保存相同配置无副作用；实际变更仅重建中继连接，保留LAN监听、已发现设备和LAN传输。`relay_settings_lifecycle_test.dart` 覆盖重新挂载造成假保存的回归。

## 独立设备 ID 与公网 Key

Mac/Flutter中继表单分别编辑服务端登记的设备ID、WSS地址和公网Key；Key留空保留已保存值。已有接入配置中的私钥、公钥、组和信任列表在只换Key时保持不变；首次登记仍通过高级接入JSON导入公钥信任配置。显式保存一次应用整组编辑，初始化/重新挂载不保存。自定义ID需与服务端登记及对端信任表一致；界面编辑不会代替服务端登记。

中继设备ID与稳定的LAN peerId分离。加密presence增加peerId字段用于映射到LAN会话；旧端缺字段时仅以UUID格式的中继ID兼容。中继注册和流寻址使用自定义ID，LAN连接、去重、ACK与设备共享授权继续使用原peerId。修改中继配置仅重建中继连接。

手动刷新同时触发LAN扫描和中继presence刷新；缺少会话的发送也会立即请求中继刷新。presence使用SDK在线单向接口，不等待业务回执；文本发送仍等待v3接收ACK。两种环境的不同设备同时保留在列表，同一peer优先LAN，LAN不可达时中继接管；不创建两条竞争的业务会话。

## 设备组管理

Mac 与 Flutter 的公网中继设置新增“管理公网设备组”：完整成员列表（含离线设备）、管理员邀请二维码/链接、加入申请和配对码核对、显式授予管理权限、带确认的设备移除。手机与 Mac 使用同一权限模型，可相互邀请，手机也可邀请手机。Android/iOS 使用相机扫描；Mac 支持二维码图片识别和粘贴链接。

新成员默认普通权限。删除自己被禁止；普通成员不显示管理操作，服务端仍独立验证权限与签名。移除只撤销公网中继，LAN 与已收到数据不受影响。所有现有剪贴板共享开关保持原意，不因入组自动打开。

首次初始化需要新版 common-relay 的 `group-bootstrap` 短时邀请；旧组通过可信邀请升级成员签名身份，保留已有传输密钥和令牌。旧服务器会拒绝新管理接口，不应把接口不存在解释为空设备组。完整协议与运维说明位于 common-relay 的 `docs/DEVICE-GROUPS.md`。

本轮 SDK 快照保留原提交来源，并以 SOURCE.json 的 `working_tree_patch` 和逐文件 SHA-256 标注未提交扩展。组管理私有草稿/邀请在 Keychain 或 FlutterSecureStorage 中；页面关闭后可恢复，设备列表显式刷新，不新增后台轮询。连接前及带版本的 `group.changed` 通知后验证连续签名成员记录，更新可信公钥表并只重建中继连接。


## Relay invitation modes and short links

公网中继邀请默认“扫码后自动加入”，可关闭并使用配对码手动确认。自动加入通过管理员签署的限时委托验证，仅授予普通成员权限，不要求邀请设备持续在线。二维码和复制链接使用加密邀请短链接，兼容旧邀请；既有成员须升级支持委托签名链的 SDK。服务端需支持自动入组及短链接接口。

## Fast LAN / relay handoff

Network-interface changes, peer reconnection and explicit device refresh trigger a bounded 3-second ping check. A fresh pong preserves a healthy session; only the captured session without a newer pong is retired, then relay discovery runs immediately. Repeated refreshes share the deadline; stop cancels the probe and lifecycle checks reject stale callbacks. Relay refresh wakes a pending retry, uses known presence immediately, coalesces roster requests and reconnects after a 3-second roster timeout. Wi-Fi/cellular changes are handled without requiring an offline interval. No new permanent poller is added; LAN preference and trust checks remain.
