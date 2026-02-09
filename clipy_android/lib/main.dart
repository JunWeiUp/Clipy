import 'dart:io';
import 'package:flutter/material.dart';
import 'clipboard_manager.dart';
import 'models.dart';
import 'sync_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SyncManager.instance.init();
  await ClipboardManager.instance.init();
  await SnippetManager.instance.init();
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
    SyncManager.instance.addListener(_handleDataChanged);
  }

  @override
  void dispose() {
    SyncManager.instance.removeListener(_handleDataChanged);
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
    final syncManager = SyncManager.instance;
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
            icon: Icon(syncManager.isSyncEnabled ? Icons.wifi : Icons.wifi_off),
            onPressed: () async {
              await syncManager.setSyncEnabled(!syncManager.isSyncEnabled);
              setState(() {});
            },
            tooltip: syncManager.isSyncEnabled ? 'Disable Sync' : 'Enable Sync',
          ),
          IconButton(
            icon: const Icon(Icons.devices_other),
            onPressed: () => _showDevicesDialog(context),
            tooltip: 'Sync Devices',
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

  Future<void> _showDevicesDialog(BuildContext context) async {
    final syncManager = SyncManager.instance;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Sync Devices'),
          content: SizedBox(
            width: 420,
            child: StatefulBuilder(
              builder: (context, setDialogState) {
                final devices = syncManager.discoveredDevices.toList()..sort();
                if (!syncManager.isSyncEnabled) {
                  return const Text('Sync is disabled.');
                }
                if (devices.isEmpty) {
                  return const Text('Searching for devices...');
                }
                return ListView(
                  shrinkWrap: true,
                  children: devices.map((device) {
                    final isAllowed = syncManager.allowedDevices.contains(device);
                    final lastSeen = syncManager.deviceLastSeen[device];
                    return CheckboxListTile(
                      title: Text(device),
                      subtitle: lastSeen != null
                          ? Text('Last seen ${lastSeen.toString().split('.')[0]}')
                          : null,
                      value: isAllowed,
                      onChanged: (value) async {
                        await syncManager.toggleDeviceAllowance(device);
                        setDialogState(() {});
                        setState(() {});
                      },
                    );
                  }).toList(),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
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
  late TextEditingController _nameController;
  late TextEditingController _keyController;
  late TextEditingController _excludedController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: SyncManager.instance.deviceName);
    _keyController = TextEditingController(text: SyncManager.instance.syncKey);
    _excludedController = TextEditingController(
      text: ClipboardManager.instance.excludedApps.join('\n'),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _keyController.dispose();
    _excludedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final syncManager = SyncManager.instance;
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
          subtitle: const Text('Sync clipboard and snippets with devices on your local network'),
          value: syncManager.isSyncEnabled,
          onChanged: (value) {
            syncManager.setSyncEnabled(value);
            setState(() {});
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Device Name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              syncManager.setDeviceName(value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _keyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Sync Key',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              syncManager.setSyncKey(value);
            },
          ),
        ),
        if (syncManager.isSyncEnabled) ...[
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'Discovered Devices',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          if (syncManager.discoveredDevices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Text('Searching for devices...', style: TextStyle(color: Colors.grey)),
            )
          else
            ...syncManager.discoveredDevices.map((device) {
              final isAllowed = syncManager.allowedDevices.contains(device);
              final lastSeen = syncManager.deviceLastSeen[device];
              return CheckboxListTile(
                title: Text('💻 $device'),
                subtitle: lastSeen != null
                    ? Text('Last seen ${lastSeen.toString().split('.')[0]}')
                    : null,
                value: isAllowed,
                onChanged: (value) {
                  syncManager.toggleDeviceAllowance(device);
                  setState(() {});
                },
              );
            }),
        ],
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
  @override
  void initState() {
    super.initState();
    ClipboardManager.instance.onHistoryChanged = () {
      setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) {
    final history = ClipboardManager.instance.history;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipy History'),
        actions: [
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
        ],
      ),
      body: ListView.builder(
        itemCount: history.length,
        itemBuilder: (context, index) {
          final entry = history[index];
          return ListTile(
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
          );
        },
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
  late TextEditingController _nameController;
  late TextEditingController _keyController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: SyncManager.instance.deviceName);
    _keyController = TextEditingController(text: SyncManager.instance.syncKey);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncManager.instance,
      builder: (context, _) {
        final syncManager = SyncManager.instance;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            children: [
              SwitchListTile(
                title: const Text('Enable LAN Sync'),
                subtitle: const Text('Sync clipboard with other devices on your local network'),
                value: syncManager.isSyncEnabled,
                onChanged: (value) {
                  syncManager.setSyncEnabled(value);
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Device Name',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) {
                    syncManager.setDeviceName(value);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: TextField(
                  controller: _keyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Sync Key',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) {
                    syncManager.setSyncKey(value);
                  },
                ),
              ),
              if (syncManager.isSyncEnabled) ...[
                const Divider(),
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Discovered Devices',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                if (syncManager.discoveredDevices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text('Searching for devices...', style: TextStyle(color: Colors.grey)),
                  )
                else
                  ...syncManager.discoveredDevices.map((device) {
                    final isAllowed = syncManager.allowedDevices.contains(device);
                    return CheckboxListTile(
                      title: Text('📱 $device'),
                      value: isAllowed,
                      onChanged: (value) {
                        syncManager.toggleDeviceAllowance(device);
                      },
                    );
                  }),
              ],
              const Divider(),
              const ListTile(
                title: Text('About'),
                subtitle: Text('ClipyClone Android v1.0.0'),
              ),
            ],
          ),
        );
      },
    );
  }
}
