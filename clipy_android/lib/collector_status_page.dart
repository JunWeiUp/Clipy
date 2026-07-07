import 'dart:async';
import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'collector_manager.dart';
import 'models.dart';
import 'notification_health_banner.dart';
import 'notification_health_monitor.dart';
import 'sync_manager.dart';

class CollectorStatusPage extends StatefulWidget {
  const CollectorStatusPage({super.key});

  @override
  State<CollectorStatusPage> createState() => _CollectorStatusPageState();
}

class _CollectorStatusPageState extends State<CollectorStatusPage>
    with WidgetsBindingObserver {
  StreamSubscription? _devicesSubscription;
  List<DiscoveredPeer> _peers = [];
  bool _smsPermissionsGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _peers = SyncManager.instance.availablePeers;
    _devicesSubscription =
        SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) setState(() => _peers = peers);
    });
    _loadSmsPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _devicesSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSmsPermission();
    }
  }

  Future<void> _loadSmsPermission() async {
    final granted = await CollectorManager.instance.hasSmsPermissions();
    if (mounted) setState(() => _smsPermissionsGranted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final authorized = SyncManager.instance.authorizedPeerIds;
    final connectedMacs = _peers
        .where((peer) => authorized.contains(peer.peerId))
        .map((peer) => peer.displayName)
        .toList();
    final notificationHealth =
        NotificationHealthMonitor.instance.latestStatus;
    final smsCategoryEnabled =
        CollectorManager.instance.categoryEnabled[CollectorCategories.sms] ??
            true;

    return Column(
      children: [
        const NotificationHealthBanner(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.collectorServiceStatus,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _StatusRow(
                        label: l10n.collectorEnabled,
                        value: CollectorManager.instance.isEnabled
                            ? l10n.enabled
                            : l10n.disabled,
                        ok: CollectorManager.instance.isEnabled,
                      ),
                      _StatusRow(
                        label: l10n.syncEnabled,
                        value: SyncManager.instance.isEnabled
                            ? l10n.enabled
                            : l10n.disabled,
                        ok: SyncManager.instance.isEnabled,
                      ),
                      _StatusRow(
                        label: l10n.connectedMac,
                        value: connectedMacs.isEmpty
                            ? l10n.notConnected
                            : connectedMacs.join(', '),
                        ok: connectedMacs.isNotEmpty,
                      ),
                      if (notificationHealth != null &&
                          notificationHealth.needsReauthorization)
                        _StatusRow(
                          label: l10n.permissionNotificationListener,
                          value: l10n.notGranted,
                          ok: false,
                        ),
                      if (CollectorManager.instance.isEnabled &&
                          smsCategoryEnabled &&
                          !_smsPermissionsGranted)
                        _StatusRow(
                          label: l10n.permissionSms,
                          value: l10n.notGranted,
                          ok: false,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.collectorCategoryToggles,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ...CollectorCategories.all.map((category) {
                final enabled =
                    CollectorManager.instance.categoryEnabled[category] ?? true;
                return SwitchListTile(
                  title: Text(l10n.collectorCategoryLabel(category)),
                  value: enabled,
                  onChanged: (value) async {
                    await CollectorManager.instance.setCategoryEnabled(
                      category,
                      value,
                    );
                    if (mounted) setState(() {});
                  },
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final bool ok;

  const _StatusRow({
    required this.label,
    required this.value,
    required this.ok,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: ok ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('$label: $value')),
        ],
      ),
    );
  }
}
