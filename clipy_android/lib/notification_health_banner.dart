import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'notification_health_monitor.dart';
import 'notification_manager.dart';

class NotificationHealthBanner extends StatefulWidget {
  const NotificationHealthBanner({super.key});

  @override
  State<NotificationHealthBanner> createState() =>
      _NotificationHealthBannerState();
}

class _NotificationHealthBannerState extends State<NotificationHealthBanner> {
  NotificationHealthStatus? _status;

  @override
  void initState() {
    super.initState();
    _status = NotificationHealthMonitor.instance.latestStatus;
    NotificationHealthMonitor.instance.onHealthChanged.listen((status) {
      if (mounted) setState(() => _status = status);
    });
    Future<void>.microtask(() async {
      final status = await NotificationHealthMonitor.instance.checkHealth();
      if (mounted) setState(() => _status = status);
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null || status.isHealthy) {
      return const SizedBox.shrink();
    }

    final l10n = context.l10n;
    final message = _messageForIssue(l10n, status.issue);
    final actionLabel = l10n.reauthorizeNotificationListener;

    return Material(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.notifications_off_outlined, color: Colors.orange.shade800),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.notificationListenerIssueTitle,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(color: Colors.orange.shade900),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => _handleReauthorize(context),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }

  String _messageForIssue(AppStrings l10n, NotificationHealthIssue issue) {
    switch (issue) {
      case NotificationHealthIssue.permissionDenied:
        return l10n.notificationListenerPermissionDenied;
      case NotificationHealthIssue.listenerNotConnected:
        return l10n.notificationListenerNotConnected;
      case NotificationHealthIssue.notReceiving:
        return l10n.notificationListenerNotReceiving;
      case NotificationHealthIssue.none:
        return '';
    }
  }

  Future<void> _handleReauthorize(BuildContext context) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await NotificationManager.instance.requestListenerRebind();
    await NotificationManager.instance.openListenerSettings();
    await Future<void>.delayed(const Duration(seconds: 1));
    final status = await NotificationHealthMonitor.instance.checkHealth();
    if (!context.mounted) return;
    setState(() => _status = status);
    if (status.isHealthy) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.notificationListenerRecovered)),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.notificationListenerStillUnavailable)),
      );
    }
  }
}
