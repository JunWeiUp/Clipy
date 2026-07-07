import 'dart:async';
import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'collector_manager.dart';
import 'models.dart';

class CollectorEventsPage extends StatefulWidget {
  const CollectorEventsPage({super.key});

  @override
  State<CollectorEventsPage> createState() => _CollectorEventsPageState();
}

class _CollectorEventsPageState extends State<CollectorEventsPage> {
  static const _pageSize = 50;

  final ScrollController _scrollController = ScrollController();
  final List<CollectorEvent> _events = [];
  StreamSubscription? _eventsSubscription;
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
    _eventsSubscription =
        CollectorManager.instance.onEventsChanged.listen((_) => _reload());
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    _events.clear();
    _hasMore = true;
    _loadMore(reset: true);
  }

  void _onScroll() {
    if (!_hasMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore({bool reset = false}) async {
    if (_loading) return;
    _loading = true;
    final offset = reset ? 0 : _events.length;
    final page = await CollectorManager.instance.fetchPage(
      offset: offset,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      if (reset) _events.clear();
      _events.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    if (_events.isEmpty && !_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.noCollectorEvents,
            style: TextStyle(color: Colors.grey[500], fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _events.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _events.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _EventTile(event: _events[index], l10n: l10n);
      },
    );
  }
}

class _EventTile extends StatelessWidget {
  final CollectorEvent event;
  final AppStrings l10n;

  const _EventTile({required this.event, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(_iconForCategory(event.category)),
      title: Text(l10n.collectorCategoryLabel(event.category)),
      subtitle: Text(
        _subtitleForEvent(event),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        DateTime.fromMillisecondsSinceEpoch(event.timestamp)
            .toLocal()
            .toString()
            .substring(11, 19),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

IconData _iconForCategory(String category) {
  switch (category) {
    case CollectorCategories.sms:
      return Icons.sms_outlined;
    case CollectorCategories.call:
      return Icons.phone_in_talk_outlined;
    case CollectorCategories.callLog:
      return Icons.history;
    case CollectorCategories.clipboard:
      return Icons.content_paste;
    default:
      return Icons.sensors;
  }
}

String _subtitleForEvent(CollectorEvent event) {
  final payload = event.payload;
  switch (event.category) {
    case CollectorCategories.sms:
      return '${payload['address'] ?? ''}: ${payload['body'] ?? ''}';
    case CollectorCategories.call:
    case CollectorCategories.callLog:
      return '${payload['phoneNumber'] ?? ''} ${payload['state'] ?? payload['type'] ?? ''}';
    case CollectorCategories.clipboard:
      return (payload['text'] ?? '').toString();
    default:
      return payload.values.join(' · ');
  }
}
