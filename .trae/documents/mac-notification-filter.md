# Mac 端通知弹横幅过滤规则

## 目标

在 Mac 端为通知同步增加「按应用 / 按关键字」过滤弹横幅的能力。通知无论是否命中规则都正常入库（通知列表窗口仍可见），**只有命中规则的通知才弹出系统横幅**。

## 行为规则（已与用户确认）

- **空规则（未勾选任何应用、未配置关键字）= 全部不弹横幅**。默认行为从「全部弹」变为「全部静默」，用户必须主动配置规则。
- **未命中规则的通知**：仍入库保存、仍发 ACK、仍可在通知列表窗口查看，**但不弹横幅**。
- **命中判定**：`应用白名单命中 OR 关键字命中`（任一即弹）。
  - 应用白名单命中：`entry.packageName ∈ bannerApps`
  - 关键字命中：关键字（大小写不敏感、trim 后非空）以 `contains` 方式匹配 `title` / `subtitle` / `body` 任一字段。
- ACK 与入库逻辑保持不变：只要 `upsertNotification` 返回 `inserted`/`replacedDuplicate` 就发 ACK（让 Android 清除离线队列）；`updated`（backfill）不发 ACK。是否弹横幅不影响 ACK。

## 现状分析

- [NotificationManager.swift:150-173](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/NotificationManager.swift#L150-L173) `handleRemoteNotification` 仅做全局开关 + 空内容过滤，无入站规则过滤。
- [NotificationManager.swift:16](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/NotificationManager.swift#L16) `allowedPackages` 字段存在，但原用于「下发到 Android」（现 `notification/config` 被安全策略禁用），**未用于入站过滤**。为避免语义混淆，本次不复用它，新增独立字段。
- [UI/SettingsView.swift:235-247](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/UI/SettingsView.swift#L235-L247) 通知 Section 仅两个 Toggle。
- 偏好项（`notificationSyncEnabled` / `notificationSound` / `allowedPackages`）直接存在 NotificationManager 内的 UserDefaults，本次新增字段沿用同一存储模式。
- [Localization.swift:139](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/Localization.swift#L139) 已有未使用的 `.notificationFilter` key（"通知过滤"/"Notification Filter"），可复用为 Section 标题。
- [NotificationRepository.swift](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/NotificationRepository.swift) 查询均为 `queue.sync { ...Locked }` 模式，新增查询方法沿用即可。

## 改动清单

### 1. `clipy_macos/Sources/NotificationRepository.swift`

新增「已见应用列表」查询，供设置页勾选用：

```swift
struct AppIdentity: Equatable {
    let packageName: String
    let appName: String
}

func fetchUniqueApps() -> [AppIdentity] {
    queue.sync {
        guard let db else { return [] }
        let sql = """
        SELECT package_name, app_name FROM phone_notifications
        GROUP BY package_name
        ORDER BY MAX(post_time) DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var apps: [AppIdentity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let pkg = optionalString(stmt, 0), let name = optionalString(stmt, 1) {
                apps.append(AppIdentity(packageName: pkg, appName: name))
            }
        }
        return apps
    }
}
```

（`AppIdentity` 也可定义为嵌套类型，保持文件内聚。）

### 2. `clipy_macos/Sources/NotificationManager.swift`

**(a) 新增偏好字段**（第 16-18 行附近）：

```swift
var bannerApps: Set<String> = []        // packageName 白名单
var bannerKeywords: [String] = []       // 关键字列表
```

**(b) 新增过滤判定方法**（放在 `handleRemoteNotification` 附近）：

```swift
func shouldShowBanner(_ entry: NotificationEntry) -> Bool {
    if bannerApps.isEmpty && bannerKeywords.isEmpty { return false }
    if bannerApps.contains(entry.packageName) { return true }
    let loweredKeywords = bannerKeywords
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    let title = entry.title.lowercased()
    let subtitle = (entry.subtitle ?? "").lowercased()
    let body = entry.body.lowercased()
    for keyword in loweredKeywords {
        if title.contains(keyword) || subtitle.contains(keyword) || body.contains(keyword) {
            return true
        }
    }
    return false
}
```

**(c) 修改 `handleRemoteNotification`**（第 166-171 行）：入库不变，弹横幅前加判断：

```swift
let accepted = upsertNotification(entry)
if accepted {
    if shouldShowBanner(entry) {
        showSystemNotification(entry)
    }
    SyncManager.shared.sendNotificationAck(hash: entry.id)
}
```

**(d) 扩展 `loadPreferences` / `savePreferences`**（第 284-305 行）读写新字段：

```swift
// loadPreferences
if let packages = defaults.stringArray(forKey: "notificationBannerApps") {
    bannerApps = Set(packages)
}
if let keywords = defaults.stringArray(forKey: "notificationBannerKeywords") {
    bannerKeywords = keywords
}

// savePreferences
defaults.set(Array(bannerApps), forKey: "notificationBannerApps")
defaults.set(bannerKeywords, forKey: "notificationBannerKeywords")
```

**(e) 新增便捷访问**（供 SettingsView 拉取已见应用）：

```swift
var knownApps: [NotificationRepository.AppIdentity] {
    repository.fetchUniqueApps()
}
```

### 3. `clipy_macos/Sources/UI/SettingsView.swift`

**(a) 新增 `@State`**（第 21-22 行附近，与现有 `notificationSyncEnabled` 同区）：

```swift
@State private var bannerApps: Set<String>
@State private var bannerKeywordsText: String
@State private var knownApps: [NotificationRepository.AppIdentity]
```

`init()` 中初始化：
```swift
_bannerApps = State(initialValue: NotificationManager.shared.bannerApps)
_bannerKeywordsText = State(initialValue: NotificationManager.shared.bannerKeywords.joined(separator: ", "))
_knownApps = State(initialValue: NotificationManager.shared.knownApps)
```

**(b) 扩展通知 Section**（第 235-247 行），在两个现有 Toggle 之后追加：

- **关键字输入行**：`TextField` 绑定 `bannerKeywordsText`，`onSubmit` 时 split 逗号、trim、去空，写回 `NotificationManager.shared.bannerKeywords` 并 `savePreferences()`。参考现有 `excludedApps`（第 120 行附近）的处理范式。
- **应用勾选列表**：`ForEach(knownApps)` 每项一个 `Toggle`，label 显示 `appName`，绑定值以 `packageName` 为 key 存取 `bannerApps`；`onChange` 时写回 manager + `savePreferences()`。
- **空列表提示**：当 `knownApps.isEmpty` 时显示 `Text(L10n.t(.noReceivedApps))`，提示收到手机通知后这里会出现可勾选的应用。
- **Section header / 说明文字**：复用 `.notificationFilter` 作为标题，加一行说明（「未配置时默认不弹横幅；勾选应用或关键字后命中才弹」）。

**(c) 刷新已知应用列表**：在现有 `.onReceive(...didBecomeActiveNotification)`（第 279 行）和 `.onReceive(...phoneNotificationsDidChange)`（如未监听则新增）里追加 `knownApps = NotificationManager.shared.knownApps`，保证收到新通知带来新应用时列表更新。SettingsView 需新增对 `.phoneNotificationsDidChange` 的监听。

### 4. `clipy_macos/Sources/Localization.swift`

新增 key（中/英对照，插入到第 133-141 行的 enum 与第 390-398、636-644 行两份字典）：

| case | 中文 | English |
|------|------|---------|
| `bannerRules` | 弹横幅规则 | Banner Rules |
| `bannerRulesHint` | 未配置时不弹横幅；勾选应用或填写关键字后，命中才弹 | No banner without rules; tick apps or add keywords to show banners on match |
| `bannerKeywords` | 关键字 | Keywords |
| `bannerKeywordsHint` | 逗号分隔，匹配通知标题/副标题/正文 | Comma-separated; matches title/subtitle/body |
| `noReceivedApps` | 暂无已接收应用，收到手机通知后会在此显示 | No received apps yet; they appear after phone notifications arrive |

（`.notificationFilter` 已存在，用作 Section header。）

## 假设与决策

1. **不复用遗留 `allowedPackages`**：它语义为「下发白名单」（已废弃），改为入站过滤会造成歧义。新增独立 `bannerApps` / `bannerKeywords`，旧字段保留不动。
2. **关键字大小写不敏感、包含匹配**，匹配范围 `title` + `subtitle` + `body`；`extras` 不参与匹配（结构不稳定）。
3. **应用勾选列表来源 = 本地已入库通知的 distinct packageName**，首次使用（无历史）时列表为空并给出提示；不提供手动输入包名（YAGNI，收到通知后自动出现）。
4. **空规则默认不弹**会改变现有用户体验——这是用户明确要求，无需额外兼容开关。
5. 关键字输入采用与 `excludedApps` 一致的「逗号分隔 TextField + onSubmit 落盘」模式，保持设置页交互一致。

## 验证

1. `proxy && cd clipy_macos && swift build`（或 Xcode 构建脚本）编译通过。
2. 清空规则：从 Android 发一条通知 → Mac 入库、通知列表可见、**不弹横幅**、Android 端离线队列被 ACK 清除。
3. 勾选该应用：再发一条 → 入库 + **弹横幅**。
4. 取消勾选应用、改用关键字命中（如正文包含某词）→ 入库 + 弹横幅。
5. 未命中关键字且未勾选应用 → 入库 + 不弹横幅。
6. 通知列表窗口（NotificationView）所有场景下都能看到该通知。
7. 重启 app，`bannerApps` / `bannerKeywords` 持久化生效。
