# 通知偏好整合到通知窗口

## 目标

将所有通知相关偏好（启用同步、声音、弹横幅规则）从设置页迁移到通知查看窗口；每个应用的"是否弹横幅"开关直接嵌入应用分组行；支持搜索应用过滤；数据加载改为全量（不再分页）；关键字配置通过工具栏按钮 + popover 呈现；新增 Mac 系统通知权限状态/跳转按钮。

## 行为规则（已确认）

- **迁移范围**：设置页的通知 Section 全部移除（含启用同步、声音、弹横幅规则），迁移到通知窗口。
- **应用弹横幅开关**：每个应用分组的 label 行右侧加一个铃铛图标按钮，点击切换该应用是否弹横幅（绑定 `bannerApps`）。
- **搜索应用**：列表上方加搜索框，按 `appName` / `packageName` 过滤分组（非通知内容搜索）。
- **全量加载**：移除分页（pageSize/offset/loadMore），一次性 fetchAll。
- **内存优先（关键）**：全量数据只保留一份副本（`groups`），删除中间 `loadedEntries`；窗口关闭时 `prepareForClose` 彻底清空所有 `@Published` 数组/集合与缓存，`onTeardown` 释放 viewModel（`= nil`），让全部通知数据随窗口关闭立即回收，降低 app 常驻内存。
- **关键字 + 全局开关**：工具栏齿轮按钮 → popover 内含「启用通知同步 Toggle」「通知声音 Toggle」「关键字 TextField」。
- **Mac 通知权限**：工具栏铃铛按钮，显示系统通知授权状态，点击跳转系统设置通知页。

## 现状分析

- [NotificationView.swift](file:///Users/mac/Documents/code1/clipy_macos/Sources/UI/NotificationView.swift)：`NotificationViewModel` 分页加载（pageSize=100、loadedOffset、loadNextPage、canLoadMore），底部 ProgressView 触发 loadMore。`NotificationView` 用 `AppListWindowLayout` + `AppToolbar` + `List` + `DisclosureGroup`（按 packageName 分组）。
- [SettingsView.swift:241-294](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/UI/SettingsView.swift#L241-L294)：上一轮加的通知 Section（启用同步 Toggle、声音 Toggle、弹横幅规则 Section 含关键字 + 应用勾选列表），需整体移除。
- [NotificationManager.swift:16-25](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/NotificationManager.swift#L16-L25)：`bannerApps`、`bannerKeywords`、`shouldShowBanner`、`knownApps`、偏好持久化已就绪，保留。
- [NotificationRepository.swift](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/NotificationRepository.swift)：有 `fetch(offset:limit:)` 和 `fetchUniqueApps()`，无 `fetchAll`。
- [AppToolbar.swift](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/UI/AppToolbar.swift)：`AppToolbarButton` 是纯数据结构（title/systemImage/action），不支持 popover；popover 需在 NotificationView 用自定义 Button + `.popover` 实现。
- [AppWindowLayout.swift](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/UI/AppWindowLayout.swift)：`AppListWindowLayout` = `VStack { toolbar / Divider / content / statusbar }`，搜索框加在 content 顶部。
- SettingsView 相关 @State（第 21-22 行 bannerApps/bannerKeywordsText/knownApps）、init（第 43-45 行）、commitBannerKeywords、phoneNotificationsDidChange 监听均需移除。

## 改动清单

### 1. `NotificationRepository.swift` — 新增全量查询

```swift
func fetchAll() -> [NotificationManager.NotificationEntry] {
    queue.sync { fetchLocked(offset: 0, limit: -1) }
}
```
（现有 `fetchLocked` 已支持 `limit > 0` 校验，需调整为 `limit <= 0` 时返回全部，或新增独立 `fetchAllLocked`。推荐新增独立方法避免改动现有分页逻辑：

```swift
private func fetchAllLocked() -> [NotificationManager.NotificationEntry] {
    guard let db else { return [] }
    let sql = """
    SELECT id, notification_key, package_name, app_name, title, subtitle, body,
           post_time, group_key, is_clearable, extras_json
    FROM phone_notifications ORDER BY post_time DESC
    """
    // ... 同 fetchLocked 但无 LIMIT/OFFSET
}
```
）

### 2. `NotificationManager.swift` — 新增便捷方法

```swift
func fetchAllNotifications() -> [NotificationEntry] {
    repository.fetchAll()
}
```

Mac 通知权限检查与跳转：

```swift
/// 检查系统通知授权状态（.authorized / .denied / .notDetermined / .provisional）
func checkNotificationAuthorization(completion: @escaping (UNAuthorizationStatus) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async { completion(settings.authorizationStatus) }
    }
}

/// 跳转到系统设置 > 通知（本 app）
func openSystemNotificationSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
        NSWorkspace.shared.open(url)
    }
}
```

### 3. `NotificationView.swift` — 核心重构

#### 3a. NotificationViewModel 改造

**移除分页 + 移除双份数据副本**：删除 `pageSize`、`loadedOffset`、`isLoadingMore`、`canLoadMore`、`loadMoreIfNeeded`、`loadNextPage`，**同时删除 `loadedEntries`**。数据只保存在 `groups`（@Published）一份。

**全量加载（直接构建 groups，无中间数组）**：
```swift
func reload() {
    lastReloadAt = Date()
    let entries = manager.fetchAllNotifications()
    groups = buildGroups(from: entries)
}

private func buildGroups(from entries: [NotificationManager.NotificationEntry]) -> [NotificationGroup] {
    var grouped: [String: NotificationGroup] = [:]
    var order: [String] = []
    for entry in entries {
        if grouped[entry.packageName] == nil {
            order.append(entry.packageName)
            grouped[entry.packageName] = NotificationGroup(id: entry.packageName, packageName: entry.packageName, appName: entry.appName, items: [])
        }
        grouped[entry.packageName]!.items.append(entry)
    }
    return order.compactMap { grouped[$0] }
}
```
`entries` 是局部变量，函数返回后即释放；只有 `groups` 持有数据。

**窗口关闭彻底释放**（强化 `prepareForClose`）：
```swift
func prepareForClose() {
    isActive = false
    groups = []                  // 释放全量通知数据（唯一副本）
    expandedPackages.removeAll()
    selectedIDs.removeAll()
    searchText = ""
    bannerKeywordsText = ""
}
```
配合 `NotificationWindow.onTeardown { self?.viewModel = nil }`（已存在），viewModel 及其全部 @Published 随窗口销毁被 ARC 回收。

**exportJSON 改为从 groups 提取**（不再依赖 loadedEntries）：
```swift
func exportJSON() {
    let allEntries = groups.flatMap { $0.items }  // 替代原 loadedEntries
    // ... 其余不变
}
```

**新增搜索**：
```swift
@Published var searchText = ""

var filteredGroups: [NotificationGroup] {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return groups }
    return groups.filter {
        $0.appName.localizedCaseInsensitiveContains(trimmed) ||
        $0.packageName.localizedCaseInsensitiveContains(trimmed)
    }
}
```

**新增弹横幅开关**：
```swift
func toggleBanner(for packageName: String) {
    if manager.bannerApps.contains(packageName) {
        manager.bannerApps.remove(packageName)
    } else {
        manager.bannerApps.insert(packageName)
    }
    manager.savePreferences()
}

func isBannerEnabled(for packageName: String) -> Bool {
    manager.bannerApps.contains(packageName)
}
```

**新增偏好镜像**（供 popover 绑定）：
```swift
var notificationSyncEnabled: Bool {
    get { manager.notificationSyncEnabled }
    set { manager.notificationSyncEnabled = newValue; manager.savePreferences() }
}
var notificationSound: Bool {
    get { manager.notificationSound }
    set { manager.notificationSound = newValue; manager.savePreferences() }
}

@Published var bannerKeywordsText: String
// init 中初始化 = manager.bannerKeywords.joined(separator: ", ")

func commitBannerKeywords() {
    let keywords = bannerKeywordsText
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    manager.bannerKeywords = keywords
    manager.savePreferences()
    bannerKeywordsText = keywords.joined(separator: ", ")
}
```

**新增权限状态**：
```swift
@Published var notificationAuthorized: UNAuthorizationStatus = .notDetermined
func refreshAuthorization() {
    manager.checkNotificationAuthorization { [weak self] status in
        self?.notificationAuthorized = status
    }
}
```
在 `onAppear` / `reload` 中调用 `refreshAuthorization()`。

#### 3b. NotificationView UI 改造

**工具栏**新增两个按钮（trailing）：
- 齿轮按钮 → `.popover` 弹出设置面板（Form：启用同步 Toggle、声音 Toggle、关键字 TextField + 提示 + onSubmit commit）
- 铃铛按钮 → 显示权限状态（authorized=绿色 bell.fill / 其他=橙色 bell.slash），点击调用 `manager.openSystemNotificationSettings()`

由于 `AppToolbar` 只接受 `AppToolbarButton`（不支持 popover），这两个按钮在 `AppListWindowLayout` 的 toolbar 闭包内**与 AppToolbar 组合**：用 `HStack` 把 AppToolbar 和自定义按钮放在一起，或直接在 toolbar 闭包内用自定义 HStack 替代 AppToolbar（保持相同样式 `.background(.thinMaterial)` + padding）。

推荐方案：保持 AppToolbar 不变，在 `content` 区域**顶部**加搜索栏（`AppWindowHeader` 包裹 TextField），工具栏保持原样，齿轮/铃铛按钮加到 AppToolbar 的 trailing 数组中，用状态控制 popover。具体实现：

```swift
AppToolbar(
    leading: [...],
    trailing: [
        AppToolbarButton(title: ..., systemImage: "gearshape", action: { showSettingsPopover = true }),
        AppToolbarButton(title: ..., systemImage: bellIcon, action: { manager.openSystemNotificationSettings() }),
        AppToolbarButton(title: ..., systemImage: "doc.on.doc", action: viewModel.copySelected),
        AppToolbarButton(title: ..., systemImage: "square.and.arrow.up", action: viewModel.exportJSON),
    ]
)
```

但 AppToolbarButton 只有 action，无法承载 popover。**解决**：在 toolbar 闭包内不用 AppToolbarButton 传齿轮/铃铛，而是自定义一个按钮视图附加 `.popover`。做法：把 toolbar 闭包改为自定义 `NotificationToolbar` 视图，内部用 HStack 排列标准按钮（清空/清除手机）+ Spacer + 齿轮(带popover) + 铃铛(跳转) + 复制 + 导出，保持与 AppToolbar 相同的视觉样式（`.bordered` 按钮 + `.thinMaterial` 背景 + `AppTitleBar.height` 顶部 padding）。

**搜索栏**：content 区域顶部加：
```swift
VStack(spacing: 0) {
    // 搜索栏
    HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(L10n.t(.searchApps), text: $viewModel.searchText)
            .textFieldStyle(.plain)
    }
    .padding(.horizontal, AppSpacing.sm)
    .padding(.vertical, AppSpacing.xs)
    Divider()
    // 列表
    ...
}
```

**分组 label 加弹横幅按钮**：
```swift
} label: {
    HStack {
        Text(group.appName).font(AppFont.body.weight(.semibold))
        Spacer()
        // 弹横幅开关（铃铛图标按钮，点击不触发展开）
        Button(action: { viewModel.toggleBanner(for: group.packageName) }) {
            Image(systemName: viewModel.isBannerEnabled(for: group.packageName) ? "bell.badge.fill" : "bell.slash")
                .foregroundStyle(viewModel.isBannerEnabled(for: group.packageName) ? AppColor.accent : .secondary)
        }
        .buttonStyle(.borderless)
        CountBadge(count: group.items.count)
        Text(viewModel.latestTime(for: group)).font(AppFont.caption).foregroundStyle(.secondary)
    }
    .frame(height: AppRowHeight.group)
}
```
用 `Button(.borderless)` 而非 `Toggle`，避免点击与 DisclosureGroup 展开冲突。

**列表数据源**：`ForEach(viewModel.groups)` 改为 `ForEach(viewModel.filteredGroups)`。移除底部 loadMore ProgressView。

### 4. `SettingsView.swift` — 移除通知 Section

- 删除第 241-294 行的两个通知 Section（启用同步/声音 Toggle + 弹横幅规则 Section）。
- 删除 @State：`notificationSyncEnabled`、`notificationSound`、`bannerApps`、`bannerKeywordsText`、`knownApps`（第 21-25 行）。
- 删除 init 中对应初始化（第 43-47 行）。
- 删除 `commitBannerKeywords()` 方法。
- 删除 `.onReceive(...phoneNotificationsDidChange)` 监听。
- `didBecomeActive` 监听中移除 `knownApps = ...` 行。

### 5. `Localization.swift` — 新增/调整文案

新增 case：
| case | 中文 | English |
|------|------|---------|
| `searchApps` | 搜索应用 | Search Apps |
| `notificationSettings` | 通知设置 | Notification Settings |
| `macNotificationPermission` | Mac 通知权限 | Mac Notification Permission |
| `macNotificationGranted` | 已授权 | Granted |
| `macNotificationDenied` | 已拒绝，请在系统设置中允许 | Denied; please allow in System Settings |
| `openNotificationSettings` | 前往系统设置 | Open System Settings |

已有可复用：`.notificationFilter`、`.bannerRules`、`.bannerRulesHint`、`.bannerKeywords`、`.bannerKeywordsHint`、`.enableNotificationSync`、`.notificationSound`。

## 假设与决策

1. **弹横幅开关用 Button(borderless)+图标**而非 Toggle：避免 DisclosureGroup label 内 Toggle 点击事件与展开/折叠冲突。`bell.badge.fill`（已启用）= accent 色，`bell.slash`（未启用）= secondary 色。
2. **全局开关 + 关键字放 popover**：通知窗口主体是查看通知，设置项用齿轮按钮 popover 呈现，不占用列表空间；符合 macOS 原生交互。
3. **搜索只过滤应用名**（appName/packageName），不搜索通知内容；符合"支持搜索应用"需求。
4. **全量加载 + 内存优先**：SQLite 有 post_time DESC 索引，全量读取性能可接受。为降低常驻内存，数据只保留 `groups` 一份（删除 `loadedEntries` 中间副本）；窗口关闭时 `prepareForClose` 清空所有 @Published，`onTeardown` 置 viewModel = nil，确保通知数据不随窗口隐藏而驻留。exportJSON 从 `groups.flatMap { $0.items }` 提取，无需额外缓存。
5. **Mac 通知权限按钮**：用 `UNUserNotificationCenter.getNotificationSettings` 检查状态，`x-apple.systempreferences:` URL scheme 跳转系统设置。异步检查，存入 @Published 驱动图标颜色。
6. **工具栏自定义**：因 AppToolbarButton 不支持 popover，新建内部 `NotificationToolbar` 视图复用 AppToolbar 视觉样式；不改动通用 AppToolbar 组件。

## 验证

1. `swiftc -typecheck` 编译通过。
2. 设置页打开：通知 Section 已消失。
3. 通知窗口打开：
   - 工具栏有齿轮、铃铛、复制、导出按钮 + 左侧清空/清除手机。
   - 搜索框输入应用名 → 分组实时过滤。
   - 每个分组行右侧铃铛按钮 → 点击切换图标/颜色，持久化（重开窗口保持）。
   - 齿轮按钮 → popover 显示启用同步/声音 Toggle + 关键字输入，修改后持久化。
   - 铃铛按钮 → 显示当前 Mac 通知权限状态颜色，点击跳转系统设置。
4. 全量加载：所有通知一次性显示，无底部加载指示器。
5. **内存释放**：关闭通知窗口后，viewModel 的 `groups`/`expandedPackages`/`selectedIDs` 全部清空，viewModel 被释放（Instruments/Xcode Memory Graph 确认通知数据不再驻留）；重新打开窗口时重新 fetchAll。
6. 弹横幅行为：勾选应用或配关键字后收到通知弹横幅；未配置不弹（上轮已实现 shouldShowBanner 逻辑不变）。
7. 重启 app，所有偏好持久化生效。
