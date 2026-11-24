part of '../../notification_sync_page.dart';

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
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                ),
              if (body.isNotEmpty && body != title)
                Text(
                  body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                '$timeDisplay · ${isCollected ? l10n.collect : l10n.appCollectDisabled} · ${syncEnabled ? l10n.sync : l10n.appSyncDisabled}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          isThreeLine: entry.isArchived || (body.isNotEmpty && body != title),
          trailing: PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
                  isCollected
                      ? l10n.stopCollectingThisApp
                      : l10n.collectThisApp,
                ),
              ),
              PopupMenuItem(
                value: 'toggle_sync',
                enabled: isCollected,
                child: Text(
                  syncEnabled ? l10n.stopSyncingThisApp : l10n.syncThisApp,
                ),
              ),
              if (entry.isClearable)
                PopupMenuItem(
                  value: 'dismiss_phone',
                  child: Text(l10n.dismissOnPhone),
                ),
              PopupMenuItem(value: 'dismiss_local', child: Text(l10n.delete)),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            isExpanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 22,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
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
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  appName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
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
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
                        isCollected
                            ? l10n.stopCollectingThisApp
                            : l10n.collectThisApp,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'toggle_sync',
                      enabled: isCollected,
                      child: Text(
                        syncEnabled
                            ? l10n.stopSyncingThisApp
                            : l10n.syncThisApp,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'copy_all',
                      child: Text(l10n.copyContent),
                    ),
                    PopupMenuItem(
                      value: 'dismiss_all',
                      child: Text(l10n.dismissOnPhone),
                    ),
                    PopupMenuItem(
                      value: 'delete_all',
                      child: Text(l10n.delete),
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 68),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _formatTime(latestPostTime),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _HistoryToggleButton(
                    label: l10n.collect,
                    tooltip: isCollected
                        ? l10n.stopCollectingThisApp
                        : l10n.collectThisApp,
                    selected: isCollected,
                    onPressed: () => onToggleCollected(!isCollected),
                  ),
                  const SizedBox(width: 6),
                  _HistoryToggleButton(
                    label: l10n.sync,
                    tooltip: syncEnabled
                        ? l10n.stopSyncingThisApp
                        : l10n.syncThisApp,
                    selected: isCollected && syncEnabled,
                    onPressed: isCollected
                        ? () => onToggleSync(!syncEnabled)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-tap control for per-app settings in the history list.
class _HistoryToggleButton extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback? onPressed;

  const _HistoryToggleButton({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        toggled: selected,
        enabled: enabled,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Material(
            color: selected
                ? colors.primaryContainer
                : colors.surfaceContainerHighest,
            shape: StadiumBorder(
              side: BorderSide(
                color: selected ? colors.primary : colors.outlineVariant,
              ),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onPressed,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 36),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: !enabled
                            ? colors.outline
                            : selected
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
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

  Widget _buildSwitch(
    BuildContext context,
    String label,
    bool value,
    ValueChanged<bool>? onChanged,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            height: 1.0,
            color: onChanged == null
                ? Theme.of(context).colorScheme.outline
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        SizedBox(
          width: 52,
          height: 44,
          child: Center(
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
        _buildSwitch(context, collectLabel, isCollected, onToggleCollected),
        const SizedBox(width: 4),
        _buildSwitch(
          context,
          syncLabel,
          syncEnabled,
          isCollected ? onToggleSync : null,
        ),
      ],
    );
  }
}
