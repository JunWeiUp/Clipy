import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'log_manager.dart';
import 'models.dart';
import 'notification_manager.dart';

enum NotificationHealthIssue {
  none,
  permissionDenied,
  listenerNotConnected,
  batteryOptimization,
  notReceiving,
}

class NotificationHealthStatus {
  final NotificationHealthIssue issue;
  final NotificationListenerStatus listenerStatus;
  final bool batteryOptimizationExempt;
  final DateTime? lastNotificationAt;
  final DateTime checkedAt;

  const NotificationHealthStatus({
    required this.issue,
    required this.listenerStatus,
    required this.batteryOptimizationExempt,
    required this.lastNotificationAt,
    required this.checkedAt,
  });

  bool get isHealthy => issue == NotificationHealthIssue.none;

  bool get needsReauthorization =>
      issue == NotificationHealthIssue.permissionDenied ||
      issue == NotificationHealthIssue.listenerNotConnected ||
      issue == NotificationHealthIssue.batteryOptimization ||
      issue == NotificationHealthIssue.notReceiving;
}

class NotificationHealthMonitor with WidgetsBindingObserver {
  NotificationHealthMonitor._();
  static final NotificationHealthMonitor instance =
      NotificationHealthMonitor._();

  static const _foregroundInterval = Duration(seconds: 45);
  static const _notReceivingGracePeriod = Duration(minutes: 3);
  static const _notReceivingStalePeriod = Duration(minutes: 15);

  Timer? _timer;
  NotificationHealthStatus? _latestStatus;
  bool _observingLifecycle = false;

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
    _timer = Timer.periodic(_foregroundInterval, (_) {
      unawaited(checkHealth());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background state is expressed by whether `_timer` is running, so there is
    // no separate flag to keep in sync.
    if (state == AppLifecycleState.resumed) {
      unawaited(checkHealth());
      // Resume periodic checks (foreground interval).
      _restartTimer();
    } else if (_timer != null) {
      // Foreground-only (per sync power plan v2): stop periodic health checks
      // while backgrounded — there's no UI to surface issues and the 5min
      // wake burned battery. Health is re-checked on the next resume/page open.
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<NotificationHealthStatus> checkHealth() async {
    if (!Platform.isAndroid) {
      return _publish(
        _healthyStatus(
          const NotificationListenerStatus(
            permissionGranted: true,
            serviceConnected: true,
            activeNotificationCount: 0,
          ),
        ),
      );
    }

    final notificationManager = NotificationManager.instance;
    if (!notificationManager.isEnabled) {
      return _publish(
        _healthyStatus(
          const NotificationListenerStatus(
            permissionGranted: true,
            serviceConnected: true,
            activeNotificationCount: 0,
          ),
        ),
      );
    }

    var status = await notificationManager.getListenerStatus();
    if (status.permissionGranted && !status.serviceConnected) {
      // Soft rebind first (often ignored on Xiaomi).
      appLog(
        'NotificationHealthMonitor: listener disconnected; trying soft rebind',
        level: 'warning',
      );
      await notificationManager.requestListenerRebind(force: false);
      await Future<void>.delayed(const Duration(seconds: 2));
      status = await notificationManager.getListenerStatus();

      // Xiaomi/MIUI/HyperOS: escalate to component disable/enable force reconnect.
      if (!status.serviceConnected) {
        appLog(
          'NotificationHealthMonitor: soft rebind failed on OEM; forcing component reconnect',
          level: 'warning',
        );
        await notificationManager.requestListenerRebind(force: true);
        await Future<void>.delayed(const Duration(seconds: 3));
        status = await notificationManager.getListenerStatus();
        if (!status.serviceConnected) {
          appLog(
            'NotificationHealthMonitor: force reconnect still failed — '
            'user must toggle 通知使用权 OFF/ON (common on Xiaomi)',
            level: 'warning',
          );
        } else {
          appLog('NotificationHealthMonitor: force reconnect succeeded');
        }
      } else {
        appLog('NotificationHealthMonitor: soft rebind succeeded');
      }
    }

    // 检测电池优化白名单——多数国产 ROM 会因省电杀掉后台监听服务
    final batteryOptimizationExempt = await notificationManager
        .isBatteryOptimizationExempt();
    if (!batteryOptimizationExempt) {
      appLog(
        'NotificationHealthMonitor: battery optimization NOT exempt, '
        'listener may be killed by OEM ROM',
        level: 'warning',
      );
    }

    final issue = _resolveIssue(
      status: status,
      batteryOptimizationExempt: batteryOptimizationExempt,
      lastNotificationAt: notificationManager.lastNotificationReceivedAt,
      monitoringStartedAt: notificationManager.monitoringStartedAt,
    );

    return _publish(
      NotificationHealthStatus(
        issue: issue,
        listenerStatus: status,
        batteryOptimizationExempt: batteryOptimizationExempt,
        lastNotificationAt: notificationManager.lastNotificationReceivedAt,
        checkedAt: DateTime.now(),
      ),
    );
  }

  NotificationHealthIssue _resolveIssue({
    required NotificationListenerStatus status,
    required bool batteryOptimizationExempt,
    required DateTime? lastNotificationAt,
    required DateTime? monitoringStartedAt,
  }) {
    if (!status.permissionGranted) {
      return NotificationHealthIssue.permissionDenied;
    }
    if (!status.serviceConnected) {
      return NotificationHealthIssue.listenerNotConnected;
    }
    if (!batteryOptimizationExempt) {
      return NotificationHealthIssue.batteryOptimization;
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
      batteryOptimizationExempt: true,
      lastNotificationAt:
          NotificationManager.instance.lastNotificationReceivedAt,
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
        'batteryExempt=${status.batteryOptimizationExempt}, '
        'active=${status.listenerStatus.activeNotificationCount}',
        level: 'warning',
      );
    }
    return status;
  }
}
