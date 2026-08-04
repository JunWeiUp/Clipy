## 目标
Mac 端通知：当通知内容为空（**标题 `entry.title` 与正文 `entry.body` 都为空**）时，既不弹出系统横幅，也不播放通知声音。

## 根因分析
- 接收链路：`SyncManager.handleFrame`（`notifPost`，`SyncManager.swift:855-859`）→ 解密 → `NotificationManager.handleRemoteNotification(_:from:)`（`NotificationManager.swift:169`）→ `upsertNotification` → `shouldShowBanner` 通过则 `showSystemNotification`。
- 现有 `isEmptyNotification`（`NotificationManager.swift:235`）只在 **title + subtitle + body + extras 全空** 时才短路，门槛过高：一条只有 appName、标题/正文都空的通知仍会走到 `showSystemNotification`。
- 弹窗与声音都由 `showSystemNotification(_:)`（`NotificationManager.swift:269`）唯一产生：弹窗来自第 288 行 `UNUserNotificationCenter.add(request)`，声音来自第 277 行 `content.sound = notificationSound ? .default : nil`，前台时再由 `willPresent` 委托强制 `[.banner, .sound]`（第 386 行）。
- 只要 `showSystemNotification` 不投递该 request，弹窗和声音就都不会出现（`willPresent` 也不会被回调）。已用 grep 确认这两个函数无外部调用方。

## 改动方案（单文件、单处）

文件：`clipy_macos/Sources/Notifications/NotificationManager.swift`

在 `showSystemNotification(_:)`（第 269 行函数体开头）加一个早返回守卫：若 `entry.title` 与 `entry.body` 去空白后都为空，直接 `return`，不构建/投递 `UNNotificationRequest`，也就不设置 `.sound`、不触发 `willPresent`。

```swift
func showSystemNotification(_ entry: NotificationEntry) {
    // 内容为空（标题与正文都为空）时不弹横幅、不发声
    let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty && body.isEmpty { return }

    let content = UNMutableNotificationContent()
    // …其余保持不变
}
```

要点：
- 选 `showSystemNotification` 而不是 `shouldShowBanner`，因为它是「弹窗 + 声音」共同的唯一发射点，在此守卫能硬性保证「没弹窗就一定没声音」，且对任何未来新增调用方都生效。
- 判空规则按用户确认：**`entry.title` 和 `entry.body` 同时为空才跳过**；`subtitle` 不计入（它本身未映射到原生横幅），`appName` 是始终展示的应用元数据也不计入。
- 存储路径不变：`upsertNotification` 仍按原逻辑执行，历史里依然会记录该条通知；只是不弹不响，符合用户「无法弹窗时也不要声音」的诉求。
- 不复用 `isEmptyNotification`：它的语义是「全字段空→存储级去重」，与此处「内容空→抑制展示/声音」不同，避免混用语义。

## 影响范围
- 仅 `NotificationManager.swift` 一处修改，约 4 行新增。
- 不影响 ACK（`handleRemoteNotification` 的 `defer` 仍正常回执，发送方照常清队列）。
- 不影响通知历史存储、搜索、菜单计数。
- 其余通知路径（dismiss / clearAll）不受影响。

## 验证
- 编译：按 AGENTS.md 规则，先 `proxy` 设置代理，再用 `build_macos_app.sh` 构建确认 EXIT 0。
- 手动验证（可选）：从 Android 端发一条标题/正文均为空的通知，确认 Mac 端不弹横幅、无声；发正常通知确认弹窗+声音照常。