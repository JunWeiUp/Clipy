import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_manager.dart';
import 'models.dart';
import 'storage_paths.dart';
import 'sync_manager.dart';
import 'collector_manager.dart';

class NotificationManager {
  static final NotificationManager instance = NotificationManager._();
  NotificationManager._();

  static const _channel =
      MethodChannel('com.clipyclone.clipy_android/notifications');
  static const _legacyStorageKey = 'notification_history';
  static const _historyFileName = 'notification_history.jsonl';
  static const _duplicateNotificationWindowMs = 30000;
  static const _selfPackageName = 'com.clipyclone.clipy_android';

  List<String> allowedPackages = [];
  bool isEnabled = false;
  DateTime? lastNotificationReceivedAt;
  DateTime? monitoringStartedAt;
  File? _historyFile;
  Future<void> _storageWriteQueue = Future.value();

  final _notificationsChangedController =
      StreamController<List<NotificationEntry>>.broadcast();
  Stream<List<NotificationEntry>> get onNotificationsChanged =>
      _notificationsChangedController.stream;

  final _allowedPackagesChangedController =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get onAllowedPackagesChanged =>
      _allowedPackagesChangedController.stream;

  final List<NotificationEntry> _activeNotifications = [];
  List<NotificationEntry> get activeNotifications =>
      List.unmodifiable(_activeNotifications);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('notificationSyncEnabled') ?? true;
    allowedPackages = prefs.getStringList('notificationAllowedPackages') ?? [];

    await _initStorage();
    await _loadFromDisk();
    await _migrateLegacyHistory(prefs);

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
          _handleNotificationPosted(Map<String, dynamic>.from(args));
          break;
        case 'onNotificationRemoved':
          final Map<dynamic, dynamic> args = call.arguments;
          _handleNotificationRemoved(Map<String, dynamic>.from(args));
          break;
      }
    } catch (e) {
      appLog('NotificationManager: method call error: $e', level: 'error');
    }
  }

  void _handleNotificationPosted(Map<String, dynamic> data) {
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

    final accepted = _upsertNotification(entry);
    appLog('NotificationManager: posted ${entry.packageName}: ${entry.title}');
    if (accepted) {
      lastNotificationReceivedAt = DateTime.now();
      _broadcastToSync(entry);
    }
  }

  void _handleNotificationRemoved(Map<String, dynamic> data) {
    // Notification history is append-only from the user's perspective. A system
    // removal should not erase historical records because one app can post many
    // notifications and each record must remain searchable after dismissal.
  }

  bool _upsertNotification(NotificationEntry entry) {
    final result = _mergeNotificationInMemory(entry);
    if (!result.accepted) return false;

    if (result.rewriteHistory) {
      _rewriteHistoryFile();
    } else {
      _appendToHistoryFile(entry);
    }
    _notificationsChangedController.add(_activeNotifications);
    return true;
  }

  ({bool accepted, bool rewriteHistory}) _mergeNotificationInMemory(
      NotificationEntry entry) {
    if (_isEmptyNotification(entry)) {
      return (accepted: false, rewriteHistory: false);
    }

    final existingIndex =
        _activeNotifications.indexWhere((n) => n.id == entry.id);
    if (existingIndex >= 0) {
      _activeNotifications[existingIndex] = entry;
      final updated = _activeNotifications.removeAt(existingIndex);
      _activeNotifications.insert(0, updated);
      return (accepted: true, rewriteHistory: true);
    }

    final duplicateIndex = _activeNotifications
        .indexWhere((n) => _isDuplicateNotification(n, entry));
    if (duplicateIndex >= 0) {
      _activeNotifications.removeAt(duplicateIndex);
      _activeNotifications.insert(0, entry);
      return (accepted: true, rewriteHistory: true);
    }

    _activeNotifications.insert(0, entry);
    return (accepted: true, rewriteHistory: false);
  }

  bool _isEmptyNotification(NotificationEntry entry) {
    return entry.title.trim().isEmpty &&
        (entry.subtitle ?? '').trim().isEmpty &&
        entry.body.trim().isEmpty &&
        entry.extras.values.every((value) => value.toString().trim().isEmpty);
  }

  bool _isDuplicateNotification(
      NotificationEntry existing, NotificationEntry incoming) {
    if (existing.packageName != incoming.packageName) {
      return false;
    }
    if ((existing.postTime - incoming.postTime).abs() >
        _duplicateNotificationWindowMs) {
      return false;
    }

    if (existing.notificationKey != null &&
        incoming.notificationKey != null &&
        existing.notificationKey == incoming.notificationKey) {
      return true;
    }

    return existing.title.trim() == incoming.title.trim() &&
        (existing.subtitle ?? '').trim() == (incoming.subtitle ?? '').trim() &&
        existing.body.trim() == incoming.body.trim() &&
        existing.groupKey == incoming.groupKey;
  }

  void _broadcastToSync(NotificationEntry entry) {
    final content = jsonEncode(entry.toJson());
    final hash = entry.id;
    SyncManager.instance.broadcastNotificationMessage(
      type: 'notification/post',
      content: content,
      hash: hash,
    );
    CollectorManager.instance.broadcastNotificationToMac(
      CollectorEvent.fromNotificationEntry(
        entry,
        SyncManager.instance.deviceId,
      ),
    );
  }

  void handleRemoteNotification(String decrypted, String senderDevice) {
    try {
      final json = jsonDecode(decrypted);
      final entry = NotificationEntry.fromJson(json);
      _upsertNotification(entry);
      appLog(
          'NotificationManager: received remote notification from $senderDevice: ${entry.title}');
    } catch (e) {
      appLog('NotificationManager: error handling remote notification: $e',
          level: 'error');
    }
  }

  void handleRemoteDismiss(String decrypted) {
    try {
      final json = jsonDecode(decrypted);
      final request = NotificationDismissRequest.fromJson(json);
      dismissNotification(request);
      appLog(
          'NotificationManager: remote dismiss request for ${request.packageName}');
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
      appLog('NotificationManager: error getting listener status: $e',
          level: 'error');
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
    } catch (e) {
      appLog('NotificationManager: error requesting listener rebind: $e',
          level: 'warning');
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

  Future<void> refreshActiveNotifications() async {
    if (!isEnabled) return;
    try {
      await _channel.invokeMethod('refreshActiveNotifications');
    } catch (e) {
      appLog('NotificationManager: error refreshing active notifications: $e',
          level: 'warning');
    }
  }

  Future<void> dismissNotification(NotificationDismissRequest request) async {
    try {
      await _channel.invokeMethod('dismissNotification', {
        'packageName': request.packageName,
        'groupKey': request.groupKey,
        'notificationKey': request.notificationKey,
      });
      _activeNotifications.removeWhere((n) =>
          n.packageName == request.packageName &&
          (request.notificationKey == null ||
              n.notificationKey == request.notificationKey));
      _rewriteHistoryFile();
      _notificationsChangedController.add(_activeNotifications);
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
      _activeNotifications.clear();
      _rewriteHistoryFile();
      _notificationsChangedController.add(_activeNotifications);
    } catch (e) {
      appLog('NotificationManager: error clearing all notifications: $e',
          level: 'error');
    }
  }

  List<Map<String, dynamic>>? _installedAppsCache;

  Future<List<Map<String, dynamic>>> getInstalledApps({bool forceRefresh = false}) async {
    if (!forceRefresh && _installedAppsCache != null) {
      return _installedAppsCache!;
    }
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (result == null) return [];
      final apps =
          result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _installedAppsCache = apps;
      return apps;
    } catch (e) {
      appLog('NotificationManager: error getting installed apps: $e',
          level: 'error');
      return _installedAppsCache ?? [];
    }
  }

  Future<void> setEnabled(bool enabled, {bool syncCollectorCategory = true}) async {
    isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notificationSyncEnabled', enabled);
    if (syncCollectorCategory) {
      await CollectorManager.instance
          .syncNotificationCategoryEnabled(enabled);
    }
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
        if (!packages.contains(packageName)) {
          packages.add(packageName);
        }
      } else {
        packages.remove(packageName);
      }
      packages = packages.toSet().toList()..sort();
    }

    await updateAllowedPackages(packages);
  }

  Future<List<String>> _knownPackageNames() async {
    final packages = <String>{};
    for (final app in await getInstalledApps()) {
      final packageName = app['packageName'] as String?;
      if (packageName != null && packageName.isNotEmpty) {
        packages.add(packageName);
      }
    }
    for (final entry in _activeNotifications) {
      packages.add(entry.packageName);
    }
    packages.remove(_selfPackageName);
    return packages.toList()..sort();
  }

  void removeNotification(String id) {
    _activeNotifications.removeWhere((n) => n.id == id);
    _rewriteHistoryFile();
    _notificationsChangedController.add(_activeNotifications);
  }

  void clearAllLocal() {
    _activeNotifications.clear();
    _rewriteHistoryFile();
    _notificationsChangedController.add(_activeNotifications);
  }

  void broadcastDismissToRemote(NotificationDismissRequest request) {
    final content = jsonEncode(request.toJson());
    SyncManager.instance.broadcastNotificationMessage(
      type: 'notification/dismiss',
      content: content,
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

  // MARK: - Persistence

  Future<void> _initStorage() async {
    try {
      final dir = await StoragePaths.appStorageDirectory();
      _historyFile = File('${dir.path}/$_historyFileName');
      if (!await _historyFile!.exists()) {
        await _historyFile!.create(recursive: true);
      }
    } catch (e) {
      appLog('NotificationManager: error initializing storage: $e',
          level: 'error');
    }
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = _historyFile;
      if (file == null || !await file.exists()) return;

      _activeNotifications.clear();
      var total = 0;
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          total++;
          final entry = NotificationEntry.fromJson(
              Map<String, dynamic>.from(jsonDecode(trimmed) as Map));
          _mergeNotificationInMemory(entry);
        } catch (e) {
          appLog('NotificationManager: skipped invalid history line: $e',
              level: 'warning');
        }
      }
      if (total != _activeNotifications.length) {
        await _rewriteHistoryFile();
      }
      appLog(
          'NotificationManager: loaded ${_activeNotifications.length} notifications from disk');
    } catch (e) {
      appLog('NotificationManager: error loading from disk: $e',
          level: 'error');
    }
  }

  Future<void> _appendToHistoryFile(NotificationEntry entry) {
    final line = '${jsonEncode(entry.toJson())}\n';
    _storageWriteQueue = _storageWriteQueue.then((_) async {
      try {
        final file = _historyFile;
        if (file == null) return;
        await file.writeAsString(line, mode: FileMode.append, flush: false);
      } catch (e) {
        appLog('NotificationManager: error appending history: $e',
            level: 'error');
      }
    });
    return _storageWriteQueue;
  }

  Future<void> _rewriteHistoryFile() {
    final snapshot = List<NotificationEntry>.from(_activeNotifications);
    _storageWriteQueue = _storageWriteQueue.then((_) async {
      try {
        final file = _historyFile;
        if (file == null) return;
        final sink = file.openWrite(mode: FileMode.write);
        for (final entry in snapshot.reversed) {
          sink.writeln(jsonEncode(entry.toJson()));
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        appLog('NotificationManager: error rewriting history: $e',
            level: 'error');
      }
    });
    return _storageWriteQueue;
  }

  Future<void> _migrateLegacyHistory(SharedPreferences prefs) async {
    try {
      final jsonStr = prefs.getString(_legacyStorageKey);
      if (jsonStr == null || jsonStr.isEmpty) return;

      final jsonList = jsonDecode(jsonStr) as List<dynamic>;
      var changed = false;
      for (final item in jsonList.reversed) {
        final entry =
            NotificationEntry.fromJson(Map<String, dynamic>.from(item as Map));
        final result = _mergeNotificationInMemory(entry);
        changed = changed || result.accepted;
      }

      if (changed) {
        await _rewriteHistoryFile();
      }
      await prefs.remove(_legacyStorageKey);
      appLog('NotificationManager: migrated legacy notification history');
    } catch (e) {
      appLog('NotificationManager: error migrating legacy history: $e',
          level: 'error');
    }
  }
}
