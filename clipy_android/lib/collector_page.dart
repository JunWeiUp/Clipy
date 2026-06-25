import 'package:flutter/material.dart';
import 'app_localizations.dart';
import 'collector_events_page.dart';
import 'collector_permissions_page.dart';
import 'collector_status_page.dart';

class CollectorPage extends StatefulWidget {
  const CollectorPage({super.key});

  @override
  State<CollectorPage> createState() => _CollectorPageState();
}

class _CollectorPageState extends State<CollectorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.status),
              Tab(text: l10n.recentCollectorEvents),
              Tab(text: l10n.permissions),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              CollectorStatusPage(),
              CollectorEventsPage(),
              CollectorPermissionsPage(),
            ],
          ),
        ),
      ],
    );
  }
}
