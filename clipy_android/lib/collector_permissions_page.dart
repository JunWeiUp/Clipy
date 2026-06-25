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

class _CollectorPermissionsPageState extends State<CollectorPermissionsPage> {
  final Map<String, bool> _permissionStates = {};

  @override
  void initState() {
    super.initState();
    _refreshPermissions();
    NotificationHealthMonitor.instance.onHealthChanged.listen((_) {
      if (mounted) _refreshPermissions();
    });
  }

  Future<void> _refreshPermissions() async {
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
      'android.permission.ACCESS_FINE_LOCATION': await CollectorManager.instance
          .checkPermission('android.permission.ACCESS_FINE_LOCATION'),
      'android.permission.POST_NOTIFICATIONS': await CollectorManager.instance
          .checkPermission('android.permission.POST_NOTIFICATIONS'),
      'battery': await CollectorManager.instance.isBatteryOptimizationIgnored(),
    };
    if (mounted) setState(() => _permissionStates.addAll(states));
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
            await CollectorManager.instance
                .requestPermission('android.permission.READ_SMS');
            await CollectorManager.instance
                .requestPermission('android.permission.RECEIVE_SMS');
            await _refreshPermissions();
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
          title: l10n.permissionLocation,
          granted: _permissionStates['android.permission.ACCESS_FINE_LOCATION'] ??
              false,
          onRequest: () async {
            await CollectorManager.instance
                .requestPermission('android.permission.ACCESS_FINE_LOCATION');
            await CollectorManager.instance.openPermissionSettings('location');
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
            await CollectorManager.instance.startForegroundService();
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
