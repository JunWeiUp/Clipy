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

    final accepted = await NotificationRepository.instance.upsert(entry);
    if (accepted) {
      lastNotificationReceivedAt = DateTime.now();
      if (!_suppressBroadcast && _shouldSync(packageName)) {
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
    appLog('NotificationManager: ACK received, removed pending sync for $hash');
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
    final accepted = await NotificationRepository.instance.upsert(entry);
    if (accepted) {
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

  Future<void> requestListenerRebind() async {
    try {
      await _channel.invokeMethod('requestListenerRebind');
    } catch (_) {}
  }

  Future<void> openListenerSettings() async {
    try {
      await _channel.invokeMethod('openListenerSettings');
    } catch (e) {
      appLog('NotificationManager: error opening listener settings: $e',
          level: 'error');
    }
  }

  Future<void> refreshActiveNotifications() async {
    if (!isEnabled) return;
    _suppressBroadcast = true;
    try {
      await _channel.invokeMethod('refreshActiveNotifications');
    } catch (e) {
      appLog('NotificationManager: error refreshing active notifications: $e',
          level: 'warning');
    } finally {
      _suppressBroadcast = false;
    }
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
