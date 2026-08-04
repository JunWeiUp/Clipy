# 修复锁屏期间通知丢失（两个缺口都修）

## 目标
让锁屏/杀进程期间到达的通知，在 APP 重开 + Mac 重连后能被补发同步；不再依赖"恰好那一刻 Dart isolate 活着"。

## 核心思路
**把"持久化"动作前移到 Kotlin 端**，让 `pending_notification_sync` 的数据源不再唯一依赖 Dart isolate 是否存活；同时打通 `refreshActiveNotifications` 的 diff 补发路径。

---

## 改动一：Kotlin 端原生落盘（缺口 1）

### 1.1 新增依赖 `androidx.room`（不用完整 Room，直接用 SupportSQLite 更轻）
考虑到项目当前只有 `core-ktx` 一个依赖，且数据结构极简单（一张表、存 JSON 字符串），**用原生 `androidx.sqlite` + `androidx.sqlite.framework` 即可，不引入 Room 编译器和注解处理的复杂度**。但 `androidx.sqlite` 也需加依赖。

**最终决策：直接用 Android 内置 `android.database.sqlite.SQLiteDatabase`（零新依赖）**，因为只是单进程内的一张溢出表，不需要跨进程，也不需要 Room 的 ORM 能力。

### 1.2 新增文件 `NativePendingPostStore.kt`
位于 `android/app/src/main/kotlin/com/clipyclone/clipy_android/NativePendingPostStore.kt`

职责：
- 打开/创建一个**独立**的 SQLite 库 `clipy_native_pending.db`（与 Dart 的 `clipy.db` 物理隔离，避免跨进程写 sqflite 的锁/迁移风险 —— 数据库路径用 `context.getDatabasePath("clipy_native_pending.db")`）
- 表结构：`native_pending_posts(rowid INTEGER PRIMARY KEY AUTOINCREMENT, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL)`
- 方法：
  - `insert(payloadJson: String)` — 追加一行
  - `drainAll(): List<String>` — 读取全部 payload_json 并 `DELETE FROM native_pending_posts`（原子事务）
  - `trim(maxRows: Int = 200)` — 保留最新 N 条，防无界增长

线程：所有 DB 操作走后台线程（用 `synchronized` + 单线程 executor 或直接 `db.execSQL`，SQLite 自带线程安全模式 `enableWriteAheadLogging`）。

### 1.3 改 `ClipyNotificationListenerService.kt`
**当前逻辑**（保留）：`onNotificationPosted` → `emitNotificationPosted`：
- 若 channel 非 null → 直接 `invokeMethod`（热路径，不变）
- 若 channel 为 null → `enqueuePending(data)` 塞内存队列（上限 64）

**新增逻辑**：在 `emitNotificationPosted` 里，**无论 channel 是否为 null，都先 `NativePendingPostStore.insert(json)` 落盘**。即：
```
fun emitNotificationPosted(data) {
    val json = encodeToJson(data)        // 新增：序列化
    NativePendingPostStore.insert(context, json)   // 新增：总是落盘
    runOnMainThread {
        val channel = methodChannel
        if (channel == null) {
            // 内存队列保留作为"Activity 短暂重建"的快速通道（可选，可删）
            enqueuePending(data)
        } else {
            channel.invokeMethod("onNotificationPosted", data)
        }
    }
}
```
> 说明：热路径（channel 活着）时也落盘，是因为"落盘"是"是否已同步给 Mac"的唯一事实来源 —— 仅当 Mac 回 ack 后才从 Dart 侧 `pending_notification_sync` 删除。Kotlin 侧的 `native_pending_posts` 表只是一个**中转缓冲**，Dart 启动消费后即清空，不承担"是否已 ack"的职责（那是 Dart `pending_notification_sync` 的活）。所以热路径落盘后必须由 Dart 在 ack 时清理，否则重复消费 —— 见 1.4。

**修正（避免双重持久化复杂度）**：热路径不落盘。改为：
- channel 非 null（热路径）→ 直接 `invokeMethod`，**不落盘 native 表**（Dart 端 `insertPendingSync` 已负责持久化 + ack 清理，这条链路本来就对）
- channel 为 null（冷路径）→ `NativePendingPostStore.insert(json)` 落盘 native 表 + 内存队列（内存队列作为 Activity 快速重建的缓冲，可保留也可删）

这样 `native_pending_posts` 表的语义清晰：**只有"Dart 没机会处理"的通知才进去**，Dart 启动消费后整表清空，不与 Dart 的 `pending_notification_sync` 重叠，无双重删除问题。

### 1.4 MainActivity 新增 method `drainNativePendingPosts`
在 `NOTIFICATIONS_CHANNEL` 的 handler 里加：
```
"drainNativePendingPosts" -> {
    result.success(NativePendingPostStore.drainAll())  // 返回 List<String>，已清表
}
```

### 1.5 启动消费时机
在 `MainActivity.configureFlutterEngine` 注册完 channel 后（即 `setMethodChannel` 之后），**不需要**主动触发消费 —— 由 Dart 侧 `NotificationManager.init()` 在 `setMethodCallHandler` 完成后主动调用 `drainNativePendingPosts`（见改动二）。这样保证消费发生在 Dart 已准备好 `_handleNotificationPosted` 之后。

---

## 改动二：Dart 端启动时消费 native 溢出表（缺口 1 收尾）

### 2.1 `notification_manager.dart` — `init()` 末尾追加
```
// 消费 Kotlin 端在 channel=null 期间落盘的通知
unawaited(_drainNativePendingPosts());
```
新增方法：
```
Future<void> _drainNativePendingPosts() async {
  try {
    final list = await _channel.invokeMethod<List<dynamic>>('drainNativePendingPosts');
    if (list == null || list.isEmpty) return;
    appLog('Consumed ${list.length} native-buffered notification(s)');
    for (final item in list) {
      if (item is String) {
        final data = jsonDecode(item) as Map<String, dynamic>;
        await _handleNotificationPosted(data);  // 复用现成路径：upsert + insertPendingSync + broadcast
      }
    }
  } catch (e) {
    appLog('drainNativePendingPosts failed: $e', level: 'warning');
  }
}
```
关键：`_handleNotificationPosted` 此时 `_suppressBroadcast` 为 false（`init` 里没设），所以这些补进来的通知会正常走 `_broadcastToSync` → `insertPendingSync`（写 Dart 的 `pending_notification_sync`）→ 下次 Mac session up 时 `_flushPending` 重发。

> 顺序：`init()` 里 `_channel.setMethodCallHandler` 在前（第 82 行），`_drainNativePendingPosts` 在后，保证消费时 handler 已就绪。

### 2.2 关于内存队列 `pendingPostedNotifications` 的去留
Kotlin 侧 `flushPendingPostedNotifications()`（在 `setMethodChannel` 时触发）仍保留，作为"Activity 短暂重建、Dart engine 已就绪但 drain 还没跑"的快速通道 —— 与 native 表 drain 不冲突（drain 是全量清表，flush 是清内存队列，两者数据源不同）。但需保证**不会重复处理同一条**：因为 `_handleNotificationPosted` 里 `NotificationRepository.upsert` 按 id 去重（`_isDuplicate`），即便同一条通知被 flush 和 drain 各投递一次，Dart 侧也只会入库/入同步队列一次（accepted 第二次返回 false）。**幂等安全**。

---

## 改动三：`refreshActiveNotifications` diff 补发（缺口 2）

### 3.1 `notification_manager.dart` — 重写 `refreshActiveNotifications`
**当前**：全程 `_suppressBroadcast = true`，所有 active 通知只入本地历史表。

**改为**：不再一刀切 suppress。对每条 active 通知，判断"是否需要补发同步"：
```
Future<void> refreshActiveNotifications() async {
  if (!isEnabled) return;
  _suppressBroadcast = true;  // 仍 suppress，走专门的 diff 逻辑而非 _broadcastToSync
  try {
    final result = await _channel.invokeMethod<List<dynamic>>('refreshActiveNotifications');
    if (result == null) return;
    for (final item in result) {
      if (item is Map) {
        await _handleNotificationPosted(Map<String, dynamic>.from(item));
      }
    }
  } catch (e) {
    appLog('...refresh error...', level: 'warning');
  } finally {
    _suppressBroadcast = false;
  }
  // 新增：refresh 完成后，扫描本地历史表，把"应该同步但未在 pending 同步队列里"的补进去
  await _backfillMissingToPendingSync();
}
```

### 3.2 新增 `_backfillMissingToPendingSync()`
逻辑：
1. 从 `notifications` 表查出所有"符合同步条件"的通知（`_shouldSync(packageName)` 为 true、非自我包名、近期 N 天内 —— N 取 2 天，避免把很久以前的 active 通知一次性灌给 Mac）。
2. 从 `pending_notification_sync` 表查出现在已排队待发的 notification_id 集合。
3. 对差集（在历史表里、但不在 pending 队列里、且**也未被确认已送达**）的每条，调用 `_broadcastToSync(entry)` 重新构造 payload并 `insertPendingSync` + 即时广播。

**"已确认送达"的判定**：这里有个难点 —— 当前表结构没有 `synced` 标记。最稳妥的判定是：**只要它现在不在 `pending_notification_sync` 里，就视为"已被 ack 清除 = 已送达"**。但这会导致"Mac 从未收到、ack 从未回来"的通知永远补不进去。

**解决方案（关键设计决策）**：给 `notifications` 表加一列 `sync_state`（schemaVersion 4→5 迁移）：
- `0 = pending`（待同步，初始）
- `1 = acked`（Mac 已确认收到）

ack 路径（`handleAck`）里把对应 `notifications` 行的 `sync_state` 置 1。
`_backfillMissingToPendingSync` 只补 `sync_state = 0` 且不在 `pending_notification_sync` 表里的行。

这样语义清晰：
- Mac 收到并 ack → `sync_state=1`，永不重复补发
- Mac 没收到/没 ack → `sync_state=0`，refresh 时若发现它没在 pending 队列（说明之前 broadcast 丢了或从没 broadcast 过），补进 pending 队列 + 即时广播

### 3.3 `NotificationRepository` 新增方法
- `fetchUnsyncedForBackfill({required bool Function(String) shouldSync, int withinDays = 2})` → 返回 `sync_state=0` 且符合条件且 post_time 在 N 天内的列表
- `markSynced(String id)` → ack 时调用
- `fetchPendingSyncIds()` → 返回 `pending_notification_sync` 表里所有 notification_id 集合（backfill 时排除用）

### 3.4 `app_database.dart` — schemaVersion 4 → 5 迁移
```
if (oldVersion < 5) {
  await db.execute('ALTER TABLE notifications ADD COLUMN sync_state INTEGER NOT NULL DEFAULT 0');
}
```
`_onCreate` 里 `notifications` 表 DDL 也加 `sync_state INTEGER NOT NULL DEFAULT 0`。

### 3.5 `handleAck` 改造
```
void handleAck(String hash) {
  if (hash.isEmpty) return;
  NotificationRepository.instance.removePendingSync(hash);
  NotificationRepository.instance.markSynced(hash);   // 新增
  appLog('ACK received, removed pending sync + marked synced for $hash');
}
```

---

## 改动四：触发时机对齐

### 4.1 何时触发 backfill
`_backfillMissingToPendingSync` 在以下时机调用（都已在现有流程里）：
- `refreshActiveNotifications()` 末尾（改动三已含）—— 覆盖 `init()` 和 `onListenerConnected` 两个入口
- **可选增强**：`SyncManager._flushPending(peerId)` 成功后不主动 backfill（flush 只重发已在 pending 表里的，backfill 是发现"本该在但不在"的，两者职责不同，不混）

这样：APP 重开 → `init` → `refreshActiveNotifications` → `_backfillMissingToPendingSync` 把漏的补进 pending 队列 → 之后 Mac session up 时 `_flushPending` 正常重发。**即使 Mac 此刻未连接，pending 队列里也已就绪**。

### 4.2 冷启动顺序保证
`main.dart` 启动顺序（已确认）：
```
SyncManager.init()   // line 498
NotificationManager.init()  // line 504 —— 内部会 _drainNativePendingPosts + refreshActiveNotifications + _backfillMissingToPendingSync
```
NotificationManager.init 在 SyncManager.init 之后，backfill 写入 pending 队列后，SyncManager 后续 session up 时的 `_flushPending` 自然消费。无需改 main.dart。

---

## 不改动的部分（已验证无需动）
- `SyncManager._flushPending` / `_fanout` / `_deliver` / `_enqueuePending`：重发逻辑本身正确
- `pending_notification_sync` 表结构、`cleanOldPendingSync` 清理策略（7天/500条）
- Mac 端 `NotificationManager.handleRemoteNotification` / `sendNotificationAck` / `upsertLocked` 去重：协议幂等，无需改
- `ClipySyncForegroundService`：保活职责不变
- `ClipyNotificationListenerService` 的 rebind/forceReconnect 逻辑：不变

---

## 文件清单

**新增（1）**
- `clipy_android/android/app/src/main/kotlin/com/clipyclone/clipy_android/NativePendingPostStore.kt`

**修改（5）**
- `clipy_android/android/app/src/main/kotlin/com/clipyclone/clipy_android/ClipyNotificationListenerService.kt` — channel=null 时落盘 native 表
- `clipy_android/android/app/src/main/kotlin/com/clipyclone/clipy_android/MainActivity.kt` — 新增 `drainNativePendingPosts` method handler
- `clipy_android/lib/notification_manager.dart` — init 消费 native 表；refreshActiveNotifications 末尾 backfill；handleAck 标记 synced
- `clipy_android/lib/database/notification_repository.dart` — 新增 fetchUnsyncedForBackfill / markSynced / fetchPendingSyncIds；upsert 时新通知默认 sync_state=0
- `clipy_android/lib/database/app_database.dart` — schemaVersion 4→5，notifications 加 sync_state 列

**不动**：Mac 端、SyncManager、main.dart、ClipySyncForegroundService、proguard（用内置 SQLiteDatabase 无新类需 keep，且已有 `-keep class com.clipyclone.clipy_android.**`）

---

## 验证要点
1. 编译：`cd clipy_android && proxy && flutter build apk --debug` 通过
2. 场景 A（缺口1）：APP 在后台/被杀，锁屏收到通知 → 重开 APP → 日志见 "Consumed N native-buffered notification(s)" → Mac 连上后收到该通知
3. 场景 B（缺口2）：APP 重开后状态栏里还有未同步的旧通知 → 日志见 backfill 补了 M 条 → Mac 收到
4. 幂等：同一条通知被 flush + drain 各投递一次，Dart 只入库一次（upsert 去重）；Mac 收到两次也只显示一次（entry.id 去重）
5. ack 正常：Mac 收到后回 notif.ack → Android handleAck → removePendingSync + markSynced → 该通知不再被 backfill 重复补