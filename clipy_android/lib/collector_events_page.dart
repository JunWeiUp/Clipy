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
  StreamSubscription? _eventsSubscription;

  @override
  void initState() {
    super.initState();
    _eventsSubscription =
        CollectorManager.instance.onEventsChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final events = CollectorManager.instance.recentEvents;

    if (events.isEmpty) {
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: events.length,
      itemBuilder: (context, index) {
        return _EventTile(event: events[index], l10n: l10n);
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
        maxLines: 3,
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
    case CollectorCategories.notification:
      return Icons.notifications_outlined;
    case CollectorCategories.sms:
      return Icons.sms_outlined;
    case CollectorCategories.call:
      return Icons.phone_in_talk_outlined;
    case CollectorCategories.callLog:
      return Icons.history;
    case CollectorCategories.clipboard:
      return Icons.content_paste;
    case CollectorCategories.location:
      return Icons.location_on_outlined;
    case CollectorCategories.system:
      return Icons.battery_charging_full_outlined;
    default:
      return Icons.sensors;
  }
}

String _subtitleForEvent(CollectorEvent event) {
  final payload = event.payload;
  switch (event.category) {
    case CollectorCategories.notification:
      return '${payload['appName'] ?? ''}: ${payload['title'] ?? ''}';
    case CollectorCategories.sms:
      return '${payload['address'] ?? ''}: ${payload['body'] ?? ''}';
    case CollectorCategories.call:
    case CollectorCategories.callLog:
      return '${payload['phoneNumber'] ?? ''} ${payload['state'] ?? payload['type'] ?? ''}';
    case CollectorCategories.clipboard:
      return (payload['text'] ?? '').toString();
    case CollectorCategories.location:
      return '${payload['latitude']}, ${payload['longitude']}';
    case CollectorCategories.system:
      return '${payload['batteryLevel']}% ${payload['networkType']}';
    default:
      return payload.values.join(' · ');
  }
}
