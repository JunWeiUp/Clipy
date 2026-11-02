import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../app_localizations.dart';
import '../../database/notification_repository.dart';
import '../../models.dart';
import '../../notification_manager.dart';
import '../../ui/app_components.dart';
import '../../ui/windows_controls.dart';
import '../../sync_manager.dart';
import 'windows_notification_service.dart';

/// Read-only mirror of Android notifications on platforms without a system
/// notification listener. Remote posts are stored by NotificationManager.
class RemoteNotificationsPage extends StatefulWidget {
  const RemoteNotificationsPage({super.key, this.windowsLayout, this.loader});
  @visibleForTesting
  final bool? windowsLayout;
  @visibleForTesting
  final Future<List<NotificationEntry>> Function({
    required int offset,
    required int limit,
    required String query,
  })?
  loader;

  @override
  State<RemoteNotificationsPage> createState() =>
      _RemoteNotificationsPageState();
}

class _RemoteNotificationsPageState extends State<RemoteNotificationsPage> {
  static const _pageSize = 40;
  final _entries = <NotificationEntry>[];
  final _scroll = ScrollController();
  StreamSubscription<void>? _changes;
  bool _loading = false;
  bool _hasMore = true;
  bool _failed = false;
  bool _refreshPending = false;
  String _query = '';
  int _queryRevision = 0;
  String? _selectedId;
  NotificationEntry? _selectedEntry;
  bool _unreadOnly = false;
  bool? _bannersEnabled;
  bool _savingPreference = false;
  List<Map<String, Object?>> _sources = [];
  StreamSubscription<List<DiscoveredPeer>>? _peers;
  final _fixtureReadIds = <String>{};
  bool get _windows => widget.windowsLayout ?? Platform.isWindows;
  String _text(String zh, String en) =>
      AppLanguageController.instance.locale.languageCode == 'zh' ? zh : en;
  bool _isRead(NotificationEntry entry) =>
      entry.extras['clipyWindowsRead'] == true ||
      entry.extras['clipyWindowsRead'] == 1 ||
      _fixtureReadIds.contains(entry.id);
  String _sourceName(NotificationEntry entry) =>
      entry.extras['clipyWindowsSourceName'] as String? ??
      _text('来源未知', 'Unknown source');
  Timer? _searchTimer;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _changes = NotificationManager.instance.onNotificationsChanged.listen((_) {
      unawaited(_load(reset: true));
    });
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.extentAfter < 240) {
        unawaited(_load());
      }
    });
    if (_windows) {
      _peers = SyncManager.instance.onPeersChanged.listen((_) {
        if (mounted) setState(() {});
      });
      unawaited(_loadPreferences());
    }
    unawaited(_load());
  }

  Future<void> _loadPreferences() async {
    try {
      final enabled = await WindowsNotificationService.enabled();
      if (mounted) setState(() => _bannersEnabled = enabled);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.loadFailed);
    }
  }

  Future<void> _setBanners(bool enabled) async {
    setState(() => _savingPreference = true);
    try {
      await WindowsNotificationService.setEnabled(enabled);
      if (mounted) setState(() => _bannersEnabled = enabled);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _savingPreference = false);
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _peers?.cancel();
    _searchTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) {
      _refreshPending |= reset;
      return;
    }
    if (!reset && !_hasMore) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final revision = _queryRevision;
    try {
      final page = widget.loader != null
          ? await widget.loader!(
              offset: reset ? 0 : _entries.length,
              limit: _pageSize,
              query: _query,
            )
          : await NotificationRepository.instance.fetchPage(
              offset: reset ? 0 : _entries.length,
              limit: _pageSize,
              query: _query,
              unreadOnly: _windows && _unreadOnly,
            );
      final sources = _windows && widget.loader == null
          ? await NotificationRepository.instance.windowsSourceSummary()
          : <Map<String, Object?>>[];
      if (!mounted || revision != _queryRevision) return;
      setState(() {
        if (reset) _entries.clear();
        _entries.addAll(
          widget.loader != null && _unreadOnly
              ? page.where((entry) => !_isRead(entry))
              : page,
        );
        _sources = sources;
        if (_selectedId != null) {
          final matches = _entries.where((entry) => entry.id == _selectedId);
          if (matches.isNotEmpty) {
            _selectedEntry = matches.first;
          } else if (reset && !_unreadOnly) {
            _selectedEntry = null;
          }
        }
        _hasMore = page.length == _pageSize;
      });
    } catch (_) {
      if (mounted && revision == _queryRevision) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_load(reset: true));
        }
      }
    }
  }

  void _searchChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _queryRevision++;
        _entries.clear();
        _selectedId = null;
        _selectedEntry = null;
        _hasMore = true;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      unawaited(_load(reset: true));
    });
  }

  Future<void> _copyNotification(NotificationEntry entry) async {
    try {
      final text = [
        entry.title,
        if (entry.subtitle?.isNotEmpty == true) entry.subtitle!,
        entry.body,
      ].where((part) => part.trim().isNotEmpty).join('\n');
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) showClipyMessage(context, context.l10n.copiedToClipboard);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  Future<void> _copyCode(String code) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (mounted) showClipyMessage(context, context.l10n.copiedToClipboard);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  Future<void> _select(NotificationEntry entry, bool narrow) async {
    setState(() {
      _selectedId = entry.id;
      _selectedEntry = entry;
    });
    try {
      if (widget.loader == null) {
        await NotificationRepository.instance.markWindowsRead(entry.id);
      }
      if (!mounted) return;
      setState(() {
        if (widget.loader != null) _fixtureReadIds.add(entry.id);
        final index = _entries.indexWhere((item) => item.id == entry.id);
        if (index >= 0) {
          _entries[index] = entry.copyWith(
            extras: {...entry.extras, 'clipyWindowsRead': true},
          );
        }
      });
      if (_unreadOnly || widget.loader == null) unawaited(_load(reset: true));
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
    if (mounted && narrow) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: SizedBox(width: 500, child: _notificationDetail(entry)),
        ),
      );
    }
  }

  Widget _codeChip(NotificationEntry entry) {
    final code = WindowsNotificationService.verificationCode(entry);
    if (code == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          key: ValueKey('code-${entry.id}'),
          onPressed: () => _copyCode(code),
          icon: const Icon(Icons.copy, size: 14),
          label: Text('$code  ·  ${_text('复制验证码', 'Copy code')}'),
        ),
      ),
    );
  }

  Widget _preferences() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          _text('通知偏好', 'Notification preferences'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      Card(
        child: ListTile(
          onTap: _bannersEnabled == null || _savingPreference
              ? null
              : () => _setBanners(!_bannersEnabled!),
          leading: const Icon(Icons.notifications_outlined),
          title: Text(_text('在 Windows 上弹出通知', 'Show Windows notifications')),
          subtitle: Text(
            _text(
              'Clipy 需在系统托盘中运行；系统通知与专注设置影响显示',
              'Keep Clipy running in the tray. System notification and Focus settings apply.',
            ),
          ),
          trailing: WindowsToggle(
            label: _text('在 Windows 上弹出通知', 'Show Windows notifications'),
            value: _bannersEnabled ?? false,
            onChanged: _bannersEnabled == null || _savingPreference
                ? null
                : _setBanners,
          ),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.smartphone_outlined),
          title: Text(_text('选择转发的应用', 'Choose forwarded apps')),
          subtitle: Text(
            _text(
              '在手机端 Clipy → 通知 → 应用管理中设置',
              'On your phone: Clipy → Notifications → App management',
            ),
          ),
          trailing: const Icon(Icons.info_outline),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(_text('选择转发的应用', 'Choose forwarded apps')),
              content: Text(
                _text(
                  '在来源 Android 手机上打开 Clipy → 通知 → 应用管理，选择需要同步的应用。Windows 只查看和复制收到的通知，不能远程修改手机的应用选择。',
                  'Open Clipy → Notifications → App management on the source Android phone and choose which apps to sync. Windows can view and copy received notifications; app selection is managed on the phone.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _notificationDetail(NotificationEntry entry) {
    final time = DateTime.fromMillisecondsSinceEpoch(entry.postTime);
    final received = entry.extras['clipyWindowsReceivedAt'];
    String timestamp(DateTime date) =>
        '${MaterialLocalizations.of(context).formatMediumDate(date)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          entry.appName.isEmpty
                              ? '?'
                              : entry.appName.characters.first,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.appName,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              '${_sourceName(entry)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: context.l10n.copyAll,
                        child: OutlinedButton.icon(
                          onPressed: () => _copyNotification(entry),
                          icon: const Icon(Icons.copy_outlined, size: 16),
                          label: Text(_text('复制全文', 'Copy all')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SelectableText(
                    entry.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (entry.subtitle?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    SelectableText(entry.subtitle!),
                  ],
                  const SizedBox(height: 8),
                  SelectableText(
                    entry.body,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                  const Divider(height: 32),
                  SelectableText(
                    '${_text('应用', 'App')}  ${entry.appName} (${entry.packageName})',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    '${_text('来源设备', 'Source device')}  ${_sourceName(entry)}',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    '${_text('通知时间', 'Posted')}  ${timestamp(time)}',
                  ),
                  if (received is num) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      '${_text('收到时间', 'Received')}  ${timestamp(DateTime.fromMillisecondsSinceEpoch(received.toInt()))}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          _preferences(),
        ],
      ),
    );
  }

  Widget _sourceSummary() {
    final connected = SyncManager.instance.connectedPeerIds;
    final unread = widget.loader != null
        ? _entries.where((entry) => !_isRead(entry)).length
        : _sources.fold<int>(
            0,
            (sum, source) => sum + (source['unread'] as int? ?? 0),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_sources.isEmpty)
                Text(_text('Android 通知镜像', 'Android notification mirror')),
              for (final source in _sources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.smartphone_outlined, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              source['sourceName'] as String? ??
                                  _text(
                                    '来源未知（旧通知）',
                                    'Unknown source (older notifications)',
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${connected.contains(source['sourceId']) ? _text('已连接', 'Connected') : _text('未连接', 'Not connected')} · ${_text('今日', 'Today')} ${source['today']} · ${_text('共', 'Total')} ${source['total']}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final unreadTab in [false, true])
                    TextButton(
                      onPressed: () => _filter(unreadTab),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 3,
                              color: _unreadOnly == unreadTab
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Text(
                          unreadTab
                              ? '${_text('未读', 'Unread')} $unread'
                              : _text('全部', 'All'),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _filter(bool unread) {
    if (_unreadOnly == unread) return;
    setState(() {
      _unreadOnly = unread;
      _queryRevision++;
      _entries.clear();
      _hasMore = true;
    });
    unawaited(_load(reset: true));
  }

  Widget _windowsNotifications(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final selected =
        _selectedEntry ?? (_entries.isEmpty ? null : _entries.first);
    final groups = <String, List<NotificationEntry>>{};
    for (final entry in _entries) {
      (groups[entry.packageName] ??= []).add(entry);
    }
    Widget list(bool narrow) => CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
          sliver: SliverMainAxisGroup(
            slivers: [
              if (_entries.isEmpty && !_loading)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _failed
                          ? l10n.loadFailed
                          : (_query.isEmpty && !_unreadOnly
                                ? l10n.noNotifications
                                : l10n.nothingFound),
                    ),
                  ),
                ),
              for (final group in groups.values) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
                    child: Text(
                      '${group.first.appName} · ${group.length} ${_text('条已加载', 'loaded')}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: group.length,
                  itemBuilder: (context, index) {
                    final item = group[index];
                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(
                          color: item.id == selected?.id
                              ? colors.primary
                              : colors.outlineVariant,
                        ),
                      ),
                      child: InkWell(
                        onTap: () => _select(item, narrow),
                        child: Container(
                          decoration: BoxDecoration(
                            border: _isRead(item)
                                ? null
                                : Border(
                                    left: BorderSide(
                                      width: 3,
                                      color: colors.primary,
                                    ),
                                  ),
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.title.isEmpty
                                          ? item.appName
                                          : item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    MaterialLocalizations.of(
                                      context,
                                    ).formatTimeOfDay(
                                      TimeOfDay.fromDateTime(
                                        DateTime.fromMillisecondsSinceEpoch(
                                          item.postTime,
                                        ),
                                      ),
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${item.appName} · ${item.body}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              _codeChip(item),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    if (_loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    if (_failed)
                      TextButton(
                        onPressed: () => _load(reset: true),
                        child: Text(l10n.retry),
                      ),
                    if (_hasMore && !_loading && !_failed)
                      TextButton(
                        onPressed: _load,
                        child: Text(_text('加载更多', 'Load more')),
                      ),
                    if (narrow) _preferences(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _text('手机通知', 'Phone notifications'),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: TextField(
                  controller: _search,
                  onChanged: _searchChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.searchNotifications,
                    suffixIcon: IconButton(
                      tooltip: l10n.clearSearch,
                      onPressed: () {
                        _search.clear();
                        _searchChanged('');
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.remoteNotificationIntro,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 700;
              final pane = Column(
                children: [
                  // Summary remains bounded visually even with many source devices.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 190),
                    child: SingleChildScrollView(child: _sourceSummary()),
                  ),
                  Expanded(child: list(narrow)),
                ],
              );
              if (narrow) return pane;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: (constraints.maxWidth * .43).clamp(300, 440),
                    child: pane,
                  ),
                  VerticalDivider(width: 1, color: colors.outlineVariant),
                  Expanded(
                    child: selected == null
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              children: [
                                Text(l10n.noNotifications),
                                _preferences(),
                              ],
                            ),
                          )
                        : _notificationDetail(selected),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.windowsLayout ?? Platform.isWindows) {
      return _windowsNotifications(context);
    }
    if (_entries.isEmpty && !_loading) {
      return Center(
        child: Text(
          _failed ? context.l10n.loadFailed : context.l10n.noNotifications,
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      itemCount: _entries.length + (_loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _entries.length) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final item = _entries[index];
        final time = DateTime.fromMillisecondsSinceEpoch(item.postTime);
        if (Platform.isIOS) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: CupertinoDynamicColor.resolve(
                CupertinoColors.secondarySystemGroupedBackground,
                context,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.bell_fill,
                      size: 16,
                      color: CupertinoColors.systemBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.appName,
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoDynamicColor.resolve(
                            CupertinoColors.secondaryLabel,
                            context,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      MaterialLocalizations.of(
                        context,
                      ).formatTimeOfDay(TimeOfDay.fromDateTime(time)),
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoDynamicColor.resolve(
                          CupertinoColors.secondaryLabel,
                          context,
                        ),
                      ),
                    ),
                  ],
                ),
                if (item.title.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  item.body,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
          );
        }
        return Card(
          child: ListTile(
            title: Text(item.title.isEmpty ? item.appName : item.title),
            subtitle: Text(
              item.body,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              MaterialLocalizations.of(
                context,
              ).formatTimeOfDay(TimeOfDay.fromDateTime(time)),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        );
      },
    );
  }
}
