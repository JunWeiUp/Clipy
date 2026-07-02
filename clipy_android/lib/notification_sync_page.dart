import 'dart:async';
import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'clipboard_manager.dart';
import 'models.dart';
import 'notification_manager.dart';

class NotificationSyncPage extends StatefulWidget {
  const NotificationSyncPage({super.key});

  @override
  State<NotificationSyncPage> createState() => _NotificationSyncPageState();
}

class _NotificationSyncPageState extends State<NotificationSyncPage>
    with SingleTickerProviderStateMixin {
  static const _historyTabIndex = 1;

  late TabController _tabController;
  bool _permissionGranted = false;
  List<Map<String, dynamic>> _installedApps = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;
  StreamSubscription? _notifSubscription;
  StreamSubscription? _allowedPackagesSubscription;
  final Set<String> _expandedApps = {};
  List<_HistoryListItem> _historyItems = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChanged);
    _loadPermissionStatus();
    _loadInstalledApps();
    _rebuildHistoryItems();
    _notifSubscription =
        NotificationManager.instance.onNotificationsChanged.listen((_) {
      if (!mounted) return;
      _rebuildHistoryItems();
      if (_tabController.index == _historyTabIndex) {
        setState(() {});
      }
    });
    _allowedPackagesSubscription =
        NotificationManager.instance.onAllowedPackagesChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _notifSubscription?.cancel();
    _allowedPackagesSubscription?.cancel();
    super.dispose();
  }

  Future<void> _setPackageSyncEnabled(String packageName, bool enabled) async {
    await NotificationManager.instance.setPackageSyncEnabled(
      packageName,
      enabled,
    );
    if (mounted) setState(() {});
  }

  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == _historyTabIndex) {
      setState(() {});
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _searchQuery = value.trim().toLowerCase());
    });
  }

  List<Map<String, dynamic>> get _filteredApps {
    if (_searchQuery.isEmpty) return _installedApps;
    return _installedApps.where((app) {
      final name = (app['appName'] as String).toLowerCase();
      final pkg = (app['packageName'] as String).toLowerCase();
      return name.contains(_searchQuery) || pkg.contains(_searchQuery);
    }).toList();
  }

  List<_AppListItem> _buildFlatAppItems(List<Map<String, dynamic>> apps) {
    final l10n = context.l10n;
    final userApps = apps.where((a) => a['isSystem'] != true).toList();
    final sysApps = apps.where((a) => a['isSystem'] == true).toList();
    final items = <_AppListItem>[];
    if (userApps.isNotEmpty) {
      items.add(_AppListItem.header(l10n.userApps, userApps.length));
      for (final app in userApps) {
        items.add(_AppListItem.app(app));
      }
    }
    if (sysApps.isNotEmpty) {
      items.add(_AppListItem.header(l10n.systemApps, sysApps.length));
      for (final app in sysApps) {
        items.add(_AppListItem.app(app));
      }
    }
    return items;
  }

  void _rebuildHistoryItems() {
    final notifications = NotificationManager.instance.activeNotifications;
    if (notifications.isEmpty) {
      _historyItems = const [];
      return;
    }

    final grouped = <String, List<NotificationEntry>>{};
    for (final notification in notifications) {
      grouped.putIfAbsent(notification.packageName, () => []).add(notification);
    }
    for (final items in grouped.values) {
      items.sort((a, b) => b.postTime.compareTo(a.postTime));
    }
    final order = grouped.keys.toList()
      ..sort((a, b) =>
          grouped[b]!.first.postTime.compareTo(grouped[a]!.first.postTime));

    final rows = <_HistoryListItem>[
      _HistoryListItem.summary(
        notificationCount: notifications.length,
        appCount: order.length,
      ),
    ];

    for (final packageName in order) {
      final items = grouped[packageName]!;
      final first = items.first;
      final isExpanded = _expandedApps.contains(packageName);
      rows.add(
        _HistoryListItem.groupHeader(
          appName: first.appName,
          packageName: packageName,
          count: items.length,
          isExpanded: isExpanded,
          latestPostTime: first.postTime,
          notifications: items,
        ),
      );
      if (isExpanded) {
        for (final entry in items) {
          rows.add(_HistoryListItem.notification(entry));
        }
      }
    }

    _historyItems = rows;
  }

  Future<void> _loadPermissionStatus() async {
    final granted =
        await NotificationManager.instance.isListenerPermissionGranted();
    if (mounted) setState(() => _permissionGranted = granted);
  }

  Future<void> _loadInstalledApps() async {
    final apps = await NotificationManager.instance.getInstalledApps();
    if (mounted) setState(() => _installedApps = apps);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.notificationSync),
        actions: [
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'open_permission',
                child: Text(l10n.notificationListenerPermission),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'clear_all',
                child: Text(l10n.clearNotificationHistory),
              ),
              PopupMenuItem(
                value: 'clear_on_phone',
                child: Text(l10n.clearAllNotifications),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(icon: const Icon(Icons.tune), text: l10n.settings),
            Tab(
                icon: const Icon(Icons.notifications),
                text: l10n.notificationHistory),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSettingsTab(),
          _buildHistoryTab(),
        ],
      ),
    );
  }

  // MARK: - Settings Tab

  Widget _buildSettingsTab() {
    final l10n = context.l10n;
    final manager = NotificationManager.instance;
    final appItems = _buildFlatAppItems(_filteredApps);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildPermissionCard(l10n)),
        SliverToBoxAdapter(child: const Divider(height: 1)),
        SliverToBoxAdapter(
          child: SwitchListTile(
            title: Text(l10n.enableNotificationSync),
            subtitle: Text(
              _permissionGranted
                  ? (manager.isEnabled
                      ? l10n.permissionGranted
                      : l10n.permissionNotGranted)
                  : l10n.notificationPermissionRequired,
            ),
            value: manager.isEnabled && _permissionGranted,
            onChanged: _permissionGranted
                ? (value) async {
                    await manager.setEnabled(value);
                    if (mounted) setState(() {});
                  }
                : null,
            secondary: Icon(
              manager.isEnabled && _permissionGranted
                  ? Icons.sync
                  : Icons.sync_disabled,
              color: manager.isEnabled && _permissionGranted
                  ? Colors.green
                  : Colors.grey,
            ),
          ),
        ),
        SliverToBoxAdapter(child: const Divider(height: 1)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.filter_list,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.syncNotificationsFrom,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${manager.allowedPackages.length} / ${_installedApps.length}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.searchApps,
                prefixIcon: const Icon(Icons.search, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                isDense: true,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.select_all, size: 18),
                  onPressed: () async {
                    final allPkgs = _installedApps
                        .map((app) => app['packageName'] as String)
                        .toList();
                    await manager.updateAllowedPackages(allPkgs);
                    if (mounted) setState(() {});
                  },
                  label: Text(l10n.selectAll),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.deselect, size: 18),
                  onPressed: () async {
                    await manager.updateAllowedPackages([]);
                    if (mounted) setState(() {});
                  },
                  label: Text(l10n.deselectAll),
                ),
              ],
            ),
          ),
        ),
        if (appItems.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  l10n.noAppsAvailable,
                  style: TextStyle(color: Colors.grey[500]),
                ),
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = appItems[index];
                if (item.isHeader) {
                  return _buildSectionHeader(item.title!, item.count!);
                }
                return _buildAppTile(item.app!, manager);
              },
              childCount: appItems.length,
            ),
          ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(fontSize: 11, color: Colors.grey[700]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppTile(Map<String, dynamic> app, NotificationManager manager) {
    final packageName = app['packageName'] as String;
    final appName = app['appName'] as String;
    final isAllowed = manager.isPackageSyncEnabled(packageName);
    return CheckboxListTile(
      title: Text(appName, style: const TextStyle(fontSize: 14)),
      subtitle: Text(packageName,
          style: TextStyle(fontSize: 11, color: Colors.grey[500])),
      value: isAllowed,
      onChanged: (value) async {
        await manager.setPackageSyncEnabled(packageName, value ?? false);
        if (mounted) setState(() {});
      },
    );
  }

  Widget _buildPermissionCard(AppStrings l10n) {
    return Card(
      margin: const EdgeInsets.all(12),
      color: _permissionGranted ? Colors.green[50] : Colors.orange[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _permissionGranted ? Icons.check_circle : Icons.warning_amber,
              color: _permissionGranted ? Colors.green : Colors.orange,
              size: 36,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _permissionGranted
                        ? l10n.permissionGranted
                        : l10n.notificationListenerPermission,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _permissionGranted
                        ? l10n.enableNotificationSync
                        : l10n.permissionGuide,
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
            ),
            if (!_permissionGranted)
              ElevatedButton(
                onPressed: () {
                  NotificationManager.instance.openListenerSettings();
                },
                child: Text(l10n.grantPermission),
              ),
          ],
        ),
      ),
    );
  }

  // MARK: - History Tab

  Widget _buildHistoryTab() {
    final l10n = context.l10n;

    if (_historyItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              l10n.noNotificationHistory,
              style: TextStyle(color: Colors.grey[500], fontSize: 16),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _historyItems.length,
      itemBuilder: (context, index) {
        final item = _historyItems[index];
        switch (item.kind) {
          case _HistoryListItemKind.summary:
            return _buildHistorySummary(l10n, item);
          case _HistoryListItemKind.groupHeader:
            final syncEnabled = NotificationManager.instance
                .isPackageSyncEnabled(item.packageName!);
            return _AppGroupHeader(
              appName: item.appName!,
              packageName: item.packageName!,
              count: item.count!,
              isExpanded: item.isExpanded!,
              latestPostTime: item.latestPostTime!,
              syncEnabled: syncEnabled,
              onToggleSync: (enabled) =>
                  _setPackageSyncEnabled(item.packageName!, enabled),
              onTap: () {
                setState(() {
                  if (item.isExpanded!) {
                    _expandedApps.remove(item.packageName);
                  } else {
                    _expandedApps.add(item.packageName!);
                  }
                  _rebuildHistoryItems();
                });
              },
              onDismissAll: () {
                for (final notification in item.notifications!) {
                  NotificationManager.instance.broadcastDismissToRemote(
                    NotificationDismissRequest(
                      packageName: notification.packageName,
                      groupKey: notification.groupKey,
                      notificationKey: notification.notificationKey,
                    ),
                  );
                  NotificationManager.instance
                      .removeNotification(notification.id);
                }
              },
              onDeleteAll: () {
                for (final notification in item.notifications!) {
                  NotificationManager.instance
                      .removeNotification(notification.id);
                }
              },
              onCopyAll: () {
                final text = item.notifications!
                    .map(_notificationDetailText)
                    .join('\n\n');
                ClipboardManager.instance.copyToClipboard(
                  HistoryItem(type: 'text', value: text),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.copiedToClipboard)),
                );
              },
            );
          case _HistoryListItemKind.notification:
            final entry = item.entry!;
            final syncEnabled =
                NotificationManager.instance.isPackageSyncEnabled(
              entry.packageName,
            );
            return _NotificationTile(
              entry: entry,
              syncEnabled: syncEnabled,
              onToggleSync: (enabled) =>
                  _setPackageSyncEnabled(entry.packageName, enabled),
              onDismiss: () =>
                  NotificationManager.instance.removeNotification(entry.id),
              onDismissOnPhone: () {
                NotificationManager.instance.broadcastDismissToRemote(
                  NotificationDismissRequest(
                    packageName: entry.packageName,
                    groupKey: entry.groupKey,
                    notificationKey: entry.notificationKey,
                  ),
                );
                NotificationManager.instance.removeNotification(entry.id);
              },
              onCopy: () {
                ClipboardManager.instance.copyToClipboard(
                  HistoryItem(type: 'text', value: _notificationDetailText(entry)),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.copiedToClipboard)),
                );
              },
              onOpen: () => NotificationManager.instance.openNotification(entry),
              onShowDetails: () => _showNotificationDetails(entry),
            );
        }
      },
    );
  }

  Widget _buildHistorySummary(AppStrings l10n, _HistoryListItem item) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(Icons.notifications_active,
              size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            l10n.notificationsCount(item.notificationCount!),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${item.appCount}',
              style: TextStyle(fontSize: 11, color: Colors.grey[700]),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _confirmClearHistory(l10n),
            icon: const Icon(Icons.delete_sweep, size: 16),
            label: Text(l10n.clearAll),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  String _notificationDetailText(NotificationEntry entry) {
    final lines = <String>[
      'App: ${entry.appName}',
      'Package: ${entry.packageName}',
      'Title: ${entry.title}',
      if ((entry.subtitle ?? '').isNotEmpty) 'Subtitle: ${entry.subtitle}',
      if (entry.body.isNotEmpty) 'Body: ${entry.body}',
      'Time: ${DateTime.fromMillisecondsSinceEpoch(entry.postTime)}',
      if ((entry.notificationKey ?? '').isNotEmpty)
        'Key: ${entry.notificationKey}',
      if ((entry.groupKey ?? '').isNotEmpty) 'Group: ${entry.groupKey}',
    ];

    if (entry.extras.isNotEmpty) {
      lines.add('');
      lines.add('Extras:');
      final keys = entry.extras.keys.toList()..sort();
      for (final key in keys) {
        final value = entry.extras[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) {
          lines.add('$key: $value');
        }
      }
    }

    return lines.join('\n');
  }

  void _showNotificationDetails(NotificationEntry entry) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.appName,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                entry.packageName,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: SelectableText(_notificationDetailText(entry)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      NotificationManager.instance.openNotification(entry);
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      ClipboardManager.instance.copyToClipboard(
                        HistoryItem(
                            type: 'text',
                            value: _notificationDetailText(entry)),
                      );
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.l10n.copiedToClipboard)),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(context.l10n.copyContent),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmClearHistory(AppStrings l10n) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.clearNotificationHistory),
        content: Text(l10n.clearNotificationHistoryConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          TextButton(
            onPressed: () {
              NotificationManager.instance.clearAllLocal();
              Navigator.pop(ctx);
            },
            child: Text(l10n.clearAll),
          ),
        ],
      ),
    );
  }

  void _handleMenuAction(String action) {
    final l10n = context.l10n;
    switch (action) {
      case 'open_permission':
        NotificationManager.instance.openListenerSettings();
        unawaited(Future<void>.delayed(
            const Duration(seconds: 1), _loadPermissionStatus));
        break;
      case 'clear_all':
        _confirmClearHistory(l10n);
        break;
      case 'clear_on_phone':
        NotificationManager.instance.broadcastClearAllToRemote();
        break;
    }
  }
}

enum _HistoryListItemKind { summary, groupHeader, notification }

class _HistoryListItem {
  final _HistoryListItemKind kind;
  final int? notificationCount;
  final int? appCount;
  final String? appName;
  final String? packageName;
  final int? count;
  final bool? isExpanded;
  final int? latestPostTime;
  final List<NotificationEntry>? notifications;
  final NotificationEntry? entry;

  const _HistoryListItem._({
    required this.kind,
    this.notificationCount,
    this.appCount,
    this.appName,
    this.packageName,
    this.count,
    this.isExpanded,
    this.latestPostTime,
    this.notifications,
    this.entry,
  });

  factory _HistoryListItem.summary({
    required int notificationCount,
    required int appCount,
  }) {
    return _HistoryListItem._(
      kind: _HistoryListItemKind.summary,
      notificationCount: notificationCount,
      appCount: appCount,
    );
  }

  factory _HistoryListItem.groupHeader({
    required String appName,
    required String packageName,
    required int count,
    required bool isExpanded,
    required int latestPostTime,
    required List<NotificationEntry> notifications,
  }) {
    return _HistoryListItem._(
      kind: _HistoryListItemKind.groupHeader,
      appName: appName,
      packageName: packageName,
      count: count,
      isExpanded: isExpanded,
      latestPostTime: latestPostTime,
      notifications: notifications,
    );
  }

  factory _HistoryListItem.notification(NotificationEntry entry) {
    return _HistoryListItem._(
      kind: _HistoryListItemKind.notification,
      entry: entry,
    );
  }
}

class _AppListItem {
  final bool isHeader;
  final String? title;
  final int? count;
  final Map<String, dynamic>? app;

  const _AppListItem._({
    required this.isHeader,
    this.title,
    this.count,
    this.app,
  });

  factory _AppListItem.header(String title, int count) {
    return _AppListItem._(isHeader: true, title: title, count: count);
  }

  factory _AppListItem.app(Map<String, dynamic> app) {
    return _AppListItem._(isHeader: false, app: app);
  }
}

class _NotificationTile extends StatelessWidget {
  final NotificationEntry entry;
  final bool syncEnabled;
  final ValueChanged<bool> onToggleSync;
  final VoidCallback onDismiss;
  final VoidCallback onDismissOnPhone;
  final VoidCallback onCopy;
  final VoidCallback onOpen;
  final VoidCallback onShowDetails;

  const _NotificationTile({
    required this.entry,
    required this.syncEnabled,
    required this.onToggleSync,
    required this.onDismiss,
    required this.onDismissOnPhone,
    required this.onCopy,
    required this.onOpen,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = DateTime.fromMillisecondsSinceEpoch(entry.postTime);
    final timeDisplay =
        '${timeStr.hour.toString().padLeft(2, '0')}:${timeStr.minute.toString().padLeft(2, '0')}';
    final title = entry.title.trim().isNotEmpty
        ? entry.title.trim()
        : (entry.body.trim().isNotEmpty ? entry.body.trim() : entry.appName);
    final body = entry.body.trim();

    return Opacity(
      opacity: syncEnabled ? 1 : 0.55,
      child: Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => onDismiss(),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          radius: 20,
          child: Text(
            entry.appName.isNotEmpty ? entry.appName[0] : '?',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (body.isNotEmpty && body != title)
              Text(
                body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
            const SizedBox(height: 2),
            Text(
              '${entry.appName} · $timeDisplay · ${syncEnabled ? context.l10n.appSyncEnabled : context.l10n.appSyncDisabled}',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],
        ),
        isThreeLine: body.isNotEmpty && body != title,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: syncEnabled,
              onChanged: onToggleSync,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, size: 18, color: Colors.grey[600]),
          onSelected: (v) {
            switch (v) {
              case 'copy':
                onCopy();
                break;
              case 'toggle_sync':
                onToggleSync(!syncEnabled);
                break;
              case 'dismiss_phone':
                onDismissOnPhone();
                break;
              case 'dismiss_local':
                onDismiss();
                break;
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'copy', child: Text(context.l10n.copyContent)),
            PopupMenuItem(
              value: 'toggle_sync',
              child: Text(syncEnabled
                  ? context.l10n.stopSyncingThisApp
                  : context.l10n.syncThisApp),
            ),
            if (entry.isClearable)
              PopupMenuItem(
                  value: 'dismiss_phone',
                  child: Text(context.l10n.dismissOnPhone)),
            PopupMenuItem(
                value: 'dismiss_local', child: Text(context.l10n.delete)),
          ],
        ),
          ],
        ),
        onTap: onOpen,
        onLongPress: onShowDetails,
      ),
    ),
    );
  }
}

class _AppGroupHeader extends StatelessWidget {
  final String appName;
  final String packageName;
  final int count;
  final bool isExpanded;
  final int latestPostTime;
  final bool syncEnabled;
  final ValueChanged<bool> onToggleSync;
  final VoidCallback onTap;
  final VoidCallback onDismissAll;
  final VoidCallback onDeleteAll;
  final VoidCallback onCopyAll;

  const _AppGroupHeader({
    required this.appName,
    required this.packageName,
    required this.count,
    required this.isExpanded,
    required this.latestPostTime,
    required this.syncEnabled,
    required this.onToggleSync,
    required this.onTap,
    required this.onDismissAll,
    required this.onDeleteAll,
    required this.onCopyAll,
  });

  String _formatTime(int postTime) {
    final dt = DateTime.fromMillisecondsSinceEpoch(postTime);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Opacity(
      opacity: syncEnabled ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
        ),
        child: Row(
          children: [
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      isExpanded ? Icons.expand_more : Icons.chevron_right,
                      size: 22,
                      color: Colors.grey[600],
                    ),
                    const SizedBox(width: 4),
                    CircleAvatar(
                      radius: 16,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        appName.isNotEmpty ? appName[0] : '?',
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width * 0.38,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            appName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            packageName,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            syncEnabled
                                ? l10n.appSyncEnabled
                                : l10n.appSyncDisabled,
                            style: TextStyle(
                              fontSize: 11,
                              color: syncEnabled
                                  ? Colors.green[700]
                                  : Colors.orange[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _formatTime(latestPostTime),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
            ),
            Tooltip(
              message:
                  syncEnabled ? l10n.stopSyncingThisApp : l10n.syncThisApp,
              child: Switch(
                value: syncEnabled,
                onChanged: onToggleSync,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 18, color: Colors.grey[600]),
              onSelected: (v) {
                switch (v) {
                  case 'toggle_sync':
                    onToggleSync(!syncEnabled);
                    break;
                  case 'copy_all':
                    onCopyAll();
                    break;
                  case 'dismiss_all':
                    onDismissAll();
                    break;
                  case 'delete_all':
                    onDeleteAll();
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'toggle_sync',
                  child: Text(syncEnabled
                      ? l10n.stopSyncingThisApp
                      : l10n.syncThisApp),
                ),
                PopupMenuItem(
                    value: 'copy_all', child: Text(l10n.copyContent)),
                PopupMenuItem(
                    value: 'dismiss_all',
                    child: Text(l10n.dismissOnPhone)),
                PopupMenuItem(
                    value: 'delete_all', child: Text(l10n.delete)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
