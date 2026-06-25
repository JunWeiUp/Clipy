import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_manager.dart';
import 'models.dart';
import 'storage_paths.dart';
import 'sync_manager.dart';

class CollectorManager {
  static final CollectorManager instance = CollectorManager._();
  CollectorManager._();

  static const _channel = MethodChannel('com.clipyclone.clipy_android/collector');
  static const _historyFileName = 'collector_events.jsonl';
  static const _maxRecentEvents = 100;
  static const _maxBufferedEvents = 500;
  static const _duplicateNotificationWindowMs = 30000;
  static const _duplicateSmsWindowMs = 5000;
  static const _duplicateLocationWindowMs = 60000;
  static const _duplicateLocationDistanceMeters = 50.0;

  bool isEnabled = true;
  final Map<String, bool> categoryEnabled = {
    for (final category in CollectorCategories.all) category: true,
  };

  File? _historyFile;
  final List<CollectorEvent> _recentEvents = [];
  final List<CollectorEvent> _pendingEvents = [];
  Future<void> _storageWriteQueue = Future.value();

  final _eventsChangedController =
      StreamController<List<CollectorEvent>>.broadcast();
  Stream<List<CollectorEvent>> get onEventsChanged =>
      _eventsChangedController.stream;
  List<CollectorEvent> get recentEvents => List.unmodifiable(_recentEvents);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('collectorEnabled') ?? true;
    for (final category in CollectorCategories.all) {
      categoryEnabled[category] =
          prefs.getBool('collectorCategory_$category') ?? true;
    }

    await _initStorage();
    await _loadRecentFromDisk();
    _channel.setMethodCallHandler(_handleMethodCall);

    if (isEnabled) {
      await startForegroundService();
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onCollectorEvent':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final category = args['category'] as String? ?? '';
          final payload = Map<String, dynamic>.from(args['payload'] as Map? ?? {});
          final timestamp = (args['timestamp'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          await emit(
            category: category,
            payload: payload,
            timestamp: timestamp,
            id: args['id'] as String?,
          );
          break;
      }
    } catch (e) {
      appLog('CollectorManager: method call error: $e', level: 'error');
    }
    return null;
  }

  Future<void> emit({
    required String category,
    required Map<String, dynamic> payload,
    int? timestamp,
    String? id,
  }) async {
    if (!isEnabled) return;
    if (categoryEnabled[category] != true) return;

    final event = CollectorEvent(
      id: id ?? '${DateTime.now().microsecondsSinceEpoch}_$category',
      category: category,
      timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
      deviceId: SyncManager.instance.deviceId,
      payload: _normalizePayload(payload),
    );

    if (_isDuplicate(event)) return;

    _rememberEvent(event);
    await _appendToHistoryFile(event);
    _eventsChangedController.add(_recentEvents);

    if (SyncManager.instance.isEnabled) {
      await _broadcastEvent(event);
      await _flushPendingEvents();
    } else {
      _enqueuePending(event);
    }
  }

  Future<void> emitNotification(NotificationEntry entry) async {
    await emit(
      category: CollectorCategories.notification,
      id: entry.id,
      timestamp: entry.postTime,
      payload: {
        'notificationKey': entry.notificationKey,
        'packageName': entry.packageName,
        'appName': entry.appName,
        'title': entry.title,
        'subtitle': entry.subtitle,
        'body': entry.body,
        'groupKey': entry.groupKey,
        'isClearable': entry.isClearable,
        ...entry.extras.map((key, value) => MapEntry('extra_$key', value)),
      },
    );
  }

  Future<void> emitClipboard({
    required String text,
    required String hash,
    String mimeType = 'text/plain',
  }) async {
    await emit(
      category: CollectorCategories.clipboard,
      payload: {
        'text': text,
        'hash': hash,
        'mimeType': mimeType,
      },
    );
  }

  Future<void> setEnabled(bool value) async {
    isEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('collectorEnabled', value);
    if (value) {
      await startForegroundService();
    } else {
      await stopForegroundService();
    }
  }

  Future<void> setCategoryEnabled(String category, bool value) async {
    categoryEnabled[category] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('collectorCategory_$category', value);
  }

  Future<void> startForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startForegroundService');
    } catch (e) {
      appLog('CollectorManager: failed to start foreground service: $e',
          level: 'warning');
    }
  }

  Future<void> stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (e) {
      appLog('CollectorManager: failed to stop foreground service: $e',
          level: 'warning');
    }
  }

  Future<bool> checkPermission(String permission) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel
          .invokeMethod<bool>('checkPermission', {'permission': permission});
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestPermission(String permission) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod('requestPermission', {'permission': permission});
    } catch (e) {
      appLog('CollectorManager: request permission failed: $e', level: 'warning');
    }
  }

  Future<void> openPermissionSettings(String settingsType) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod('openPermissionSettings', {'type': settingsType});
    } catch (e) {
      appLog('CollectorManager: open settings failed: $e', level: 'warning');
    }
  }

  Future<bool> isBatteryOptimizationIgnored() async {
    if (!Platform.isAndroid) return true;
    try {
      final result =
          await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimization');
    } catch (e) {
      appLog('CollectorManager: battery optimization request failed: $e',
          level: 'warning');
    }
  }

  Future<void> _broadcastEvent(CollectorEvent event) async {
    final content = jsonEncode(event.toJson());
    await SyncManager.instance.broadcastCollectorEvent(
      content: content,
      hash: event.id,
    );
  }

  Future<void> _flushPendingEvents() async {
    if (_pendingEvents.isEmpty || !SyncManager.instance.isEnabled) return;
    final pending = List<CollectorEvent>.from(_pendingEvents);
    _pendingEvents.clear();
    for (final event in pending) {
      await _broadcastEvent(event);
    }
  }

  void _enqueuePending(CollectorEvent event) {
    _pendingEvents.add(event);
    if (_pendingEvents.length > _maxBufferedEvents) {
      _pendingEvents.removeRange(0, _pendingEvents.length - _maxBufferedEvents);
    }
  }

  void _rememberEvent(CollectorEvent event) {
    _recentEvents.insert(0, event);
    if (_recentEvents.length > _maxRecentEvents) {
      _recentEvents.removeRange(_maxRecentEvents, _recentEvents.length);
    }
  }

  Map<String, dynamic> _normalizePayload(Map<String, dynamic> payload) {
    return payload.map((key, value) {
      if (value == null) return MapEntry(key, '');
      if (value is String || value is num || value is bool) {
        return MapEntry(key, value);
      }
      return MapEntry(key, value.toString());
    });
  }

  bool _isDuplicate(CollectorEvent incoming) {
    final candidates = [..._recentEvents, ..._pendingEvents];
    switch (incoming.category) {
      case CollectorCategories.notification:
        return candidates.any((existing) {
          if (existing.category != incoming.category) return false;
          if ((existing.timestamp - incoming.timestamp).abs() >
              _duplicateNotificationWindowMs) {
            return false;
          }
          final key = incoming.payload['notificationKey'];
          if (key != null && key == existing.payload['notificationKey']) {
            return true;
          }
          return existing.payload['title'] == incoming.payload['title'] &&
              existing.payload['body'] == incoming.payload['body'] &&
              existing.payload['packageName'] == incoming.payload['packageName'];
        });
      case CollectorCategories.sms:
        return candidates.any((existing) {
          if (existing.category != incoming.category) return false;
          if ((existing.timestamp - incoming.timestamp).abs() >
              _duplicateSmsWindowMs) {
            return false;
          }
          return existing.payload['address'] == incoming.payload['address'] &&
              existing.payload['body'] == incoming.payload['body'];
        });
      case CollectorCategories.call:
        return candidates.any((existing) {
          if (existing.category != incoming.category) return false;
          return existing.payload['phoneNumber'] ==
                  incoming.payload['phoneNumber'] &&
              existing.payload['state'] == incoming.payload['state'] &&
              (existing.timestamp - incoming.timestamp).abs() <= 2000;
        });
      case CollectorCategories.callLog:
        final logId = incoming.payload['logId'];
        if (logId != null && logId.toString().isNotEmpty) {
          return candidates.any((existing) =>
              existing.category == incoming.category &&
              existing.payload['logId'] == logId);
        }
        return candidates.any((existing) {
          if (existing.category != incoming.category) return false;
          return existing.payload['phoneNumber'] ==
                  incoming.payload['phoneNumber'] &&
              existing.payload['type'] == incoming.payload['type'] &&
              existing.payload['date'] == incoming.payload['date'];
        });
      case CollectorCategories.clipboard:
        final hash = incoming.payload['hash'];
        if (hash == null || hash.toString().isEmpty) return false;
        return candidates.any((existing) =>
            existing.category == incoming.category &&
            existing.payload['hash'] == hash);
      case CollectorCategories.location:
        final lat = _asDouble(incoming.payload['latitude']);
        final lon = _asDouble(incoming.payload['longitude']);
        if (lat == null || lon == null) return false;
        return candidates.any((existing) {
          if (existing.category != incoming.category) return false;
          if ((existing.timestamp - incoming.timestamp).abs() >
              _duplicateLocationWindowMs) {
            return false;
          }
          final existingLat = _asDouble(existing.payload['latitude']);
          final existingLon = _asDouble(existing.payload['longitude']);
          if (existingLat == null || existingLon == null) return false;
          return _distanceMeters(lat, lon, existingLat, existingLon) <
              _duplicateLocationDistanceMeters;
        });
      case CollectorCategories.system:
        return candidates.any((existing) {
          if (existing.category != incoming.category) return false;
          return existing.payload['batteryLevel'] ==
                  incoming.payload['batteryLevel'] &&
              existing.payload['isCharging'] == incoming.payload['isCharging'] &&
              existing.payload['networkType'] ==
                  incoming.payload['networkType'] &&
              existing.payload['ssid'] == incoming.payload['ssid'];
        });
      default:
        return false;
    }
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  double _distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;

  Future<void> _initStorage() async {
    final dir = await StoragePaths.appStorageDirectory();
    _historyFile = File('${dir.path}/$_historyFileName');
  }

  Future<void> _loadRecentFromDisk() async {
    final file = _historyFile;
    if (file == null || !await file.exists()) return;
    try {
      final lines = await file.readAsLines();
      final loaded = lines
          .where((line) => line.trim().isNotEmpty)
          .map((line) => CollectorEvent.fromJson(jsonDecode(line)))
          .toList();
      _recentEvents
        ..clear()
        ..addAll(loaded.reversed.take(_maxRecentEvents));
      _eventsChangedController.add(_recentEvents);
    } catch (e) {
      appLog('CollectorManager: load history error: $e', level: 'warning');
    }
  }

  Future<void> _appendToHistoryFile(CollectorEvent event) async {
    final file = _historyFile;
    if (file == null) return;
    _storageWriteQueue = _storageWriteQueue.then((_) async {
      await file.writeAsString(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    await _storageWriteQueue;
  }
}
