import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database/notification_repository.dart';
import 'log_manager.dart';
import 'models.dart';
import 'sync_manager.dart';

class NotificationManager {
  static final NotificationManager instance = NotificationManager._();
  NotificationManager._();

  static const _channel =
      MethodChannel('com.clipyclone.clipy_android/notifications');
  static const _selfPackageName = 'com.clipyclone.clipy_android';
  static const _permissionsChannel =
      MethodChannel('com.clipyclone.clipy_android/permissions');

  List<String> collectedPackages = []; // 收集白名单：空 = 收集全部
  List<String> syncedPackages = []; // 同步白名单：空 = 同步全部已收集
  bool isEnabled = false;
  DateTime? lastNotificationReceivedAt;
  DateTime? monitoringStartedAt;
  bool _suppressBroadcast = false;

  final _notificationsChangedController = StreamController<void>.broadcast();
  Stream<void> get onNotificationsChanged =>
      _notificationsChangedController.stream;

  final _collectedPackagesChangedController =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get onCollectedPackagesChanged =>
      _collectedPackagesChangedController.stream;

  final _syncedPackagesChangedController =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get onSyncedPackagesChanged =>
      _syncedPackagesChangedController.stream;

  Future<int> count() => NotificationRepository.instance.count();

  Future<List<NotificationPackageGroup>> fetchPackageGroups({
    required int offset,
    required int limit,
  }) {
    return NotificationRepository.instance.fetchPackageGroups(
      offset: offset,
      limit: limit,
    );
  }

  Future<List<NotificationEntry>> fetchByPackage(
    String packageName, {
    required int offset,
    required int limit,
  }) {
    return NotificationRepository.instance.fetchByPackage(
      packageName,
      offset: offset,
      limit: limit,
    );
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('notificationSyncEnabled') ?? false;

    // 一次性迁移旧键 notificationAllowedPackages → collectedPackages
    final legacy = prefs.getStringList('notificationAllowedPackages');
    if (legacy != null) {
      collectedPackages = legacy;
      await prefs.remove('notificationAllowedPackages');
      await prefs.setStringList(
          'notificationCollectedPackages', collectedPackages);
    } else {
      collectedPackages =
          prefs.getStringList('notificationCollectedPackages') ?? [];
    }
    syncedPackages = prefs.getStringList('notificationSyncedPackages') ?? [];

    _channel.setMethodCallHandler(_handleMethodCall);
    monitoringStartedAt = DateTime.now();
    if (isEnabled) {
      // 先消费 Kotlin 端在 channel=null 期间（锁屏 / 进程被回收）落盘的通知，
      // 再 refresh active 通知。两者都走 _handleNotificationPosted，由 upsert 去重保证幂等。
      unawaited(drainNativePendingPosts());
      unawaited(refreshActiveNotifications());
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onNotificationPosted':
          final Map<dynamic, dynamic> args = call.arguments;
          await _handleNotificationPosted(Map<String, dynamic>.from(args));
          break;
        case 'onNotificationRemoved':
          final Map<dynamic, dynamic> removedArgs = call.arguments;
          await _handleNotificationRemoved(
              Map<String, dynamic>.from(removedArgs));
          break;
        case 'onListenerConnected':
          final Map<dynamic, dynamic> args = call.arguments;
          final connected = args['connected'] as bool? ?? true;
          appLog('NotificationManager: listener connection state changed: $connected');
          if (connected) {
            lastNotificationReceivedAt ??= DateTime.now();
            if (isEnabled) {
              unawaited(refreshActiveNotifications());
            }
          } else if (isEnabled) {
            // Defense in depth: native already requestRebinds on disconnect;
            // also nudge from Dart in case OEM ignored the first request.
            unawaited(requestListenerRebind());
          }
          _notificationsChangedController.add(null);
          break;
      }
    } catch (e) {
      appLog('NotificationManager: method call error: $e', level: 'error');
    }
  }

  Future<void> _handleNotificationPosted(Map<String, dynamic> data) async {
    if (!isEnabled) return;

    final packageName = data['packageName'] as String? ?? '';
    if (packageName != _selfPackageName &&
        collectedPackages.isNotEmpty &&
        !collectedPackages.contains(packageName)) {
      return; // 不收集，不入库
    }

    final notificationKey = data['key'] as String?;
    final now = DateTime.now().microsecondsSinceEpoch;
    final entry = NotificationEntry(
      id: '${now}_${notificationKey ?? packageName}',
      notificationKey: notificationKey,
      packageName: packageName,
      appName: data['appName'] as String? ?? packageName,
      title: data['title'] as String? ?? '',
      subtitle: data['subtitle'] as String?,
      body: data['body'] as String? ?? '',
      postTime: (data['postTime'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      groupKey: data['groupKey'] as String?,
      isClearable: data['isClearable'] as bool? ?? true,
      extras: Map<String, dynamic>.from(data['extras'] as Map? ?? {}),
    );

    final result = await NotificationRepository.instance.upsert(entry);
    if (result.accepted) {
      lastNotificationReceivedAt = DateTime.now();
      if (!_suppressBroadcast && _shouldSync(packageName)) {
        // Replacements (esp. WeChat same-person updates) must dismiss the old
        // peer banner first, otherwise Mac keeps both the previous and the new.
        for (final old in result.replaced) {
          _broadcastDismissForReplaced(old);
        }
        _broadcastToSync(entry);
      }
      _notificationsChangedController.add(null);
    }
  }

  bool _shouldSync(String packageName) {
    if (packageName == _selfPackageName) return false;
    if (syncedPackages.isEmpty) return true; // 空 = 同步全部
    return syncedPackages.contains(packageName);
  }

  Future<void> _handleNotificationRemoved(Map<String, dynamic> data) async {
    final key = data['key'] as String?;
    final packageName = data['packageName'] as String? ?? '';
    if (key == null) return;
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

  void _broadcastDismissForReplaced(NotificationEntry old) {
    NotificationRepository.instance.removePendingSync(old.id);
    SyncManager.instance.broadcastNotificationMessage(
      type: 'notification/dismiss',
      content: jsonEncode({
        'notificationKey': old.notificationKey,
        'packageName': old.packageName,
        'groupKey': old.groupKey,
      }),
      hash: '',
    );
  }

  void _broadcastToSync(NotificationEntry entry) {
    final payload = entry.toJson();
    payload['extras'] = entry.extras.map(
      (key, value) => MapEntry(key, value?.toString() ?? ''),
    );
    final content = jsonEncode(payload);
    // Persist to offline delivery queue (removed on ACK from Mac)
    NotificationRepository.instance.insertPendingSync(
      notificationId: entry.id,
      content: content,
      hash: entry.id,
    );
    SyncManager.instance.broadcastNotificationMessage(
      type: 'notification/post',
      content: content,
      hash: entry.id,
    );
  }

  /// Called when Mac acknowledges receipt of a notification.
  void handleAck(String hash) {
    if (hash.isEmpty) return;
    NotificationRepository.instance.removePendingSync(hash);
    NotificationRepository.instance.markSynced(hash);
    appLog('NotificationManager: ACK received, removed pending sync + marked synced for $hash');
  }

  /// 消费 Kotlin 端在 MethodChannel 不可用期间（锁屏 / 进程被回收 /
  /// Activity 重建）落盘到 NativePendingPostStore 的通知。
  ///
  /// 每条 JSON 走标准的 [_handleNotificationPosted] 路径：upsert 入库 +
  /// （若未被 suppress）insertPendingSync + 即时广播。upsert 的去重保证
  /// 同一条通知即使被内存队列 flush 和本方法各投递一次也只入库一次。
  /// Public so FGS / Application can drain after headless bootstrap.
  Future<void> drainNativePendingPosts() async {
    try {
      final list = await _channel
          .invokeMethod<List<dynamic>>('drainNativePendingPosts');
      if (list == null || list.isEmpty) return;
      appLog('NotificationManager: consumed ${list.length} native-buffered notification(s)');
      for (final item in list) {
        if (item is String) {
          try {
            final data = jsonDecode(item) as Map<String, dynamic>;
            await _handleNotificationPosted(data);
          } catch (e) {
            appLog(
                'NotificationManager: native buffered post decode error: $e',
                level: 'warning');
          }
        }
      }
    } catch (e) {
      appLog('NotificationManager: drainNativePendingPosts failed: $e',
          level: 'warning');
    }
  }

  /// Backfill：扫描本地历史表，把"应该同步但既不在 pending 队列里、也未被 Mac
  /// ack"的通知补进同步队列并即时广播。
  ///
  /// 覆盖缺口 2：refreshActiveNotifications 在 suppressBroadcast 下把 active
  /// 通知只写历史表不入同步队列；本方法在 refresh 完成后补上漏发的部分。
  /// 也覆盖"曾经 broadcast 但丢了、Mac 从未收到"的情况。
  Future<void> _backfillMissingToPendingSync() async {
    if (!isEnabled) return;
    try {
      final alreadyPending =
          await NotificationRepository.instance.fetchPendingSyncIds();
      final unsynced = await NotificationRepository.instance.fetchUnsynced(
        shouldSync: _shouldSync,
        withinDays: 2,
        selfPackageName: _selfPackageName,
      );
      final toBackfill = unsynced
          .where((e) => !alreadyPending.contains(e.id))
          .toList();
      if (toBackfill.isEmpty) return;
      appLog('NotificationManager: backfilling ${toBackfill.length} missed notification(s) to sync queue');
      for (final entry in toBackfill) {
        _broadcastToSync(entry);
      }
    } catch (e) {
      appLog('NotificationManager: backfill failed: $e', level: 'warning');
    }
  }

  void handleRemoteNotification(String decrypted, String senderDevice) {
    try {
      final json = jsonDecode(decrypted);
      final entry = NotificationEntry.fromJson(json);
      unawaited(_upsertRemote(entry));
    } catch (e) {
      appLog('NotificationManager: error handling remote notification: $e',
          level: 'error');
    }
  }

  Future<void> _upsertRemote(NotificationEntry entry) async {
    final result = await NotificationRepository.instance.upsert(entry);
    if (result.accepted) {
      _notificationsChangedController.add(null);
    }
  }

  void handleRemoteDismiss(String decrypted) {
    try {
      final json = jsonDecode(decrypted);
      final request = NotificationDismissRequest.fromJson(json);
      dismissNotification(request);
    } catch (e) {
      appLog('NotificationManager: error handling remote dismiss: $e',
          level: 'error');
    }
  }

  Future<bool> isListenerPermissionGranted() async {
    final status = await getListenerStatus();
    return status.permissionGranted;
  }

  Future<bool> isBatteryOptimizationExempt() async {
    try {
      final result = await _permissionsChannel
          .invokeMethod<bool>('isBatteryOptimizationExempt');
      return result ?? false;
    } catch (e) {
      appLog('NotificationManager: error checking battery optimization: $e',
          level: 'warning');
      return true; // Don't block on error
    }
  }

  Future<void> requestBatteryOptimizationExemption() async {
    try {
      await _permissionsChannel
          .invokeMethod<void>('requestBatteryOptimizationExemption');
    } catch (e) {
      appLog('NotificationManager: error requesting battery optimization: $e',
          level: 'warning');
    }
  }

  /// Whether notifications (incl. the sync FGS persistent one) can surface.
  /// On Android 13+ POST_NOTIFICATIONS defaults to denied, which hides even
  /// foreground-service notifications.
  Future<bool> areNotificationsEnabled() async {
    try {
      final result = await _permissionsChannel
          .invokeMethod<bool>('areNotificationsEnabled');
      return result ?? true;
    } catch (e) {
      appLog('NotificationManager: error checking notifications: $e',
          level: 'warning');
      return true; // Don't block on error
    }
  }

  /// Shows the POST_NOTIFICATIONS dialog (Android 13+) or opens the app's
  /// notification settings page as fallback.
  Future<void> requestNotificationPermission() async {
    try {
      await _permissionsChannel
          .invokeMethod<void>('requestNotificationPermission');
    } catch (e) {
      appLog('NotificationManager: error requesting notifications: $e',
          level: 'warning');
    }
  }

  Future<NotificationListenerStatus> getListenerStatus() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getListenerStatus',
      );
      if (result == null) {
        return const NotificationListenerStatus(
          permissionGranted: false,
          serviceConnected: false,
          activeNotificationCount: 0,
        );
      }
      return NotificationListenerStatus.fromMap(result);
    } catch (e) {
      return const NotificationListenerStatus(
        permissionGranted: false,
        serviceConnected: false,
        activeNotificationCount: 0,
      );
    }
  }

  Future<void> requestListenerRebind({bool force = false}) async {
    try {
      await _channel.invokeMethod('requestListenerRebind', {'force': force});
      appLog(
        force
            ? 'NotificationManager: force reconnect (component toggle) requested'
            : 'NotificationManager: soft rebind requested',
      );
    } catch (_) {}
  }

  /// Opens Xiaomi/HyperOS autostart settings when available.
  Future<bool> openOemAutostartSettings() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('openOemAutostartSettings');
      return result ?? false;
    } catch (e) {
      appLog('NotificationManager: openOemAutostartSettings failed: $e',
          level: 'warning');
      return false;
    }
  }

  Future<void> openListenerSettings() async {
    try {
      await _channel.invokeMethod('openListenerSettings');
    } catch (e) {
      appLog('NotificationManager: error opening listener settings: $e',
          level: 'error');
    }
  }

  /// Pull currently-active status-bar notifications into local history.
  ///
  /// 仍然 suppressBroadcast：active 快照走 suppress 入库，避免和实时 onNotificationPosted
  /// 竞争重复广播。但在 refresh 完成后调用 [_backfillMissingToPendingSync]：
  /// 把"应该同步、却从未进过 pending 队列、且未被 Mac ack"的通知补发出去。
  /// 这样锁屏期间收到、现在还挂在状态栏的通知能在 APP 重开 + Mac 连上后补发。
  Future<void> refreshActiveNotifications() async {
    if (!isEnabled) return;
    _suppressBroadcast = true;
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('refreshActiveNotifications');
      if (result == null) return;
      for (final item in result) {
        if (item is Map) {
          await _handleNotificationPosted(Map<String, dynamic>.from(item));
        }
      }
    } catch (e) {
      appLog('NotificationManager: error refreshing active notifications: $e',
          level: 'warning');
    } finally {
      _suppressBroadcast = false;
    }
    // refresh 把 active 通知写进了历史表，但它们 sync_state=0 且不在 pending 队列里。
    // backfill 会把它们补进 pending_notification_sync + 即时广播给已连接的 Mac。
    await _backfillMissingToPendingSync();
  }

  Future<void> dismissNotification(NotificationDismissRequest request) async {
    try {
      await _channel.invokeMethod('dismissNotification', {
        'packageName': request.packageName,
        'groupKey': request.groupKey,
        'notificationKey': request.notificationKey,
      });
    } catch (e) {
      appLog('NotificationManager: error dismissing notification: $e',
          level: 'error');
    }
  }

  Future<void> openNotification(NotificationEntry entry) async {
    try {
      await _channel.invokeMethod('openNotification', {
        'packageName': entry.packageName,
        'notificationKey': entry.notificationKey,
      });
    } catch (e) {
      appLog('NotificationManager: error opening notification: $e',
          level: 'error');
    }
  }

  Future<void> clearAll() async {
    try {
      await _channel.invokeMethod('clearAllNotifications');
      await NotificationRepository.instance.clearAll();
      _notificationsChangedController.add(null);
    } catch (e) {
      appLog('NotificationManager: error clearing all notifications: $e',
          level: 'error');
    }
  }

  List<Map<String, dynamic>>? _installedAppsCache;
  bool _appsLoaded = false;

  Future<List<Map<String, dynamic>>> getInstalledApps({bool forceRefresh = false}) async {
    if (!forceRefresh && _appsLoaded && _installedAppsCache != null) {
      return _installedAppsCache!;
    }
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (result == null) return _installedAppsCache ?? [];
      final apps =
          result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _installedAppsCache = apps;
      _appsLoaded = true;
      return apps;
    } catch (e) {
      return _installedAppsCache ?? [];
    }
  }

  Future<void> setEnabled(bool enabled) async {
    isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notificationSyncEnabled', enabled);
    if (enabled) {
      await refreshActiveNotifications();
    }
  }

  // —— 收集层 ——
  bool isPackageCollected(String packageName) {
    if (packageName == _selfPackageName) return false;
    if (collectedPackages.isEmpty) return true; // 空 = 收集全部
    return collectedPackages.contains(packageName);
  }

  Future<void> setPackageCollected(String packageName, bool collected) async {
    if (packageName == _selfPackageName) return;
    final prefs = await SharedPreferences.getInstance();
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
    await prefs.setStringList(
        'notificationCollectedPackages', collectedPackages);
    _collectedPackagesChangedController.add(collectedPackages);
  }

  // —— 同步层 ——
  bool isPackageSynced(String packageName) {
    if (packageName == _selfPackageName) return false;
    if (syncedPackages.isEmpty) return true; // 空 = 同步全部已收集
    return syncedPackages.contains(packageName);
  }

  Future<void> setPackageSynced(String packageName, bool synced) async {
    if (packageName == _selfPackageName) return;
    final prefs = await SharedPreferences.getInstance();
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
    await prefs.setStringList('notificationSyncedPackages', syncedPackages);
    _syncedPackagesChangedController.add(syncedPackages);
  }

  // —— 批量操作 ——
  Future<void> collectAllPackages() async {
    collectedPackages = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('notificationCollectedPackages');
    _collectedPackagesChangedController.add(collectedPackages);
  }

  Future<void> syncAllPackages() async {
    syncedPackages = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('notificationSyncedPackages');
    _syncedPackagesChangedController.add(syncedPackages);
  }

  Future<List<String>> _knownPackageNames() async {
    final packages = <String>{
      ...await NotificationRepository.instance.distinctPackageNames(),
    };
    for (final app in await getInstalledApps()) {
      final packageName = app['packageName'] as String?;
      if (packageName != null && packageName.isNotEmpty) {
        packages.add(packageName);
      }
    }
    packages.remove(_selfPackageName);
    return packages.toList()..sort();
  }

  Future<void> removeNotification(String id) async {
    await NotificationRepository.instance.removeById(id);
    _notificationsChangedController.add(null);
  }

  Future<void> clearAllLocal() async {
    await NotificationRepository.instance.clearAll();
    _notificationsChangedController.add(null);
  }

  void broadcastDismissToRemote(NotificationDismissRequest request) {
    SyncManager.instance.broadcastNotificationMessage(
      type: 'notification/dismiss',
      content: jsonEncode(request.toJson()),
      hash: '',
    );
  }

  void broadcastClearAllToRemote() {
    SyncManager.instance.broadcastNotificationMessage(
      type: 'notification/clear_all',
      content: '{}',
      hash: '',
    );
  }
}
