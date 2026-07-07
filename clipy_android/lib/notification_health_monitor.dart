import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'collector_manager.dart';
import 'log_manager.dart';
import 'models.dart';
import 'notification_manager.dart';

enum NotificationHealthIssue {
  none,
  permissionDenied,
  listenerNotConnected,
  notReceiving,
}

class NotificationHealthStatus {
  final NotificationHealthIssue issue;
  final NotificationListenerStatus listenerStatus;
  final DateTime? lastNotificationAt;
  final DateTime checkedAt;

  const NotificationHealthStatus({
    required this.issue,
    required this.listenerStatus,
    required this.lastNotificationAt,
    required this.checkedAt,
  });

  bool get isHealthy => issue == NotificationHealthIssue.none;

  bool get needsReauthorization =>
      issue == NotificationHealthIssue.permissionDenied ||
      issue == NotificationHealthIssue.listenerNotConnected ||
      issue == NotificationHealthIssue.notReceiving;
}

class NotificationHealthMonitor with WidgetsBindingObserver {
  NotificationHealthMonitor._();
  static final NotificationHealthMonitor instance = NotificationHealthMonitor._();

  static const _foregroundInterval = Duration(seconds: 45);
  static const _backgroundInterval = Duration(minutes: 5);
  static const _notReceivingGracePeriod = Duration(minutes: 3);
  static const _notReceivingStalePeriod = Duration(minutes: 15);

  Timer? _timer;
  NotificationHealthStatus? _latestStatus;
  bool _observingLifecycle = false;
  bool _inBackground = false;

  final _healthChangedController =
      StreamController<NotificationHealthStatus>.broadcast();
  Stream<NotificationHealthStatus> get onHealthChanged =>
      _healthChangedController.stream;
  NotificationHealthStatus? get latestStatus => _latestStatus;

  Future<void> startIfNeeded() async {
    if (!Platform.isAndroid) return;

    final notificationManager = NotificationManager.instance;
    if (!notificationManager.isEnabled) {
      stop();
      return;
    }

    final status = await notificationManager.getListenerStatus();
    if (!status.permissionGranted) {
      stop();
      return;
    }

    start();
  }

  void start() {
    if (!Platform.isAndroid) return;
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    _restartTimer();
    unawaited(checkHealth());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    final interval =
        _inBackground ? _backgroundInterval : _foregroundInterval;
    _timer = Timer.periodic(interval, (_) {
      unawaited(checkHealth());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inBackground = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive;

    if (state == AppLifecycleState.resumed) {
      unawaited(checkHealth());
    }

    if (_timer != null) {
      _restartTimer();
    }
  }

  Future<NotificationHealthStatus> checkHealth() async {
    if (!Platform.isAndroid) {
      return _publish(_healthyStatus(const NotificationListenerStatus(
        permissionGranted: true,
        serviceConnected: true,
        activeNotificationCount: 0,
      )));
    }

    final notificationManager = NotificationManager.instance;
    final notificationCollectionEnabled =
        notificationManager.isEnabled &&
            (CollectorManager.instance.categoryEnabled[
                    CollectorCategories.notification] ??
                true);
    if (!notificationCollectionEnabled) {
      return _publish(_healthyStatus(const NotificationListenerStatus(
        permissionGranted: true,
        serviceConnected: true,
        activeNotificationCount: 0,
      )));
    }

    var status = await notificationManager.getListenerStatus();
    if (status.permissionGranted && !status.serviceConnected) {
      await notificationManager.requestListenerRebind();
      await Future<void>.delayed(const Duration(seconds: 2));
      status = await notificationManager.getListenerStatus();
      if (status.permissionGranted && !status.serviceConnected) {
        await notificationManager.refreshActiveNotifications();
        await Future<void>.delayed(const Duration(seconds: 1));
        status = await notificationManager.getListenerStatus();
      }
    }

    final issue = _resolveIssue(
      status: status,
      lastNotificationAt: notificationManager.lastNotificationReceivedAt,
      monitoringStartedAt: notificationManager.monitoringStartedAt,
    );

    return _publish(
      NotificationHealthStatus(
        issue: issue,
        listenerStatus: status,
        lastNotificationAt: notificationManager.lastNotificationReceivedAt,
        checkedAt: DateTime.now(),
      ),
    );
  }

  NotificationHealthIssue _resolveIssue({
    required NotificationListenerStatus status,
    required DateTime? lastNotificationAt,
    required DateTime? monitoringStartedAt,
  }) {
    if (!status.permissionGranted) {
      return NotificationHealthIssue.permissionDenied;
    }
    if (!status.serviceConnected) {
      return NotificationHealthIssue.listenerNotConnected;
    }

    final now = DateTime.now();
    if (status.activeNotificationCount > 0) {
      if (lastNotificationAt == null) {
        final startedAt = monitoringStartedAt;
        if (startedAt != null &&
            now.difference(startedAt) >= _notReceivingGracePeriod) {
          return NotificationHealthIssue.notReceiving;
        }
      } else if (now.difference(lastNotificationAt) >=
          _notReceivingStalePeriod) {
        return NotificationHealthIssue.notReceiving;
      }
    }

    return NotificationHealthIssue.none;
  }

  NotificationHealthStatus _healthyStatus(NotificationListenerStatus status) {
    return NotificationHealthStatus(
      issue: NotificationHealthIssue.none,
      listenerStatus: status,
      lastNotificationAt: NotificationManager.instance.lastNotificationReceivedAt,
      checkedAt: DateTime.now(),
    );
  }

  NotificationHealthStatus _publish(NotificationHealthStatus status) {
    final previousIssue = _latestStatus?.issue;
    _latestStatus = status;
    if (previousIssue != status.issue || _healthChangedController.hasListener) {
      _healthChangedController.add(status);
    }
    if (!status.isHealthy) {
      appLog(
        'NotificationHealthMonitor: issue=${status.issue.name}, '
        'permission=${status.listenerStatus.permissionGranted}, '
        'connected=${status.listenerStatus.serviceConnected}, '
        'active=${status.listenerStatus.activeNotificationCount}',
        level: 'warning',
      );
    }
    return status;
  }
}
