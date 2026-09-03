import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipy_android/clipboard_manager.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/notification_sync_page.dart';
import 'package:clipy_android/models.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/ui/clipboard_history_list.dart';
import 'package:clipy_android/features/transfers/received_files_page.dart';
import 'package:clipy_android/features/logs/log_page.dart';
import 'package:clipy_android/features/settings/mobile_settings_content.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  StreamSubscription? _fileSubscription;
  StreamSubscription? _progressSubscription;
  final Map<String, FileProgress> _activeTransfers = {};

  @override
  void initState() {
    super.initState();
    _progressSubscription = SyncManager.instance.onFileProgress.listen((
      progress,
    ) {
      if (mounted) {
        setState(() {
          if (progress.isCompleted || progress.isFailed) {
            _activeTransfers.remove(progress.fileId);
          } else {
            _activeTransfers[progress.fileId] = progress;
          }
        });
      }
    });

    _fileSubscription = SyncManager.instance.onFileReceived.listen((fileName) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.receivedFile(fileName)),
            action: SnackBarAction(
              label: context.l10n.view,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ReceivedFilesPage(),
                ),
              ),
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _fileSubscription?.cancel();
    _progressSubscription?.cancel();
    super.dispose();
  }

  static const _channel = MethodChannel(
    'com.clipyclone.clipy_android/open_folder',
  );

  Future<void> _openFolder(String filePath) async {
    try {
      await _channel.invokeMethod('openFolder', {'path': filePath});
    } on PlatformException catch (e) {
      if (!mounted) return;
      final message = e.code == 'FILE_NOT_FOUND'
          ? context.l10n.fileNotFound
          : e.code == 'NO_ACTIVITY'
          ? context.l10n.noFileManager
          : context.l10n.couldNotOpenFolder(e.code);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotOpenFolder(e))),
        );
      }
    }
  }

  Widget _buildHistoryTab() {
    return Column(
      children: [
        if (_activeTransfers.isNotEmpty)
          Container(
            color: Colors.blue.withValues(alpha: 0.1),
            child: Column(
              children: _activeTransfers.values.map((progress) {
                final transferLabel = progress.isOutgoing
                    ? context.l10n.sending(progress.fileName)
                    : context.l10n.receiving(progress.fileName);
                return Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            progress.isOutgoing
                                ? Icons.upload_file
                                : Icons.downloading,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              transferLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${(progress.progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: progress.progress),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        Expanded(
          child: PaginatedClipboardHistoryList(
            onFileTap: (HistoryEntry entry) =>
                _openFolder(entry.item.value.toString()),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      children: [
        MobileSettingsContent(
          onOpenLogs: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const LogPage()),
          ),
          onOpenReceivedFiles: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ReceivedFilesPage()),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    final titles = [l10n.clipyHistory, l10n.settings];
    final bodies = [_buildHistoryTab(), _buildSettingsTab()];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_selectedIndex]),
        actions: _selectedIndex == 0
            ? [
                IconButton(
                  icon: const Icon(Icons.sync),
                  onPressed: () => setState(() => _selectedIndex = 1),
                  tooltip: l10n.authorizedDevices,
                ),
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const NotificationSyncPage(),
                    ),
                  ),
                  tooltip: l10n.notificationSync,
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ReceivedFilesPage(),
                    ),
                  ),
                  tooltip: l10n.receivedFiles,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ClipboardManager.instance.clearHistory();
                  },
                  tooltip: l10n.clearHistory,
                ),
                IconButton(
                  icon: const Icon(Icons.list_alt),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const LogPage()),
                  ),
                  tooltip: l10n.viewLogs,
                ),
              ]
            : null,
      ),
      // IndexedStack keeps tab state (scroll position, loaded pages) alive
      // instead of rebuilding and re-querying the DB on every tab switch.
      body: IndexedStack(index: _selectedIndex, children: bodies),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.history),
            label: l10n.history,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.settings),
            label: l10n.settings,
          ),
        ],
      ),
    );
  }
}
