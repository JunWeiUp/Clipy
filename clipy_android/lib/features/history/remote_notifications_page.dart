import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_localizations.dart';
import '../../database/notification_repository.dart';
import '../../models.dart';
import '../../notification_manager.dart';

/// Read-only mirror of Android notifications on platforms without a system
/// notification listener. Remote posts are stored by NotificationManager.
class RemoteNotificationsPage extends StatefulWidget {
  const RemoteNotificationsPage({super.key});

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
    try {
      final page = await NotificationRepository.instance.fetchPage(
        offset: reset ? 0 : _entries.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _entries.clear();
        _entries.addAll(page);
        _hasMore = page.length == _pageSize;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
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

  @override
  Widget build(BuildContext context) {
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
