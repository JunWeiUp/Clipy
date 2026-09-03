import 'dart:async';
import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'clipboard_manager.dart';
import 'database/notification_repository.dart';
import 'models.dart';
import 'notification_manager.dart';
import 'notification_health_monitor.dart';

class NotificationSyncPage extends StatefulWidget {
  final bool embedded;

  const NotificationSyncPage({super.key, this.embedded = false});

  @override
  State<NotificationSyncPage> createState() => _NotificationSyncPageState();
}

class _NotificationSyncPageState extends State<NotificationSyncPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _historyTabIndex = 1;

  late TabController _tabController;
  bool _permissionGranted = false;
  List<Map<String, dynamic>> _installedApps = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;
  StreamSubscription? _notifSubscription;
  StreamSubscription? _collectedSub;
  StreamSubscription? _syncedSub;
  final Set<String> _expandedApps = {};
  final Set<String> _collapsedSections = {};
  List<_HistoryListItem> _historyItems = [];
  final Map<String, List<NotificationEntry>> _packageNotificationsCache = {};
  bool _appsLoaded = false;
  bool _appsLoading = false;

  /// Distinguishes first permission probe from a real denied→granted transition.
  bool _permissionStatusLoaded = false;
  static const _packageGroupPageSize = 20;
  static const _notificationsPerPackage = 50;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChanged);
    _loadPermissionStatus();
    unawaited(_loadInstalledApps());
    unawaited(_rebuildHistoryItems());
    _notifSubscription = NotificationManager.instance.onNotificationsChanged
        .listen((_) {
          if (!mounted) return;
          unawaited(
            _rebuildHistoryItems().then((_) {
              if (mounted && _tabController.index == _historyTabIndex) {
                setState(() {});
              }
            }),
          );
        });
    _collectedSub = NotificationManager.instance.onCollectedPackagesChanged
        .listen((_) {
          if (!mounted) return;
          unawaited(_rebuildHistoryItems());
        });
    _syncedSub = NotificationManager.instance.onSyncedPackagesChanged.listen((
      _,
    ) {
      if (!mounted) return;
      unawaited(_rebuildHistoryItems());
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _notifSubscription?.cancel();
    _collectedSub?.cancel();
    _syncedSub?.cancel();
    // Free the process-wide installed-apps list (~300 entries); it is only
    // needed while this page is open.
    NotificationManager.instance.evictInstalledAppsCache();
    super.dispose();
  }

  Future<void> _setPackageSyncEnabled(String packageName, bool enabled) async {
    await NotificationManager.instance.setPackageSynced(packageName, enabled);
    if (mounted) setState(() {});
  }

  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 0 && !_appsLoaded) {
      unawaited(_loadInstalledApps());
    }
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

  Future<void> _rebuildHistoryItems() async {
    final l10n = context.l10n;
    final totalCount = await NotificationManager.instance.count();
    final appCount = await NotificationRepository.instance.packageGroupCount();
    final groups = await NotificationRepository.instance.fetchPackageGroups(
      offset: 0,
      limit: _packageGroupPageSize,
    );

    if (totalCount == 0) {
      if (mounted) setState(() => _historyItems = const []);
      return;
    }

    if (!mounted) return;

    final rows = <_HistoryListItem>[
      _HistoryListItem.summary(
        notificationCount: totalCount,
        appCount: appCount,
      ),
    ];

    // 按同步/收集状态分三段：可同步 → 可收集 → 不可收集
    final syncedGroups = <NotificationPackageGroup>[];
    final collectedOnlyGroups = <NotificationPackageGroup>[];
    final notCollectedGroups = <NotificationPackageGroup>[];
    final manager = NotificationManager.instance;
    for (final group in groups) {
      final collected = manager.isPackageCollected(group.packageName);
      if (!collected) {
        notCollectedGroups.add(group);
      } else if (manager.isPackageSynced(group.packageName)) {
        syncedGroups.add(group);
      } else {
        collectedOnlyGroups.add(group);
      }
    }

    Future<void> appendGroup(NotificationPackageGroup group) async {
      final isExpanded = _expandedApps.contains(group.packageName);
      List<NotificationEntry>? expandedItems;
      if (isExpanded) {
        expandedItems =
            _packageNotificationsCache[group.packageName] ??
            await NotificationRepository.instance.fetchByPackage(
              group.packageName,
              offset: 0,
              limit: _notificationsPerPackage,
            );
        _packageNotificationsCache[group.packageName] = expandedItems;
      }

      rows.add(
        _HistoryListItem.groupHeader(
          appName: group.appName,
          packageName: group.packageName,
          count: group.count,
          isExpanded: isExpanded,
          latestPostTime: group.latestPostTime,
          notifications: expandedItems ?? const [],
        ),
      );
      if (isExpanded && expandedItems != null) {
        for (final entry in expandedItems) {
          rows.add(_HistoryListItem.notification(entry));
        }
      }
    }

    Future<void> appendSection({
      required String sectionKey,
      required String title,
      required List<NotificationPackageGroup> sectionGroups,
    }) async {
      if (sectionGroups.isEmpty) return;
      final isCollapsed = _collapsedSections.contains(sectionKey);
      rows.add(
        _HistoryListItem.sectionHeader(
          title: title,
          sectionKey: sectionKey,
          isCollapsed: isCollapsed,
          count: sectionGroups.length,
        ),
      );
      if (!isCollapsed) {
        for (final group in sectionGroups) {
          await appendGroup(group);
        }
      }
    }

    await appendSection(
      sectionKey: 'synced',
      title: l10n.syncedSection,
      sectionGroups: syncedGroups,
    );
    await appendSection(
      sectionKey: 'collected',
      title: l10n.collectedSection,
      sectionGroups: collectedOnlyGroups,
    );
    await appendSection(
      sectionKey: 'not_collected',
      title: l10n.notCollectedSection,
      sectionGroups: notCollectedGroups,
    );

    if (mounted) setState(() => _historyItems = rows);
  }

  Future<List<NotificationEntry>> _notificationsForPackage(
    String packageName,
  ) async {
    return _packageNotificationsCache[packageName] ??
        await NotificationRepository.instance.fetchByPackage(
          packageName,
          offset: 0,
          limit: 500,
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPermissionStatus();
    }
  }

  Future<void> _loadPermissionStatus() async {
    final granted = await NotificationManager.instance
        .isListenerPermissionGranted();
    if (!mounted) return;
    final wasGranted = _permissionGranted;
    final isInitialLoad = !_permissionStatusLoaded;
    _permissionStatusLoaded = true;
    setState(() => _permissionGranted = granted);
    // Only refresh after a real denied→granted transition (e.g. user returned
    // from system settings). The initial open must not treat the default
    // `_permissionGranted == false` as "just granted", or every visit to this
    // page re-ingests active notifications and can re-broadcast them to Mac.
    if (!isInitialLoad &&
        !wasGranted &&
        granted &&
        NotificationManager.instance.isEnabled) {
      await NotificationManager.instance.refreshActiveNotifications();
    }
  }

  Future<void> _loadInstalledApps() async {
    if (mounted) setState(() => _appsLoading = true);
    final apps = await NotificationManager.instance.getInstalledApps();
    if (mounted) {
      setState(() {
        _installedApps = apps;
        _appsLoaded = true;
        _appsLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tabBar = TabBar(
      controller: _tabController,
      tabs: [
        Tab(icon: const Icon(Icons.tune), text: l10n.settings),
        Tab(
          icon: const Icon(Icons.notifications),
          text: l10n.notificationHistory,
        ),
      ],
    );
    final body = TabBarView(
      controller: _tabController,
      children: [_buildSettingsTab(), _buildHistoryTab()],
    );

    if (widget.embedded) {
      return Column(
        children: [
          Material(color: Theme.of(context).colorScheme.surface, child: tabBar),
          Expanded(child: body),
        ],
      );
    }

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
        bottom: tabBar,
      ),
      body: body,
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
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverToBoxAdapter(
          child: SwitchListTile(
            title: Text(l10n.enableNotificationSync),
            subtitle: Text(
              !_permissionGranted
                  ? l10n.notificationPermissionRequired
                  : (manager.isEnabled ? l10n.syncing : l10n.paused),
            ),
            value: manager.isEnabled && _permissionGranted,
            onChanged: _permissionGranted
                ? (value) async {
                    await manager.setEnabled(value);
                    if (value) {
                      await NotificationHealthMonitor.instance.startIfNeeded();
                    } else {
                      NotificationHealthMonitor.instance.stop();
                    }
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
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(
                  Icons.filter_list,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
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
                  '收集 ${manager.collectedPackages.isEmpty ? "全部" : manager.collectedPackages.length} · 同步 ${manager.syncedPackages.isEmpty ? "全部" : manager.syncedPackages.length}',
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
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.select_all, size: 18),
                  onPressed: () async {
                    await manager.collectAllPackages();
                    if (mounted) setState(() {});
                  },
                  label: Text(l10n.collectAll),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.sync, size: 18),
                  onPressed: () async {
                    await manager.syncAllPackages();
                    if (mounted) setState(() {});
                  },
                  label: Text(l10n.syncAll),
                ),
              ],
            ),
          ),
        ),
        if (_appsLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (appItems.isEmpty)
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
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = appItems[index];
              if (item.isHeader) {
                return _buildSectionHeader(item.title!, item.count!);
              }
              return _buildAppTile(item.app!, manager);
            }, childCount: appItems.length),
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
    final l10n = context.l10n;
    final packageName = app['packageName'] as String;
    final appName = app['appName'] as String;
    final isCollected = manager.isPackageCollected(packageName);
    final isSynced = manager.isPackageSynced(packageName);
    return ListTile(
      title: Text(appName, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        packageName,
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
      ),
      trailing: _CompactTogglePair(
        collectLabel: l10n.collect,
        syncLabel: l10n.sync,
        isCollected: isCollected,
        syncEnabled: isSynced,
        onToggleCollected: (v) => manager.setPackageCollected(packageName, v),
        onToggleSync: (v) => manager.setPackageSynced(packageName, v),
      ),
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
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
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
          case _HistoryListItemKind.sectionHeader:
            final sectionKey = item.sectionKey!;
            final (IconData icon, Color? iconColor) = switch (sectionKey) {
              'synced' => (Icons.sync, Colors.blue[700]),
              'collected' => (Icons.check_circle_outline, Colors.green[700]),
              _ => (Icons.block, Colors.grey[500]),
            };
            return InkWell(
              onTap: () async {
                if (_collapsedSections.contains(sectionKey)) {
                  _collapsedSections.remove(sectionKey);
                } else {
                  _collapsedSections.add(sectionKey);
                }
                await _rebuildHistoryItems();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: Colors.grey[100],
                child: Row(
                  children: [
                    Icon(
                      item.sectionIsCollapsed!
                          ? Icons.chevron_right
                          : Icons.expand_more,
                      size: 18,
                      color: Colors.grey[600],
                    ),
                    const SizedBox(width: 4),
                    Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: 6),
                    Text(
                      item.sectionTitle!,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${item.sectionCount}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                      ),
                    ),
                  ],
                ),
              ),
            );
          case _HistoryListItemKind.groupHeader:
            final isCollected = NotificationManager.instance.isPackageCollected(
              item.packageName!,
            );
            final syncEnabled = NotificationManager.instance.isPackageSynced(
              item.packageName!,
            );
            return _AppGroupHeader(
              appName: item.appName!,
              packageName: item.packageName!,
              count: item.count!,
              isExpanded: item.isExpanded!,
              latestPostTime: item.latestPostTime!,
              isCollected: isCollected,
              syncEnabled: syncEnabled,
              onToggleCollected: (enabled) {
                NotificationManager.instance.setPackageCollected(
                  item.packageName!,
                  enabled,
                );
              },
              onToggleSync: (enabled) =>
                  _setPackageSyncEnabled(item.packageName!, enabled),
              onTap: () async {
                if (item.isExpanded!) {
                  _expandedApps.remove(item.packageName);
                } else {
                  _expandedApps.add(item.packageName!);
                }
                await _rebuildHistoryItems();
              },
              onDismissAll: () async {
                final notifications = await _notificationsForPackage(
                  item.packageName!,
                );
                for (final notification in notifications) {
                  NotificationManager.instance.broadcastDismissToRemote(
                    NotificationDismissRequest(
                      packageName: notification.packageName,
                      groupKey: notification.groupKey,
                      notificationKey: notification.notificationKey,
                    ),
                  );
                  await NotificationManager.instance.removeNotification(
                    notification.id,
                  );
                }
                _packageNotificationsCache.remove(item.packageName);
              },
              onDeleteAll: () async {
                final notifications = await _notificationsForPackage(
                  item.packageName!,
                );
                for (final notification in notifications) {
                  await NotificationManager.instance.removeNotification(
                    notification.id,
                  );
                }
                _packageNotificationsCache.remove(item.packageName);
              },
              onCopyAll: () async {
                // Resolve the messenger before the await: `context` may be
                // unmounted by the time the notifications load, and looking it
                // up then throws.
                final messenger = ScaffoldMessenger.of(context);
                final message = l10n.copiedToClipboard;
                final notifications = await _notificationsForPackage(
                  item.packageName!,
                );
                final text = notifications
                    .map(_notificationDetailText)
                    .join('\n\n');
                ClipboardManager.instance.copyToClipboard(
                  HistoryItem(type: 'text', value: text),
                );
                if (!mounted) return;
                messenger.showSnackBar(SnackBar(content: Text(message)));
              },
            );
          case _HistoryListItemKind.notification:
            final entry = item.entry!;
            final isCollected = NotificationManager.instance.isPackageCollected(
              entry.packageName,
            );
            final syncEnabled = NotificationManager.instance.isPackageSynced(
              entry.packageName,
            );
            return _NotificationTile(
              entry: entry,
              isCollected: isCollected,
              syncEnabled: syncEnabled,
              onToggleCollected: (enabled) {
                NotificationManager.instance.setPackageCollected(
                  entry.packageName,
                  enabled,
                );
              },
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
                  HistoryItem(
                    type: 'text',
                    value: _notificationDetailText(entry),
                  ),
                );
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l10n.copiedToClipboard)));
              },
              onOpen: () =>
                  NotificationManager.instance.openNotification(entry),
              onShowDetails: () => _showNotificationDetails(entry),
            );
        }
      },
    );
  }

  Widget _buildHistorySummary(AppStrings l10n, _HistoryListItem item) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(
            Icons.notifications_active,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
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
      if (entry.isArchived) 'Archived: yes (WeChat history snapshot)',
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
              Text(entry.appName, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(entry.packageName, style: Theme.of(ctx).textTheme.bodySmall),
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
                          value: _notificationDetailText(entry),
                        ),
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
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
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
        unawaited(
          Future<void>.delayed(
            const Duration(seconds: 1),
            _loadPermissionStatus,
          ),
        );
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

enum _HistoryListItemKind { summary, sectionHeader, groupHeader, notification }

class _HistoryListItem {
  final _HistoryListItemKind kind;
  final int? notificationCount;
  final int? appCount;
  final String? sectionTitle;
  final String? sectionKey;
  final bool? sectionIsCollapsed;
  final int? sectionCount;
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
    this.sectionTitle,
    this.sectionKey,
    this.sectionIsCollapsed,
    this.sectionCount,
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

  factory _HistoryListItem.sectionHeader({
    required String title,
    required String sectionKey,
    required bool isCollapsed,
    required int count,
  }) {
    return _HistoryListItem._(
      kind: _HistoryListItemKind.sectionHeader,
      sectionTitle: title,
      sectionKey: sectionKey,
      sectionIsCollapsed: isCollapsed,
      sectionCount: count,
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
  final bool isCollected;
  final bool syncEnabled;
  final ValueChanged<bool> onToggleCollected;
  final ValueChanged<bool> onToggleSync;
  final VoidCallback onDismiss;
  final VoidCallback onDismissOnPhone;
  final VoidCallback onCopy;
  final VoidCallback onOpen;
  final VoidCallback onShowDetails;

  const _NotificationTile({
    required this.entry,
    required this.isCollected,
    required this.syncEnabled,
    required this.onToggleCollected,
    required this.onToggleSync,
    required this.onDismiss,
    required this.onDismissOnPhone,
    required this.onCopy,
    required this.onOpen,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final timeStr = DateTime.fromMillisecondsSinceEpoch(entry.postTime);
    final timeDisplay =
        '${timeStr.hour.toString().padLeft(2, '0')}:${timeStr.minute.toString().padLeft(2, '0')}';
    final title = entry.title.trim().isNotEmpty
        ? entry.title.trim()
        : (entry.body.trim().isNotEmpty ? entry.body.trim() : entry.appName);
    final body = entry.body.trim();

    return Opacity(
      opacity: isCollected ? 1 : 0.55,
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
              if (entry.isArchived)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    l10n.notificationArchivedBadge,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ),
              if (body.isNotEmpty && body != title)
                Text(
                  body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
              const SizedBox(height: 2),
              Text(
                '${entry.appName} · $timeDisplay · ${isCollected ? l10n.collect : l10n.appSyncDisabled}/${syncEnabled ? l10n.sync : l10n.appSyncDisabled}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
          ),
          isThreeLine: entry.isArchived || (body.isNotEmpty && body != title),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CompactTogglePair(
                collectLabel: l10n.collect,
                syncLabel: l10n.sync,
                isCollected: isCollected,
                syncEnabled: syncEnabled,
                onToggleCollected: onToggleCollected,
                onToggleSync: onToggleSync,
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, size: 18, color: Colors.grey[600]),
                onSelected: (v) {
                  switch (v) {
                    case 'copy':
                      onCopy();
                      break;
                    case 'toggle_collect':
                      onToggleCollected(!isCollected);
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
                  PopupMenuItem(value: 'copy', child: Text(l10n.copyContent)),
                  PopupMenuItem(
                    value: 'toggle_collect',
                    child: Text(
                      isCollected ? l10n.stopSyncingThisApp : l10n.syncThisApp,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'toggle_sync',
                    child: Text(
                      syncEnabled ? l10n.stopSyncingThisApp : l10n.syncThisApp,
                    ),
                  ),
                  if (entry.isClearable)
                    PopupMenuItem(
                      value: 'dismiss_phone',
                      child: Text(l10n.dismissOnPhone),
                    ),
                  PopupMenuItem(
                    value: 'dismiss_local',
                    child: Text(l10n.delete),
                  ),
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
  final bool isCollected;
  final bool syncEnabled;
  final ValueChanged<bool> onToggleCollected;
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
    required this.isCollected,
    required this.syncEnabled,
    required this.onToggleCollected,
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
      opacity: isCollected ? 1 : 0.55,
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
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      child: Text(
                        appName.isNotEmpty ? appName[0] : '?',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width * 0.28,
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
                            '${isCollected ? l10n.collect : l10n.appSyncDisabled} · ${syncEnabled ? l10n.sync : l10n.appSyncDisabled}',
                            style: TextStyle(
                              fontSize: 11,
                              color: isCollected && syncEnabled
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
            _CompactTogglePair(
              collectLabel: l10n.collect,
              syncLabel: l10n.sync,
              isCollected: isCollected,
              syncEnabled: syncEnabled,
              onToggleCollected: onToggleCollected,
              onToggleSync: onToggleSync,
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
                  case 'toggle_collect':
                    onToggleCollected(!isCollected);
                    break;
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
                  value: 'toggle_collect',
                  child: Text(
                    isCollected ? l10n.stopSyncingThisApp : l10n.syncThisApp,
                  ),
                ),
                PopupMenuItem(
                  value: 'toggle_sync',
                  child: Text(
                    syncEnabled ? l10n.stopSyncingThisApp : l10n.syncThisApp,
                  ),
                ),
                PopupMenuItem(value: 'copy_all', child: Text(l10n.copyContent)),
                PopupMenuItem(
                  value: 'dismiss_all',
                  child: Text(l10n.dismissOnPhone),
                ),
                PopupMenuItem(value: 'delete_all', child: Text(l10n.delete)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 紧凑的水平双开关（收集 + 同步），占用最小空间。
class _CompactTogglePair extends StatelessWidget {
  final String collectLabel;
  final String syncLabel;
  final bool isCollected;
  final bool syncEnabled;
  final ValueChanged<bool> onToggleCollected;
  final ValueChanged<bool>? onToggleSync;

  const _CompactTogglePair({
    required this.collectLabel,
    required this.syncLabel,
    required this.isCollected,
    required this.syncEnabled,
    required this.onToggleCollected,
    required this.onToggleSync,
  });

  Widget _buildSwitch(String label, bool value, ValueChanged<bool>? onChanged) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            height: 1.0,
            color: onChanged == null ? Colors.grey[400] : Colors.grey[600],
          ),
        ),
        SizedBox(
          width: 45,
          height: 24,
          child: FittedBox(
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSwitch(collectLabel, isCollected, onToggleCollected),
        const SizedBox(width: 4),
        _buildSwitch(syncLabel, syncEnabled, isCollected ? onToggleSync : null),
      ],
    );
  }
}
