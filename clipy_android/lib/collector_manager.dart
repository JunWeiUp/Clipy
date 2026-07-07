import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database/collector_repository.dart';
import 'log_manager.dart';
import 'models.dart';
import 'sync_manager.dart';

class CollectorManager {
  static final CollectorManager instance = CollectorManager._();
  CollectorManager._();

  static const _channel = MethodChannel('com.clipyclone.clipy_android/collector');
  static const _duplicateSmsWindowMs = 5000;

  bool isEnabled = false;
  final Map<String, bool> categoryEnabled = {
    for (final category in CollectorCategories.all) category: true,
  };

  final _eventsChangedController = StreamController<void>.broadcast();
  Stream<void> get onEventsChanged => _eventsChangedController.stream;

  Future<List<CollectorEvent>> fetchPage({
    required int offset,
    required int limit,
    String? category,
  }) {
    return CollectorRepository.instance.fetchPage(
      offset: offset,
      limit: limit,
      category: category,
    );
  }

  Future<int> count({String? category}) =>
      CollectorRepository.instance.count(category: category);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('collectorEnabled') ?? false;
    for (final category in CollectorCategories.all) {
      categoryEnabled[category] =
          prefs.getBool('collectorCategory_$category') ?? true;
    }

    _channel.setMethodCallHandler(_handleMethodCall);

    if (isEnabled) {
      await startForegroundService();
      if (await hasSmsPermissions()) {
        await reloadCollectorConfig();
      }
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
    // Clipboard uses text/plain via SyncManager — not collector/event.
    if (category == CollectorCategories.clipboard) return;
    if (categoryEnabled[category] != true) return;

    final event = CollectorEvent(
      id: id ?? '${DateTime.now().microsecondsSinceEpoch}_$category',
      category: category,
      timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
      deviceId: SyncManager.instance.deviceId,
      payload: _normalizePayload(payload),
    );

    if (await _isDuplicate(event)) return;

    await CollectorRepository.instance.insert(event);
    _eventsChangedController.add(null);

    if (SyncManager.instance.isEnabled) {
      await _broadcastEvent(event);
      await _flushPendingEvents();
    }
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
    if (Platform.isAndroid && isEnabled) {
      await reloadCollectorConfig();
    }
  }

  Future<void> reloadCollectorConfig() async {
    if (!Platform.isAndroid) return;
    if (isEnabled) {
      await startForegroundService();
    }
    try {
      await _channel.invokeMethod('reloadCollectorConfig');
    } catch (e) {
      appLog('CollectorManager: reload collector config failed: $e',
          level: 'warning');
    }
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
    await requestPermissions([permission]);
  }

  Future<void> requestPermissions(List<String> permissions) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestPermissions', {
        'permissions': permissions,
      });
    } catch (e) {
      appLog('CollectorManager: request permissions failed: $e',
          level: 'warning');
    }
  }

  static const smsPermissions = <String>[
    'android.permission.READ_SMS',
    'android.permission.RECEIVE_SMS',
  ];

  Future<void> requestSmsPermissions() async {
    await requestPermissions(smsPermissions);
  }

  Future<bool> hasSmsPermissions() async {
    for (final permission in smsPermissions) {
      if (!await checkPermission(permission)) return false;
    }
    return true;
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
    await CollectorRepository.instance.markSynced(event.id, synced: true);
  }

  Future<void> _flushPendingEvents() async {
    if (!SyncManager.instance.isEnabled) return;
    if (SyncManager.instance.authorizedPeerIds.isEmpty) return;
    final reachable = SyncManager.instance.availablePeers.where(
      (peer) => SyncManager.instance.authorizedPeerIds.contains(peer.peerId),
    );
    if (reachable.isEmpty) return;

    final pending = await CollectorRepository.instance.fetchPending(limit: 500);
    for (final event in pending) {
      if (event.category == CollectorCategories.clipboard) {
        await CollectorRepository.instance.markSynced(event.id, synced: true);
        continue;
      }
      await _broadcastEvent(event);
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

  Future<bool> _isDuplicate(CollectorEvent incoming) async {
    switch (incoming.category) {
      case CollectorCategories.sms:
        return CollectorRepository.instance.hasRecentDuplicate(
          category: incoming.category,
          sinceMs: incoming.timestamp - _duplicateSmsWindowMs,
          payloadMatch: {
            'address': incoming.payload['address'],
            'body': incoming.payload['body'],
          },
        );
      case CollectorCategories.call:
        return CollectorRepository.instance.hasRecentDuplicate(
          category: incoming.category,
          sinceMs: incoming.timestamp - 2000,
          payloadMatch: {
            'phoneNumber': incoming.payload['phoneNumber'],
            'state': incoming.payload['state'],
          },
        );
      case CollectorCategories.callLog:
        final logId = incoming.payload['logId'];
        if (logId != null && logId.toString().isNotEmpty) {
          return CollectorRepository.instance.hasPayloadMatch(
            category: incoming.category,
            payloadMatch: {'logId': logId},
          );
        }
        return CollectorRepository.instance.hasPayloadMatch(
          category: incoming.category,
          payloadMatch: {
            'phoneNumber': incoming.payload['phoneNumber'],
            'type': incoming.payload['type'],
            'date': incoming.payload['date'],
          },
        );
      case CollectorCategories.clipboard:
        final hash = incoming.payload['hash'];
        if (hash == null || hash.toString().isEmpty) return false;
        return CollectorRepository.instance.hasPayloadMatch(
          category: incoming.category,
          payloadMatch: {'hash': hash},
        );
      default:
        return false;
    }
  }
}
