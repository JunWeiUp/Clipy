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
    unawaited(_load());
  }

  @override
  void dispose() {
    _changes?.cancel();
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
      final page =
          await (widget.loader ?? NotificationRepository.instance.fetchPage)(
            offset: reset ? 0 : _entries.length,
            limit: _pageSize,
            query: _query,
          );
      if (!mounted || revision != _queryRevision) return;
      setState(() {
        if (reset) _entries.clear();
        _entries.addAll(page);
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

  Widget _notificationDetail(NotificationEntry entry) {
    final colors = Theme.of(context).colorScheme;
    final time = DateTime.fromMillisecondsSinceEpoch(entry.postTime);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 28, 24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    child: Text(
                      entry.appName.isEmpty
                          ? '?'
                          : entry.appName.characters.first,
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
                          '${MaterialLocalizations.of(context).formatMediumDate(time)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.copyAll,
                    onPressed: () => _copyNotification(entry),
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ],
              ),
              if (entry.title.isNotEmpty) ...[
                const SizedBox(height: 18),
                SelectableText(
                  entry.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
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
                entry.packageName,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _windowsNotifications(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final matches = _entries.where((entry) => entry.id == _selectedId);
    final selected = matches.isNotEmpty
        ? matches.first
        : (_entries.isEmpty ? null : _entries.first);
    Widget list({required bool narrow}) => _entries.isEmpty && !_loading
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _failed
                      ? l10n.loadFailed
                      : (_query.isEmpty
                            ? l10n.noNotifications
                            : l10n.nothingFound),
                ),
                if (_failed)
                  TextButton(
                    onPressed: () => _load(reset: true),
                    child: Text(l10n.retry),
                  ),
              ],
            ),
          )
        : ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
            itemCount: _entries.length + (_loading || _failed ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _entries.length) {
                return _failed
                    ? TextButton(
                        onPressed: () => _load(reset: true),
                        child: Text(l10n.retry),
                      )
                    : const Center(child: CircularProgressIndicator());
              }
              final item = _entries[index];
              final time = DateTime.fromMillisecondsSinceEpoch(item.postTime);
              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(
                    color: item.id == selected?.id
                        ? colors.primary
                        : colors.outlineVariant.withValues(alpha: .5),
                  ),
                ),
                child: ListTile(
                  title: Text(
                    item.title.isEmpty ? item.appName : item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${item.appName} · ${item.body}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    MaterialLocalizations.of(
                      context,
                    ).formatTimeOfDay(TimeOfDay.fromDateTime(time)),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () {
                    setState(() => _selectedId = item.id);
                    if (narrow) {
                      showDialog<void>(
                        context: context,
                        builder: (context) => Dialog(
                          child: SizedBox(
                            width: 500,
                            child: _notificationDetail(item),
                          ),
                        ),
                      );
                    }
                  },
                ),
              );
            },
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 28, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
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
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
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
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              if (narrow) return list(narrow: true);
              return Row(
                children: [
                  SizedBox(
                    width: (constraints.maxWidth - 320).clamp(300, 420),
                    child: list(narrow: false),
                  ),
                  VerticalDivider(width: 1, color: colors.outlineVariant),
                  Expanded(
                    child: selected == null
                        ? Center(child: Text(l10n.noNotifications))
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
