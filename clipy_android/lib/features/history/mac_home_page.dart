import 'package:flutter/material.dart';
import 'package:clipy_android/clipboard_manager.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/ui/clipboard_history_list.dart';
import 'package:clipy_android/features/settings/mac_settings_tab.dart';

class MacHomePage extends StatefulWidget {
  const MacHomePage({super.key});

  @override
  State<MacHomePage> createState() => _MacHomePageState();
}

class _MacHomePageState extends State<MacHomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: () => _switchTab(1),
            tooltip: l10n.preferences,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await ClipboardManager.instance.clearHistory();
            },
            tooltip: l10n.clearHistory,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.history),
            Tab(text: l10n.preferences),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [MacHistoryTab(), MacSettingsTab()],
      ),
    );
  }

  void _switchTab(int index) {
    if (index >= 0 && index < _tabController.length) {
      _tabController.animateTo(index);
    }
  }
}
