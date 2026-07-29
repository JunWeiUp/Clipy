# 安卓到 Mac 通知同步功能全面重构（实施计划）

## 当前进度追踪（会话恢复后验证）

> 以下进度基于 2026-07-28 代码重新读取验证，非假设。

### 全部 6 阶段已完成 ✅

| 阶段 | 模块 | 状态 | 验证 |
|---|---|---|---|
| 1 | 修复编译错误 + 两层筛选数据层 + dismiss | ✅ 已完成 | notification_manager.dart + repository |
| 2 | Mac 接收链路修复 | ✅ 已完成 | NotificationManager.swift + SyncManager.swift |
| 3 | notification_sync_page.dart UI 重构 | ✅ 已完成 | 双开关单列表 + loading + 权限刷新 |
| 4 | MainActivity.kt 性能 + 权限健壮性 | ✅ 已完成 | 后台线程 + try/catch + onDestroy |
| 5 | 稳定性修复 | ✅ 已完成 | stream cancel + onUpgrade + _trimToLimit |
| 6 | 本地化文案 | ✅ 已完成 | collect/sync/collectAll/syncAll/syncing/paused |

### 编译验证

- `flutter analyze` — **0 errors, 0 warnings**（仅 5 个 info 级 lint 建议）

---

## 概要

当前安卓到 Mac 通知同步功能"整体不可用"。经全链路代码审计，**头号根因是 Mac 端 `NotificationManager.notificationSyncEnabled` 默认 `false`，且 `loadPreferences()` 用 `bool(forKey:)` 在首次安装时覆盖为 `false`，接收入口 `handleRemoteNotification` 静默丢弃所有通知**；叠加接收链路硬依赖 `isSyncEnabled` 总开关、Android 端单层筛选语义混淆且当前处于**编译错误状态**、应用列表主线程阻塞加载、dismiss 事件丢弃等问题。

本计划覆盖用户全部 7 项需求，分阶段对 Android + macOS 双端全链路重构。

---

## 实际代码状态审计（基于代码读取，非假设）

| 模块 | 状态 | 说明 |
|---|---|---|
| **G** 安全加固 | ✅ 完成 | 两端 `handleNotificationConfig` 都已改为仅记日志 |
| **A** Mac 接收链路 | ⚠️ 仅 5% | 仅 `notificationSyncEnabled` 属性默认值改为 `true`（L17）。**但 `loadPreferences()` 仍用 `bool(forKey:)`，首次安装会覆盖回 `false`**；入站 `allowedPackages` 筛选未移除（L163）；`start()` 未解耦（L463）；`willPresent` 未判断 `notificationSound`（L296）；guard 无日志（L151） |
| **C** 两层筛选 | 🔴 编译错误 | `notification_manager.dart` 添加了两个新 StreamController（L29-36），但 `allowedPackages` 字段未替换（L18），L292 引用**未定义**的 `_allowedPackagesChangedController`；`notification_sync_page.dart` 引用**不存在**的 `onAllowedPackagesChanged`（L55）→ 双端均无法编译 |
| **B** 列表性能 | ❌ 未开始 | `getInstalledApps` channel 在主线程同步执行（L141） |
| **D** 权限流程 | ❌ 未开始 | MethodChannel 无 try/catch；权限卡片无分步引导 |
| **E** 开关控制 | ❌ 未开始 | 总开关无醒目状态指示 |
| **F** dismiss 同步 | ❌ 未开始 | `onNotificationRemoved` 空分支（L81-82），Kotlin 端 emit 已存在 |
| **H** 稳定性 | ❌ 未开始 | stream listener 未 cancel；无 `onUpgrade`；`_trimToLimit` 用 NOT IN 子查询 |

---

## 假设与决策

1. **两层筛选都在 Android 端配置**：Mac 端移除入站 `allowedPackages` 过滤，只负责显示。
2. **Mac 端默认开启接收**：`notificationSyncEnabled` 默认 `true`，`loadPreferences` 首次安装不覆盖。
3. **通知同步与剪贴板同步解耦**：`SyncManager.start()` 独立判断通知同步开关。
4. **筛选 UI 采用「双开关单列表」**（用户已确认）：每个应用 tile 只出现一次，同时显示「收集」「同步」两个 Switch；同步开关在收集关闭时禁用。
5. **硬编码 AES 密钥本次不动**：改动范围大，单独迭代。
6. **DB schema version 不变**：保持 v1，仅补 `onUpgrade` 框架。
7. **`allowedPackages` 字段保留但不用于入站过滤**：Mac 端避免破坏性删除，仅停止使用。

---

## 实施步骤

### 阶段 1：修复编译错误 + 完成模块 C 数据层 + 模块 F dismiss

> 优先级最高：当前代码无法编译。完成 `notification_manager.dart` 的两层筛选模型和 dismiss 处理。

**文件**：[notification_manager.dart](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/notification_manager.dart)

**1.1 字段替换（L18）**

当前：
```dart
List<String> allowedPackages = [];
```
改为：
```dart
List<String> collectedPackages = [];  // 收集白名单：空 = 收集全部
List<String> syncedPackages = [];     // 同步白名单：空 = 同步全部已收集
```

**1.2 init() 加载逻辑 + 一次性迁移（L62-72）**

当前 L65：`allowedPackages = prefs.getStringList('notificationAllowedPackages') ?? [];`

改为迁移 + 双键加载：
```dart
// 一次性迁移旧键
final legacy = prefs.getStringList('notificationAllowedPackages');
if (legacy != null) {
  collectedPackages = legacy;
  await prefs.remove('notificationAllowedPackages');
  await prefs.setStringList('notificationCollectedPackages', collectedPackages);
} else {
  collectedPackages =
      prefs.getStringList('notificationCollectedPackages') ?? [];
}
syncedPackages = prefs.getStringList('notificationSyncedPackages') ?? [];
```

**1.3 补全 onNotificationRemoved 分支（L81-82，模块 F）**

当前：空 `break;`

改为：
```dart
case 'onNotificationRemoved':
  final Map<dynamic, dynamic> args = call.arguments;
  await _handleNotificationRemoved(Map<String, dynamic>.from(args));
  break;
```

新增方法：
```dart
Future<void> _handleNotificationRemoved(Map<String, dynamic> data) async {
  final key = data['key'] as String?;
  final packageName = data['packageName'] as String? ?? '';
  if (key == null) return;
  // 本地按 key 删除（repository 需支持，见下）
  await NotificationRepository.instance.removeByNotificationKey(key);
  _notificationsChangedController.add(null);
  // 广播 dismiss 到 Mac
  SyncManager.instance.broadcastNotificationMessage(
    type: 'notification/dismiss',
    content: jsonEncode({
      'notificationKey': key,
      'packageName': packageName,
      'groupKey': null,
    }),
    hash: '',
  );
}
```

**1.4 _handleNotificationPosted 收集层过滤（L89-97）**

当前 L93-97 用 `allowedPackages` 过滤。改为用 `collectedPackages`：
```dart
if (packageName != _selfPackageName &&
    collectedPackages.isNotEmpty &&
    !collectedPackages.contains(packageName)) {
  return;  // 不收集，不入库
}
```

**1.5 入库后同步层过滤（L117-123）**

当前 L119：`if (!_suppressBroadcast) { _broadcastToSync(entry); }`

改为：
```dart
if (!_suppressBroadcast && _shouldSync(packageName)) {
  _broadcastToSync(entry);
}
```

新增：
```dart
bool _shouldSync(String packageName) {
  if (packageName == _selfPackageName) return false;
  if (syncedPackages.isEmpty) return true;  // 空 = 同步全部
  return syncedPackages.contains(packageName);
}
```

**1.6 替换 API 方法（L288-319）**

删除 `updateAllowedPackages` / `isPackageSyncEnabled` / `setPackageSyncEnabled`（引用了未定义的 `_allowedPackagesChangedController`）。

新增两组方法：
```dart
// —— 收集层 ——
bool isPackageCollected(String packageName) {
  if (packageName == _selfPackageName) return false;
  if (collectedPackages.isEmpty) return true;  // 空 = 收集全部
  return collectedPackages.contains(packageName);
}

Future<void> setPackageCollected(String packageName, bool collected) async {
  if (packageName == _selfPackageName) return;
  var packages = List<String>.from(collectedPackages);
  if (collectedPackages.isEmpty) {
    // 从"收集全部"切换到显式列表：需先排除目标
    if (!collected) {
      final known = await _knownPackageNames();
      packages = known.where((p) => p != packageName).toList();
    }
  } else {
    if (collected) {
      packages.add(packageName);
    } else {
      packages.remove(packageName);
      // 收集关闭时，同步也一并关闭
      if (syncedPackages.contains(packageName)) {
        syncedPackages.remove(packageName);
        await prefs.setStringList(
            'notificationSyncedPackages', syncedPackages);
        _syncedPackagesChangedController.add(syncedPackages);
      }
    }
    packages = packages.toSet().toList()..sort();
  }
  collectedPackages = packages;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('notificationCollectedPackages', collectedPackages);
  _collectedPackagesChangedController.add(collectedPackages);
}

// —— 同步层 ——
bool isPackageSynced(String packageName) {
  if (packageName == _selfPackageName) return false;
  if (syncedPackages.isEmpty) return true;  // 空 = 同步全部已收集
  return syncedPackages.contains(packageName);
}

Future<void> setPackageSynced(String packageName, bool synced) async {
  if (packageName == _selfPackageName) return;
  var packages = List<String>.from(syncedPackages);
  if (syncedPackages.isEmpty) {
    if (!synced) {
      final known = await _knownPackageNames();
      packages = known.where((p) => p != packageName).toList();
    }
  } else {
    if (synced) {
      packages.add(packageName);
    } else {
      packages.remove(packageName);
    }
    packages = packages.toSet().toList()..sort();
  }
  syncedPackages = packages;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('notificationSyncedPackages', syncedPackages);
  _syncedPackagesChangedController.add(syncedPackages);
}
```

注意：`_knownPackageNames()`（L321-333）保持不变。

**1.7 repository 补全 removeByNotificationKey**

**文件**：[notification_repository.dart](file:///Users/mac/Documents/code1/clipy_android/lib/database/notification_repository.dart)

确认是否有按 `notification_key` 删除的方法。若无，新增：
```dart
Future<void> removeByNotificationKey(String key) async {
  final db = await AppDatabase.instance.database;
  await db.delete('notifications', where: 'notification_key = ?', whereArgs: [key]);
}
```

---

### 阶段 2：完成模块 A（Mac 端接收链路修复）

> 解决"不可用"头号根因。

**文件 1**：[NotificationManager.swift](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/NotificationManager.swift)

**2.1 loadPreferences 首次安装不覆盖（L279-285）**

当前 L280：`notificationSyncEnabled = UserDefaults.standard.bool(forKey: "notificationSyncEnabled")`
（`bool(forKey:)` 键不存在时返回 `false`，会覆盖默认值 `true`）

改为：
```swift
private func loadPreferences() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "notificationSyncEnabled") == nil {
        notificationSyncEnabled = true  // 首次安装默认开
    } else {
        notificationSyncEnabled = defaults.bool(forKey: "notificationSyncEnabled")
    }
    if defaults.object(forKey: "notificationSound") == nil {
        notificationSound = true
    } else {
        notificationSound = defaults.bool(forKey: "notificationSound")
    }
    if let packages = defaults.stringArray(forKey: "notificationAllowedPackages") {
        allowedPackages = Set(packages)
    }
}
```

**2.2 guard 加 warning 日志（L151）**

当前：`guard notificationSyncEnabled else { return }`

改为：
```swift
guard notificationSyncEnabled else {
    appLog("NotificationManager: dropped incoming notification, sync disabled", level: .warning)
    return
}
```

**2.3 移除入站 allowedPackages 过滤（L163-165）**

删除：
```swift
if !allowedPackages.isEmpty && !allowedPackages.contains(entry.packageName) {
    return
}
```
（筛选由 Android 端两层模型控制，Mac 端不再做入站过滤。`allowedPackages` 字段保留但不再用于过滤。）

**2.4 willPresent 根据 notificationSound（L295-297）**

当前：`completionHandler([.banner, .sound])`

改为：
```swift
func userNotificationCenter(...willPresent...) {
    if notificationSound {
        completionHandler([.banner, .sound])
    } else {
        completionHandler([.banner])
    }
}
```

**文件 2**：[SyncManager.swift](file:///Users/mac/Documents/code1/clipy1/clipy_macos/Sources/SyncManager.swift)

**2.5 start() 解耦通知同步（L461-469）**

当前：
```swift
guard PreferencesManager.shared.isSyncEnabled else { return }
startListening()
startBrowsing()
startPeerLivenessProbing()
startPathMonitoring()
```

改为：
```swift
func start() {
    appLog("SyncManager starting...")
    let needListen = PreferencesManager.shared.isSyncEnabled ||
        NotificationManager.shared.notificationSyncEnabled
    guard needListen else { return }
    startListening()
    if PreferencesManager.shared.isSyncEnabled {
        startBrowsing()
        startPeerLivenessProbing()
    }
    startPathMonitoring()
}
```

（通知同步只需监听接收，不需要主动发现对端。）

---

### 阶段 3：notification_sync_page.dart UI 重构（模块 C UI + D + E）

> 依赖阶段 1 完成。采用「双开关单列表」方案。

**文件**：[notification_sync_page.dart](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/notification_sync_page.dart)

**3.1 订阅替换（L30, L54-57, L67）**

- L30 `_allowedPackagesSubscription` → 两个订阅：
  ```dart
  StreamSubscription? _collectedSub;
  StreamSubscription? _syncedSub;
  ```
- L54-57 改为监听两个新 stream：
  ```dart
  _collectedSub = NotificationManager.instance.onCollectedPackagesChanged.listen((_) {
    if (mounted) setState(() {});
  });
  _syncedSub = NotificationManager.instance.onSyncedPackagesChanged.listen((_) {
    if (mounted) setState(() {});
  });
  ```
- L67 dispose 中 cancel 两个订阅。

**3.2 _setPackageSyncEnabled 调用更新（L71-77）**

移除此辅助方法（UI 改为直接调用 `setPackageCollected` / `setPackageSynced`）。

**3.3 设置 Tab 总开关状态指示（L273-304，模块 E）**

当前 SwitchListTile 的 subtitle 文案不够醒目。改为：
- 开启时：`secondary` 图标绿色 `Icons.sync`，subtitle 显示"正在同步"。
- 关闭时：`secondary` 图标灰色 `Icons.sync_disabled`，subtitle 显示"已暂停"。

**3.4 筛选计数 header（L306-330）**

当前 L324 `${manager.allowedPackages.length} / ${_installedApps.length}` 改为显示两个维度：
```dart
'收集 ${manager.collectedPackages.isEmpty ? "全部" : manager.collectedPackages.length} · 同步 ${manager.syncedPackages.isEmpty ? "全部" : manager.syncedPackages.length}'
```

**3.5 全选/取消全选（L350-377）**

改为四按钮或两组：明确"全选收集""取消收集""全选同步""取消同步"。简化方案：保留两个按钮，一个作用于收集层（全选 = 清空 collectedPackages 即全部收集；取消 = 设为空列表排除所有），同步层同理。

更简方案：两个 TextButton 分别标注「收集全部 / 收集 none」「同步全部 / 同步 none」。实现时用 `setPackageCollected` 逐个调用或新增批量方法。

**3.6 应用 tile 改为双开关（L437-451，核心变更）**

当前 `CheckboxListTile` 单值。替换为自定义 `_DualSwitchTile`：
```dart
Widget _buildAppTile(Map<String, dynamic> app, NotificationManager manager) {
  final packageName = app['packageName'] as String;
  final appName = app['appName'] as String;
  final isCollected = manager.isPackageCollected(packageName);
  final isSynced = manager.isPackageSynced(packageName);
  return ListTile(
    title: Text(appName, style: const TextStyle(fontSize: 14)),
    subtitle: Text(packageName, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 收集开关
        _LabeledSwitch(
          label: l10n.collect,
          value: isCollected,
          onChanged: (v) => manager.setPackageCollected(packageName, v),
        ),
        const SizedBox(width: 8),
        // 同步开关（收集关时禁用）
        _LabeledSwitch(
          label: l10n.sync,
          value: isSynced,
          onChanged: isCollected ? (v) => manager.setPackageSynced(packageName, v) : null,
        ),
      ],
    ),
  );
}
```
（`_LabeledSwitch` 是一个小的 StatefulWidget，竖排 label + Switch。）

**3.7 历史 Tab 同步状态（L530-540, L590-598）**

当前调用 `isPackageSyncEnabled`。改为调用 `isPackageSynced`。tile 的 `syncEnabled` 语义保持"同步开关"，另可加小图标显示收集状态。

**3.8 权限卡片优化（L453-499，模块 D）**

当前已基本可用（橙色/绿色卡片 + 授权按钮）。增强：
- 授权后自动 `refreshActiveNotifications()` 回填。
- 增加"返回本应用后自动刷新权限状态"：在 `NotificationSyncPage` 的 `didChangeAppLifecycleState` 中，`resumed` 时重新检查权限。

**3.9 loading 状态（模块 B 配合）**

`_loadInstalledApps()` 期间，设置 Tab 应用列表区域显示 `CircularProgressIndicator`。新增 `bool _appsLoading`。

---

### 阶段 4：MainActivity.kt 性能 + 权限健壮性（模块 B + D）

**文件**：[MainActivity.kt](file:///Users/mac/Documents/code1/clipy1/clipy_android/android/app/src/main/kotlin/com/clipyclone/clipy_android/MainActivity.kt)

**4.1 getInstalledApps 后台线程（L140-142，模块 B）**

当前：`result.success(getInstalledAppsList())` 在主线程。

改为：
```kotlin
"getInstalledApps" -> {
    Thread {
        val apps = getInstalledAppsList()
        runOnUiThread { result.success(apps) }
    }.start()
}
```

**4.2 getInstalledAppsList 排序优化（L215-236）**

当前用 `sortedWith`。保持逻辑但确保在后台线程执行（由 4.1 保证）。可选优化：先返回用户应用，系统应用后续补齐（分批）。本次先保证后台线程即可满足 < 2 秒目标。

**4.3 MethodChannel try/catch（L82-172，模块 D）**

在 `notificationsChannel.setMethodCallHandler` 的每个分支中，对可能抛异常的操作加 try/catch，异常时 `result.error(code, message, null)` 而非崩溃。重点：`dismissNotification`、`openNotification`、`refreshActiveNotifications`、`clearAllNotifications` 已有 null 检查，补充 try/catch 包裹。

**4.4 onDestroy 清理（L191-195，模块 D）**

当前：
```kotlin
override fun onDestroy() {
    clipboardChangeListener?.detach()
    clipboardChangeListener = null
    super.onDestroy()
}
```

增加：
```kotlin
ClipyNotificationListenerService.setMethodChannel(null)
```

---

### 阶段 5：模块 H 稳定性修复

**文件 1**：[notification_health_banner.dart](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/notification_health_banner.dart)

**5.1 stream listener cancel（L21-23）**

当前 L21 `.listen(...)` 未保存引用，且无 `dispose`。改为：
```dart
StreamSubscription? _healthSub;

@override
void initState() {
  super.initState();
  _status = NotificationHealthMonitor.instance.latestStatus;
  _healthSub = NotificationHealthMonitor.instance.onHealthChanged.listen((status) {
    if (mounted) setState(() => _status = status);
  });
  // ... microtask ...
}

@override
void dispose() {
  _healthSub?.cancel();
  super.dispose();
}
```

**文件 2**：[app_database.dart](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/database/app_database.dart)

**5.2 onUpgrade 框架（L24-28）**

当前 `openDatabase` 无 `onUpgrade`。改为：
```dart
final db = await openDatabase(
  path,
  version: schemaVersion,
  onCreate: _onCreate,
  onUpgrade: (db, oldVersion, newVersion) async {
    // 预留：未来 schema 变更在此添加迁移逻辑
    appLog('AppDatabase: upgrade from $oldVersion to $newVersion');
  },
);
```

**文件 3**：[notification_repository.dart](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/database/notification_repository.dart)

**5.3 _trimToLimit 优化（L112-121）**

当前用 `NOT IN` 子查询。优化为按阈值删除：
```dart
Future<void> _trimToLimit(Database db) async {
  final thresholdRow = await db.rawQuery(
    'SELECT post_time FROM notifications ORDER BY post_time DESC LIMIT 1 OFFSET ?',
    [maxRows],
  );
  if (thresholdRow.isEmpty) return;
  final threshold = thresholdRow.first['post_time'] as int;
  await db.delete('notifications', where: 'post_time < ?', whereArgs: [threshold]);
}
```

---

### 阶段 6：本地化文案

**文件**：[app_localizations.dart](file:///Users/mac/Documents/code1/clipy1/clipy_android/lib/app_localizations.dart)

新增 key（中英文）：
- `collect` → "收集" / "Collect"
- `sync` → "同步" / "Sync"
- `collectAll` / `syncAll` / `stopCollectingAll` / `stopSyncingAll`（全选按钮）
- `syncing` → "正在同步" / "Syncing"
- `paused` → "已暂停" / "Paused"

**Mac 端**：如有 `L10n` 或本地化文件，补充通知同步相关文案。本次 Mac 端 UI 变更少，优先级低。

---

## 验证步骤

### 编译验证
1. `cd clipy_android && flutter analyze` — 无 error（重点确认 notification_manager.dart 和 notification_sync_page.dart 无未定义引用）。
2. `flutter build apk --debug` — 构建成功。
3. `cd clipy_macos && swift build`（或 Xcode 构建）— 成功。

### Android 端功能验证
1. 应用列表 < 2 秒加载完成，加载期间有 loading 指示。
2. 授权通知监听权限后，双开关列表可正常切换收集/同步。
3. 收集开 + 同步开 → 通知入库 + Mac 收到。
4. 收集开 + 同步关 → 通知入库 + Mac 收不到。
5. 收集关 → 通知不入库。
6. 总开关关闭 → 不收集任何通知。
7. 手机滑掉通知 → Mac 历史同步移除（dismiss）。

### macOS 端功能验证
1. 清空 UserDefaults（首次安装）→ `notificationSyncEnabled` 默认 `true`。
2. Android 推送通知 → Mac 横幅弹出 + 入库。
3. 关闭 `notificationSound` → 前台横幅不发声。
4. 关闭通知同步开关 → 日志可见 warning，不入库。

### 端到端
1. 同一局域网，Android 产生通知 → Mac 2 秒内收到。
2. 两层筛选组合验证（收集×同步 = 4 种组合）。
3. dismiss 同步：手机滑掉 → Mac 历史移除。

---

## 实施顺序总结

1. **阶段 1**（修复编译 + 模块 C 数据层 + 模块 F）— 解除阻塞，基础
2. **阶段 2**（模块 A Mac 端）— 解决"不可用"
3. **阶段 3**（模块 C UI + D + E）— 用户可见层
4. **阶段 4**（模块 B + D Kotlin）— 性能与健壮性
5. **阶段 5**（模块 H）— 稳定性收尾
6. **阶段 6**（本地化）— 文案补全
