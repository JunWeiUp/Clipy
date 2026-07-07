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

  List<String> allowedPackages = [];
  bool isEnabled = false;
  DateTime? lastNotificationReceivedAt;
  DateTime? monitoringStartedAt;
  bool _suppressBroadcast = false;

  final _notificationsChangedController = StreamController<void>.broadcast();
  Stream<void> get onNotificationsChanged =>
      _notificationsChangedController.stream;

  final _allowedPackagesChangedController =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get onAllowedPackagesChanged =>
      _allowedPackagesChangedController.stream;

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
    allowedPackages = prefs.getStringList('notificationAllowedPackages') ?? [];

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
        allowedPackages.isNotEmpty &&
        !allowedPackages.contains(packageName)) {
      return;
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
      if (!_suppressBroadcast) {
        _broadcastToSync(entry);
      }
      _notificationsChangedController.add(null);
    }
  }

  void _broadcastToSync(NotificationEntry entry) {
    final event = CollectorEvent.fromNotificationEntry(
      entry,
      SyncManager.instance.deviceId,
    );
    SyncManager.instance.broadcastCollectorEvent(
      content: jsonEncode(event.toJson()),
      hash: event.id,
    );
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

  Future<void> updateAllowedPackages(List<String> packages) async {
    allowedPackages = packages;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('notificationAllowedPackages', packages);
    _allowedPackagesChangedController.add(allowedPackages);
  }

  bool isPackageSyncEnabled(String packageName) {
    if (packageName == _selfPackageName) return false;
    if (allowedPackages.isEmpty) return true;
    return allowedPackages.contains(packageName);
  }

  Future<void> setPackageSyncEnabled(String packageName, bool enabled) async {
    if (packageName == _selfPackageName) return;

    var packages = List<String>.from(allowedPackages);
    if (allowedPackages.isEmpty) {
      if (enabled) return;
      final known = await _knownPackageNames();
      packages = known.where((pkg) => pkg != packageName).toList();
    } else {
      if (enabled) {
        packages.add(packageName);
      } else {
        packages.remove(packageName);
      }
      packages = packages.toSet().toList()..sort();
    }

    await updateAllowedPackages(packages);
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
