import 'package:flutter/material.dart';
import '../../app_localizations.dart';
import '../logs/log_page.dart';
import '../transfers/received_files_page.dart';
import 'mobile_settings_content.dart';

/// Keep the standalone route and the main Settings tab on the same UI.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.settings)),
    body: ListView(
      children: [
        MobileSettingsContent(
          onOpenLogs: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const LogPage()),
          ),
          onOpenReceivedFiles: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const ReceivedFilesPage()),
          ),
        ),
      ],
    ),
  );
}
