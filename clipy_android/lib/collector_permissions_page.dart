import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'collector_manager.dart';
import 'notification_health_banner.dart';
import 'notification_health_monitor.dart';
import 'notification_manager.dart';

class CollectorPermissionsPage extends StatefulWidget {
  const CollectorPermissionsPage({super.key});

  @override
  State<CollectorPermissionsPage> createState() =>
      _CollectorPermissionsPageState();
}

class _CollectorPermissionsPageState extends State<CollectorPermissionsPage>
    with WidgetsBindingObserver {
  final Map<String, bool> _permissionStates = {};
  bool _awaitingSmsPermission = false;
  bool _previousSmsGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
    NotificationHealthMonitor.instance.onHealthChanged.listen((_) {
      if (mounted) _refreshPermissions();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions(showSmsDeniedHint: _awaitingSmsPermission);
    }
  }

  bool _isSmsGranted(Map<String, bool> states) {
    return (states['android.permission.READ_SMS'] ?? false) &&
        (states['android.permission.RECEIVE_SMS'] ?? false);
  }

  Future<void> _reloadCollectorIfNeeded({required bool smsGranted}) async {
    if (!CollectorManager.instance.isEnabled) return;
    if (!smsGranted) return;
    await CollectorManager.instance.reloadCollectorConfig();
  }

  Future<void> _refreshPermissions({bool showSmsDeniedHint = false}) async {
    final states = <String, bool>{
      'notification_listener':
          (await NotificationManager.instance.getListenerStatus())
              .permissionGranted,
      'android.permission.READ_SMS': await CollectorManager.instance
          .checkPermission('android.permission.READ_SMS'),
      'android.permission.RECEIVE_SMS': await CollectorManager.instance
          .checkPermission('android.permission.RECEIVE_SMS'),
      'android.permission.READ_PHONE_STATE': await CollectorManager.instance
          .checkPermission('android.permission.READ_PHONE_STATE'),
      'android.permission.READ_CALL_LOG': await CollectorManager.instance
          .checkPermission('android.permission.READ_CALL_LOG'),
      'android.permission.POST_NOTIFICATIONS': await CollectorManager.instance
          .checkPermission('android.permission.POST_NOTIFICATIONS'),
      'battery': await CollectorManager.instance.isBatteryOptimizationIgnored(),
    };
    final smsGranted = _isSmsGranted(states);
    final smsNewlyGranted = smsGranted && !_previousSmsGranted;

    if (smsNewlyGranted) {
      await _reloadCollectorIfNeeded(smsGranted: true);
    }

    if (!mounted) return;
    setState(() {
      _permissionStates.addAll(states);
      _previousSmsGranted = smsGranted;
    });

    if (showSmsDeniedHint) {
      _awaitingSmsPermission = false;
      if (smsGranted) {
        await _reloadCollectorIfNeeded(smsGranted: true);
      } else {
        final l10n = context.l10n;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.smsPermissionDeniedHint),
            action: SnackBarAction(
              label: l10n.openAppSettings,
              onPressed: () => CollectorManager.instance
                  .openPermissionSettings('app_details'),
            ),
          ),
        );
      }
    }
  }

  String? _notificationListenerSubtitle(AppStrings l10n) {
    final health = NotificationHealthMonitor.instance.latestStatus;
    if (health == null || health.isHealthy) return null;
    switch (health.issue) {
      case NotificationHealthIssue.permissionDenied:
        return l10n.notificationListenerPermissionDenied;
      case NotificationHealthIssue.listenerNotConnected:
        return l10n.notificationListenerNotConnected;
      case NotificationHealthIssue.notReceiving:
        return l10n.notificationListenerNotReceiving;
      case NotificationHealthIssue.none:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        const NotificationHealthBanner(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
        Text(l10n.collectorPermissionsIntro),
        const SizedBox(height: 16),
        _PermissionTile(
          title: l10n.permissionNotificationListener,
          granted: _permissionStates['notification_listener'] ?? false,
          subtitle: _notificationListenerSubtitle(l10n),
          onRequest: () async {
            await CollectorManager.instance
                .openPermissionSettings('notification_listener');
            await NotificationHealthMonitor.instance.checkHealth();
            await _refreshPermissions();
          },
        ),
        _PermissionTile(
          title: l10n.permissionSms,
          granted: (_permissionStates['android.permission.READ_SMS'] ?? false) &&
              (_permissionStates['android.permission.RECEIVE_SMS'] ?? false),
          onRequest: () async {
            _awaitingSmsPermission = true;
            await CollectorManager.instance.requestSmsPermissions();
          },
        ),
        _PermissionTile(
          title: l10n.permissionPhone,
          granted:
              _permissionStates['android.permission.READ_PHONE_STATE'] ?? false,
          onRequest: () async {
            await CollectorManager.instance
                .requestPermission('android.permission.READ_PHONE_STATE');
            await _refreshPermissions();
          },
        ),
        _PermissionTile(
          title: l10n.permissionCallLog,
          granted:
              _permissionStates['android.permission.READ_CALL_LOG'] ?? false,
          onRequest: () async {
            await CollectorManager.instance
                .requestPermission('android.permission.READ_CALL_LOG');
            await _refreshPermissions();
          },
        ),
        _PermissionTile(
          title: l10n.permissionPostNotifications,
          granted:
              _permissionStates['android.permission.POST_NOTIFICATIONS'] ?? true,
          onRequest: () async {
            await CollectorManager.instance
                .requestPermission('android.permission.POST_NOTIFICATIONS');
            await _refreshPermissions();
          },
        ),
        _PermissionTile(
          title: l10n.permissionBatteryOptimization,
          granted: _permissionStates['battery'] ?? false,
          onRequest: () async {
            await CollectorManager.instance.requestIgnoreBatteryOptimization();
            await _refreshPermissions();
          },
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () async {
            await CollectorManager.instance.reloadCollectorConfig();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.collectorServiceStarted)),
              );
            }
          },
          icon: const Icon(Icons.play_arrow),
          label: Text(l10n.startCollectorService),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _refreshPermissions,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.refreshPermissions),
        ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final String title;
  final bool granted;
  final String? subtitle;
  final VoidCallback onRequest;

  const _PermissionTile({
    required this.title,
    required this.granted,
    this.subtitle,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: ListTile(
        leading: Icon(
          granted ? Icons.verified : Icons.warning_amber_outlined,
          color: granted ? Colors.green : Colors.orange,
        ),
        title: Text(title),
        subtitle: Text(
          subtitle ?? (granted ? l10n.granted : l10n.notGranted),
        ),
        trailing: granted
            ? null
            : TextButton(onPressed: onRequest, child: Text(l10n.grant)),
      ),
    );
  }
}
