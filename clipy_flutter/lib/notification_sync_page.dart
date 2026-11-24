import 'dart:async';
import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'clipboard_manager.dart';
import 'database/notification_repository.dart';
import 'models.dart';
import 'utils/async_refresh_controller.dart';
import 'notification_manager.dart';
import 'notification_health_monitor.dart';
import 'ui/app_components.dart';

part 'features/notifications/notification_sync_widgets.dart';

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
  final _historyRefresh = AsyncRefreshController();
  bool _appsLoaded = false;
  bool _appsLoading = false;
  bool _appsFailed = false;
  bool _historyLoading = true;
  bool _historyFailed = false;

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
          unawaited(_rebuildHistoryItems());
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
    WidgetsBinding.instance.removeObserver(this);
    _historyRefresh.dispose();
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
    try {
      await _historyRefresh.refresh(_loadHistoryItems);
      if (mounted) setState(() => _historyFailed = false);
    } catch (_) {
      if (mounted) setState(() => _historyFailed = true);
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _loadHistoryItems(bool Function() isCurrent) async {
    if (!mounted || !isCurrent()) return;
    final l10n = context.l10n;
    final totalCount = await NotificationManager.instance.count();
    final appCount = await NotificationRepository.instance.packageGroupCount();
    final groups = await NotificationRepository.instance.fetchPackageGroups(
      offset: 0,
      limit: _packageGroupPageSize,
    );

    if (totalCount == 0) {
      if (mounted && isCurrent()) setState(() => _historyItems = const []);
      return;
    }

    if (!mounted || !isCurrent()) return;

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
      if (!isCurrent()) return;
      final isExpanded = _expandedApps.contains(group.packageName);
      List<NotificationEntry>? expandedItems;
      if (isExpanded) {
        expandedItems = await NotificationRepository.instance.fetchByPackage(
          group.packageName,
          offset: 0,
          limit: _notificationsPerPackage,
        );
        if (!isCurrent()) return;
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

    if (mounted && isCurrent()) setState(() => _historyItems = rows);
  }

  Future<List<NotificationEntry>> _notificationsForPackage(
    String packageName,
  ) async {
    return NotificationRepository.instance.fetchByPackage(
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
    if (_appsLoading) return;
    if (mounted) {
      setState(() {
        _appsLoading = true;
        _appsFailed = false;
      });
    }
    try {
      final apps = await NotificationManager.instance.getInstalledApps();
      if (mounted) {
        setState(() {
          _installedApps = apps;
          _appsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _appsFailed = true);
    } finally {
      if (mounted) setState(() => _appsLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tabBar = TabBar(
      controller: _tabController,
      tabs: [
        Tab(text: l10n.notificationSettings),
        Tab(text: l10n.notificationHistory),
      ],
    );
    final body = TabBarView(
      controller: _tabController,
      children: [_buildSettingsTab(), _buildHistoryTab()],
    );

    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(child: tabBar),
                PopupMenuButton<String>(
                  tooltip: l10n.moreActions,
                  onSelected: _handleMenuAction,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'open_permission',
                      child: Text(l10n.notificationListenerPermission),
                    ),
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
            ),
          ),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.syncNotificationsFrom,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.packageSelection(
                    manager.collectedPackages.length,
                    manager.syncedPackages.length,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
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
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
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
        else if (_appsFailed)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(l10n.loadFailed),
                  TextButton(
                    onPressed: _loadInstalledApps,
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            ),
          )
        else if (appItems.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  l10n.noAppsAvailable,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
      minTileHeight: 80,
      leading: const ClipyIcon(Icons.apps_rounded, size: 36),
      title: Text(
        appName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Text(
        packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      color: _permissionGranted
          ? colors.primaryContainer
          : colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _permissionGranted
                      ? Icons.verified_user_outlined
                      : Icons.notifications_active_outlined,
                  color: _permissionGranted
                      ? colors.onPrimaryContainer
                      : colors.onTertiaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _permissionGranted
                        ? l10n.permissionGranted
                        : l10n.notificationListenerPermission,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: _permissionGranted
                          ? colors.onPrimaryContainer
                          : colors.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _permissionGranted
                  ? l10n.notificationIntro
                  : l10n.permissionGuide,
              style: TextStyle(
                color: _permissionGranted
                    ? colors.onPrimaryContainer
                    : colors.onTertiaryContainer,
                height: 1.5,
              ),
            ),
            if (!_permissionGranted) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    NotificationManager.instance.openListenerSettings(),
                child: Text(l10n.grantPermission),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // MARK: - History Tab

  Widget _buildHistoryTab() {
    final l10n = context.l10n;

    if (_historyItems.isEmpty) {
      if (_historyLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return ClipyEmptyState(
        icon: _historyFailed
            ? Icons.cloud_off_outlined
            : Icons.notifications_none_rounded,
        title: _historyFailed ? l10n.loadFailed : l10n.noNotificationHistory,
        message: _historyFailed ? l10n.retryHint : l10n.notificationEmptyHint,
        action: _historyFailed
            ? FilledButton(
                onPressed: _rebuildHistoryItems,
                child: Text(l10n.retry),
              )
            : null,
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
            final (IconData icon, Color iconColor) = switch (sectionKey) {
              'synced' => (Icons.sync, Theme.of(context).colorScheme.primary),
              'collected' => (
                Icons.check_circle_outline,
                Theme.of(context).colorScheme.primary,
              ),
              _ => (
                Icons.block,
                Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Row(
                  children: [
                    Icon(
                      item.sectionIsCollapsed!
                          ? Icons.chevron_right
                          : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: 6),
                    Text(
                      item.sectionTitle!,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${item.sectionCount}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
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
              },
              onCopyAll: () async {
                try {
                  final notifications = await _notificationsForPackage(
                    item.packageName!,
                  );
                  if (!mounted) return;
                  await _copyNotificationText(
                    notifications.map(_notificationDetailText).join('\n\n'),
                  );
                } catch (_) {
                  if (context.mounted) {
                    showClipyMessage(context, l10n.operationFailed);
                  }
                }
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
              onCopy: () =>
                  _copyNotificationText(_notificationDetailText(entry)),
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
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${item.appCount}',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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

  Future<bool> _copyNotificationText(String text) async {
    try {
      await ClipboardManager.instance.copyToClipboard(
        HistoryItem(type: 'text', value: text),
      );
      if (mounted) showClipyMessage(context, context.l10n.copiedToClipboard);
      return true;
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
      return false;
    }
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
                    onPressed: () async {
                      final copied = await _copyNotificationText(
                        _notificationDetailText(entry),
                      );
                      if (copied && ctx.mounted) Navigator.pop(ctx);
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
