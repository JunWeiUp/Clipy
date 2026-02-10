import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'clipboard_manager.dart';
import 'sync_manager.dart';
import 'log_manager.dart';
import 'models.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ClipboardManager.instance.init();
  await SnippetManager.instance.init();
  await SyncManager.instance.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipyClone',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: Platform.isMacOS ? const MacHomePage() : const HomePage(),
    );
  }
}

class MacHomePage extends StatefulWidget {
  const MacHomePage({super.key});

  @override
  State<MacHomePage> createState() => _MacHomePageState();
}

class _MacHomePageState extends State<MacHomePage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    ClipboardManager.instance.onHistoryChanged = _handleDataChanged;
    SnippetManager.instance.onSnippetsChanged = _handleDataChanged;
  }

  @override
  void dispose() {
    ClipboardManager.instance.onHistoryChanged = null;
    SnippetManager.instance.onSnippetsChanged = null;
    _tabController.dispose();
    super.dispose();
  }

  void _handleDataChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipyClone'),
        actions: [
          IconButton(
            icon: const Icon(Icons.snippet_folder_outlined),
            onPressed: () => _switchTab(1),
            tooltip: 'Snippets',
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: () => _switchTab(2),
            tooltip: 'Preferences',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => ClipboardManager.instance.clearHistory(),
            tooltip: 'Clear History',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'History'),
            Tab(text: 'Snippets'),
            Tab(text: 'Preferences'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          MacHistoryTab(),
          MacSnippetsTab(),
          MacSettingsTab(),
        ],
      ),
    );
  }

  void _switchTab(int index) {
    if (index >= 0 && index < _tabController.length) {
      _tabController.animateTo(index);
    }
  }
}

class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => LogManager.instance.clear(),
            tooltip: 'Clear Logs',
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final allLogs = LogManager.instance.logs.join('\n');
              Clipboard.setData(ClipboardData(text: allLogs));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied to clipboard')),
              );
            },
            tooltip: 'Copy All',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: LogManager.instance,
        builder: (context, _) {
          final logs = LogManager.instance.logs;
          if (logs.isEmpty) {
            return const Center(child: Text('No logs recorded yet.'));
          }
          return ListView.builder(
            reverse: true,
            itemCount: logs.length,
            itemBuilder: (context, index) {
              // Show newest logs first
              final log = logs[logs.length - 1 - index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                child: Text(
                  log,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class MacHistoryTab extends StatelessWidget {
  const MacHistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final history = ClipboardManager.instance.history;
    if (history.isEmpty) {
      return const Center(child: Text('No clipboard history yet'));
    }

    final sections = <Widget>[];
    for (var i = 0; i < history.length; i += 10) {
      final end = (i + 10) > history.length ? history.length : (i + 10);
      final group = history.sublist(i, end);
      sections.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'History ${i + 1}–$end',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      );
      for (final entry in group) {
        sections.add(
          ListTile(
            leading: _iconForItem(entry.item),
            title: Text(
              entry.item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${entry.sourceApp ?? 'Unknown'} • ${entry.date.toString().split('.')[0]}'),
            onTap: () {
              ClipboardManager.instance.copyToClipboard(entry.item);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
          ),
        );
      }
    }

    return ListView(children: sections);
  }

  Widget _iconForItem(HistoryItem item) {
    switch (item.type) {
      case 'image':
        return const Icon(Icons.image_outlined);
      case 'rtf':
        return const Icon(Icons.description_outlined);
      case 'pdf':
        return const Icon(Icons.picture_as_pdf_outlined);
      case 'fileURL':
        return const Icon(Icons.insert_drive_file_outlined);
      default:
        return const Icon(Icons.short_text);
    }
  }
}

class MacSnippetsTab extends StatelessWidget {
  const MacSnippetsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = SnippetManager.instance;
    final folders = manager.folders;
    if (folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () => _showAddFolderDialog(context),
              child: const Text('Add Snippet Folder'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _showImportXmlDialog(context),
              child: const Text('Import XML'),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Snippet Folders',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton(
                onPressed: () => _showImportXmlDialog(context),
                child: const Text('Import XML'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _showAddFolderDialog(context),
                child: const Text('Add Folder'),
              ),
            ],
          ),
        ),
        ...folders.map((folder) {
          return ExpansionTile(
            title: Text(folder.title),
            leading: Icon(folder.isEnabled ? Icons.folder_outlined : Icons.folder_off_outlined),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditFolderDialog(context, folder);
                } else if (value == 'toggle') {
                  manager.toggleFolderEnabled(folder.id, !folder.isEnabled);
                } else if (value == 'delete') {
                  _showDeleteFolderDialog(context, folder);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(folder.isEnabled ? 'Disable' : 'Enable'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
            children: [
              ...folder.snippets.map((snippet) {
                return ListTile(
                  title: Text(snippet.title),
                  subtitle: Text(
                    snippet.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: folder.isEnabled
                      ? () {
                          ClipboardManager.instance.copyToClipboard(
                            HistoryItem(type: 'text', value: snippet.content),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Snippet copied to clipboard')),
                          );
                        }
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _showEditSnippetDialog(context, folder, snippet),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _showDeleteSnippetDialog(context, folder, snippet),
                      ),
                    ],
                  ),
                );
              }),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add Snippet'),
                onTap: () => _showAddSnippetDialog(context, folder),
              ),
            ],
          );
        }),
      ],
    );
  }

  Future<void> _showAddFolderDialog(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Folder'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Folder Name'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    final title = result ?? '';
    if (title.isNotEmpty) {
      await SnippetManager.instance.addFolder(title);
    }
  }

  Future<void> _showImportXmlDialog(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import Snippets XML'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: controller,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Paste XML content',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
    final xml = result ?? '';
    if (xml.isNotEmpty) {
      await SnippetManager.instance.importFromXmlString(xml);
    }
  }

  Future<void> _showEditFolderDialog(BuildContext context, SnippetFolder folder) async {
    final controller = TextEditingController(text: folder.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Folder'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Folder Name'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    final title = result ?? '';
    if (title.isNotEmpty) {
      await SnippetManager.instance.updateFolderTitle(folder.id, title);
    }
  }

  Future<void> _showDeleteFolderDialog(BuildContext context, SnippetFolder folder) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Folder'),
          content: Text('Delete "${folder.title}" and all snippets?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.deleteFolder(folder.id);
    }
  }

  Future<void> _showAddSnippetDialog(BuildContext context, SnippetFolder folder) async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Snippet'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: const InputDecoration(labelText: 'Content'),
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.addSnippet(
        folder.id,
        titleController.text.trim(),
        contentController.text.trim(),
      );
    }
  }

  Future<void> _showEditSnippetDialog(
    BuildContext context,
    SnippetFolder folder,
    Snippet snippet,
  ) async {
    final titleController = TextEditingController(text: snippet.title);
    final contentController = TextEditingController(text: snippet.content);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Snippet'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: const InputDecoration(labelText: 'Content'),
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.updateSnippet(
        folder.id,
        snippet.id,
        titleController.text.trim(),
        contentController.text.trim(),
      );
    }
  }

  Future<void> _showDeleteSnippetDialog(
    BuildContext context,
    SnippetFolder folder,
    Snippet snippet,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Snippet'),
          content: Text('Delete "${snippet.title}"?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.deleteSnippet(folder.id, snippet.id);
    }
  }
}

class MacSettingsTab extends StatefulWidget {
  const MacSettingsTab({super.key});

  @override
  State<MacSettingsTab> createState() => _MacSettingsTabState();
}

class _MacSettingsTabState extends State<MacSettingsTab> {
  late TextEditingController _excludedController;
  late TextEditingController _portController;
  late TextEditingController _devicesController;

  @override
  void initState() {
    super.initState();
    _excludedController = TextEditingController(
      text: ClipboardManager.instance.excludedApps.join('\n'),
    );
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _devicesController = TextEditingController(
      text: SyncManager.instance.authorizedDevices.join(', '),
    );
  }

  @override
  void dispose() {
    _excludedController.dispose();
    _portController.dispose();
    _devicesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clipboardManager = ClipboardManager.instance;
    final historyLimit = clipboardManager.historyLimit;
    return ListView(
      children: [
        ListTile(
          title: const Text('History Limit'),
          subtitle: Text('Keep the most recent $historyLimit items'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: historyLimit > 1
                    ? () async {
                        await clipboardManager.updateHistoryLimit(historyLimit - 1);
                        setState(() {});
                      }
                    : null,
              ),
              Text(historyLimit.toString()),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: historyLimit < 200
                    ? () async {
                        await clipboardManager.updateHistoryLimit(historyLimit + 1);
                        setState(() {});
                      }
                    : null,
              ),
            ],
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _excludedController,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'Excluded Apps (bundle IDs, one per line)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: ElevatedButton(
            onPressed: () async {
              final apps = _excludedController.text
                  .split(RegExp(r'[\n,]'))
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList();
              await clipboardManager.updateExcludedApps(apps);
            },
            child: const Text('Save Excluded Apps'),
          ),
        ),
        const Divider(),
        SwitchListTile(
          title: const Text('Enable LAN Sync'),
          value: SyncManager.instance.isEnabled,
          onChanged: (value) async {
            SyncManager.instance.isEnabled = value;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('syncEnabled', value);
            if (value) {
              await SyncManager.instance.start();
            } else {
              await SyncManager.instance.stop();
            }
            setState(() {});
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _portController,
            decoration: const InputDecoration(
              labelText: 'Sync Port',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) async {
              final port = int.tryParse(value);
              if (port != null) {
                SyncManager.instance.port = port;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('syncPort', port);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _devicesController,
            decoration: const InputDecoration(
              labelText: 'Authorized Devices (comma separated)',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) async {
              final devices = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              SyncManager.instance.authorizedDevices = devices;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setStringList('authorizedDevices', devices);
            },
          ),
        ),
        const Divider(),
        const ListTile(
          title: Text('About'),
          subtitle: Text('ClipyClone macOS v1.0.0'),
        ),
      ],
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription? _fileSubscription;
  StreamSubscription? _progressSubscription;
  final Map<String, FileProgress> _activeTransfers = {};

  @override
  void initState() {
    super.initState();
    ClipboardManager.instance.onHistoryChanged = () {
      if (mounted) setState(() {});
    };
    
    _progressSubscription = SyncManager.instance.onFileProgress.listen((progress) {
      if (mounted) {
        setState(() {
          if (progress.isCompleted) {
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
            content: Text('Received file: $fileName'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ReceivedFilesPage()),
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

  static const _channel = MethodChannel('com.clipyclone.clipy_android/open_folder');

  Future<void> _openFolder(String filePath) async {
    try {
      await _channel.invokeMethod('openFolder', {'path': filePath});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open folder: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ClipboardManager.instance.history;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipy History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ReceivedFilesPage()),
            ),
            tooltip: 'Received Files',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => ClipboardManager.instance.clearHistory(),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const LogPage()),
            ),
            tooltip: 'View Logs',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_activeTransfers.isNotEmpty)
            Container(
              color: Colors.blue.withOpacity(0.1),
              child: Column(
                children: _activeTransfers.values.map((progress) {
                  return Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.downloading, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Receiving: ${progress.fileName}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
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
            child: ListView.builder(
              itemCount: history.length,
              itemBuilder: (context, index) {
                final entry = history[index];
                final isFile = entry.item.type == 'fileURL';
                return ListTile(
                  leading: Icon(
                    isFile ? Icons.insert_drive_file_outlined : Icons.short_text,
                    color: isFile ? Colors.blue : null,
                  ),
                  title: Text(
                    entry.item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${entry.sourceApp ?? 'Unknown'} • ${entry.date.toString().split('.')[0]}'),
                  onTap: () {
                    if (isFile) {
                      _openFolder(entry.item.value.toString());
                    } else {
                      ClipboardManager.instance.copyToClipboard(entry.item);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied to clipboard')),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _portController;
  late TextEditingController _nameController;
  StreamSubscription? _devicesSubscription;
  List<String> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _nameController = TextEditingController(
      text: SyncManager.instance.deviceId,
    );
    _availableDevices = SyncManager.instance.availableDeviceNames;
    _devicesSubscription = SyncManager.instance.onDevicesChanged.listen((devices) {
      if (mounted) {
        setState(() {
          _availableDevices = devices;
        });
      }
    });
  }

  @override
  void dispose() {
    _portController.dispose();
    _nameController.dispose();
    _devicesSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Device Name (for Sync)',
                      border: OutlineInputBorder(),
                      hintText: 'Enter device name',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    final newName = _nameController.text.trim();
                    if (newName.isNotEmpty) {
                      await SyncManager.instance.updateDeviceName(newName);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Device name updated and sync restarted')),
                        );
                      }
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Enable LAN Sync'),
            value: SyncManager.instance.isEnabled,
            onChanged: (value) async {
              SyncManager.instance.isEnabled = value;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('syncEnabled', value);
              if (value) {
                await SyncManager.instance.start();
              } else {
                await SyncManager.instance.stop();
              }
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Sync Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onChanged: (value) async {
                final port = int.tryParse(value);
                if (port != null) {
                  SyncManager.instance.port = port;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt('syncPort', port);
                }
              },
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Authorized Devices',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
            ),
          ),
          if (_availableDevices.isEmpty)
            const ListTile(
              title: Text('No devices found'),
              subtitle: Text('Ensure other devices are on the same WiFi'),
            )
          else
            ..._availableDevices.map((deviceName) {
              final isAuthorized = SyncManager.instance.authorizedDevices.contains(deviceName);
              return CheckboxListTile(
                title: Text(deviceName),
                value: isAuthorized,
                onChanged: (bool? value) async {
                  final devices = List<String>.from(SyncManager.instance.authorizedDevices);
                  if (value == true) {
                    if (!devices.contains(deviceName)) devices.add(deviceName);
                  } else {
                    devices.remove(deviceName);
                  }
                  SyncManager.instance.authorizedDevices = devices;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setStringList('authorizedDevices', devices);
                  setState(() {});
                },
              );
            }),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('View Logs'),
            subtitle: const Text('App runtime logs for troubleshooting'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogPage()),
              );
            },
          ),
          const Divider(),
          ListTile(
            title: const Text('About'),
            subtitle: Text('ClipyClone ${Platform.isIOS ? 'iOS' : 'Android'} v1.0.0'),
          ),
        ],
      ),
    );
  }
}

class ReceivedFilesPage extends StatefulWidget {
  const ReceivedFilesPage({super.key});

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  List<dynamic> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getString('fileHistory') ?? '[]';
    if (mounted) {
      setState(() {
        _files = jsonDecode(historyJson);
      });
    }
  }

  Future<void> _deleteFile(int index) async {
    final file = _files[index];
    final ioFile = File(file['filePath']);
    if (await ioFile.exists()) {
      await ioFile.delete();
    }

    _files.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fileHistory', jsonEncode(_files));
    setState(() {});
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static const _channel = MethodChannel('com.clipyclone.clipy_android/open_folder');

  Future<void> _openFolder(String filePath) async {
    try {
      await _channel.invokeMethod('openFolder', {'path': filePath});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open folder: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Received Files')),
      body: _files.isEmpty
          ? const Center(child: Text('No files received yet'))
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index];
                final date = DateTime.parse(file['timestamp']);
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file['fileName']),
                  subtitle: Text(
                    '${_formatSize(file['fileSize'])} • From: ${file['senderName']}\n${date.toString().split('.')[0]}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteFile(index),
                  ),
                  onTap: () => _openFolder(file['filePath']),
                );
              },
            ),
    );
  }
}
