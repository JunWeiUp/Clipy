import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'clipboard_manager.dart';
import 'sync_manager.dart';
import 'notification_manager.dart';
import 'collector_manager.dart';
import 'collector_page.dart';
import 'notification_health_monitor.dart';
import 'log_manager.dart';
import 'models.dart';
import 'app_localizations.dart';
import 'database/app_database.dart';
import 'database/file_transfer_repository.dart';
import 'ui/clipboard_history_list.dart';

Future<void> pickAndSendFileToDevice(BuildContext context, String deviceName) async {
  final l10n = context.l10n;
  final result = await FilePicker.pickFiles(allowMultiple: false);
  if (result == null || result.files.isEmpty) return;
  final path = result.files.single.path;
  if (path == null) return;
  final file = File(path);
  if (!file.existsSync()) return;
  await SyncManager.instance.sendFile(file, targetDevice: deviceName);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.fileSentTo(deviceName))),
    );
  }
}

class SyncTargetDeviceList extends StatefulWidget {
  const SyncTargetDeviceList({super.key});

  @override
  State<SyncTargetDeviceList> createState() => _SyncTargetDeviceListState();
}

class _SyncTargetDeviceListState extends State<SyncTargetDeviceList> {
  StreamSubscription? _subscription;
  List<DiscoveredPeer> _availablePeers = [];

  @override
  void initState() {
    super.initState();
    _availablePeers = SyncManager.instance.availablePeers;
    _subscription = SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) {
        setState(() => _availablePeers = peers);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.authorizedDevices,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            l10n.syncTargetsHint,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        if (_availablePeers.isEmpty)
          ListTile(
            title: Text(l10n.noDevicesFound),
            subtitle: Text(l10n.sameWifiHint),
          )
        else
          ..._availablePeers.map((peer) {
            final checked =
                SyncManager.instance.authorizedPeerIds.contains(peer.peerId);
            return CheckboxListTile(
              title: Text(peer.displayName),
              subtitle: Text(peer.peerId, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              value: checked,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (value) async {
                await SyncManager.instance.setSyncTarget(
                  peer.peerId,
                  enabled: value ?? false,
                );
                if (mounted) setState(() {});
              },
            );
          }),
      ],
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await AppDatabase.instance.database;
  } catch (e) {
    debugPrint('AppDatabase init error: $e');
  }
  
  try {
    await ClipboardManager.instance.init();
  } catch (e) {
    debugPrint('ClipboardManager init error: $e');
  }
  
  try {
    await SyncManager.instance.init();
  } catch (e) {
    debugPrint('SyncManager init error: $e');
  }
  
  try {
    await NotificationManager.instance.init();
  } catch (e) {
    debugPrint('NotificationManager init error: $e');
  }

  try {
    await CollectorManager.instance.init();
  } catch (e) {
    debugPrint('CollectorManager init error: $e');
  }

  try {
    await NotificationHealthMonitor.instance.startIfNeeded();
  } catch (e) {
    debugPrint('NotificationHealthMonitor init error: $e');
  }
  
  try {
    await AppLanguageController.instance.init();
  } catch (e) {
    debugPrint('AppLanguageController init error: $e');
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguageController.instance,
      builder: (context, _) {
        final strings = AppLanguageController.instance.strings;
        return MaterialApp(
          title: strings.appTitle,
          locale: AppLanguageController.instance.locale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(
            primarySwatch: Colors.blue,
            useMaterial3: true,
          ),
          home: Platform.isMacOS ? const MacHomePage() : const HomePage(),
        );
      },
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
        children: const [
          MacHistoryTab(),
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

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  static const _pageSize = 100;

  final ScrollController _scrollController = ScrollController();
  final List<String> _logs = [];
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
    LogManager.instance.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    LogManager.instance.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (!mounted) return;
    _logs.clear();
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
    final offset = reset ? 0 : _logs.length;
    final page = await LogManager.instance.fetchPage(
      offset: offset,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      if (reset) _logs.clear();
      _logs.addAll(page.map((r) => r.formatted));
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appLogs),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              await LogManager.instance.clear();
            },
            tooltip: l10n.clearLogs,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () async {
              final count = await LogManager.instance.count();
              final buffer = StringBuffer();
              var offset = 0;
              while (offset < count) {
                final page = await LogManager.instance.fetchPage(
                  offset: offset,
                  limit: 200,
                );
                for (final record in page) {
                  buffer.writeln(record.formatted);
                }
                offset += page.length;
                if (page.isEmpty) break;
              }
              await Clipboard.setData(ClipboardData(text: buffer.toString()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.logsCopied)),
                );
              }
            },
            tooltip: l10n.copyAll,
          ),
        ],
      ),
      body: _logs.isEmpty && !_loading
          ? Center(child: Text(l10n.noLogs))
          : ListView.builder(
              controller: _scrollController,
              reverse: true,
              itemCount: _logs.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _logs.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final log = _logs[index];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                  child: Text(
                    log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
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
  StreamSubscription? _devicesSubscription;
  List<String> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _excludedController = TextEditingController(
      text: ClipboardManager.instance.excludedApps.join('\n'),
    );
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
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
    _excludedController.dispose();
    _portController.dispose();
    _devicesSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final clipboardManager = ClipboardManager.instance;
    final historyLimit = clipboardManager.historyLimit;
    return ListView(
      children: [
        ListTile(
          title: Text(l10n.languageLabel),
          trailing: DropdownButton<AppLanguage>(
            value: AppLanguageController.instance.language,
            onChanged: (language) async {
              if (language == null) return;
              await AppLanguageController.instance.setLanguage(language);
              if (mounted) setState(() {});
            },
            items: AppLanguage.values.map((language) {
              return DropdownMenuItem(
                value: language,
                child: Text(language.displayName),
              );
            }).toList(),
          ),
        ),
        const Divider(),
        ListTile(
          title: Text(l10n.historyLimit),
          subtitle: Text(l10n.keepRecentItems(historyLimit)),
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
            decoration: InputDecoration(
              labelText: l10n.excludedApps,
              border: const OutlineInputBorder(),
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
            child: Text(l10n.saveExcludedApps),
          ),
        ),
        const Divider(),
        SwitchListTile(
          title: Text(l10n.enableLanSync),
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
            decoration: InputDecoration(
              labelText: l10n.syncPort,
              border: const OutlineInputBorder(),
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
        const SyncTargetDeviceList(),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.lanDevices,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
        ),
        if (_availableDevices.isEmpty)
          ListTile(
            title: Text(l10n.noDevicesFound),
            subtitle: Text(l10n.sameWifiHint),
          )
        else
          ..._availableDevices.map((deviceName) {
            return ListTile(
              leading: const Icon(Icons.upload_file),
              title: Text(deviceName),
              subtitle: Text(l10n.sendFile),
              onTap: () => pickAndSendFileToDevice(context, deviceName),
            );
          }),
        const Divider(),
        ListTile(
          title: Text(l10n.about),
          subtitle: const Text('ClipyClone macOS v1.0.0'),
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
  int _selectedIndex = 0;
  StreamSubscription? _fileSubscription;
  StreamSubscription? _progressSubscription;
  final Map<String, FileProgress> _activeTransfers = {};

  @override
  void initState() {
    super.initState();
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
            content: Text(context.l10n.receivedFile(fileName)),
            action: SnackBarAction(
              label: context.l10n.view,
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
                              context.l10n.receiving(progress.fileName),
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
        _MobileSettingsContent(
          onOpenLogs: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const LogPage())),
          onOpenReceivedFiles: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ReceivedFilesPage())),
        ),
        const Divider(),
        SwitchListTile(
          title: Text(context.l10n.collectorEnabled),
          value: CollectorManager.instance.isEnabled,
          onChanged: (value) async {
            await CollectorManager.instance.setEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        SwitchListTile(
          title: Text(context.l10n.collectorClipboardOnly),
          value: ClipboardManager.instance.collectorClipboardOnly,
          onChanged: (value) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('collectorClipboardOnly', value);
            await ClipboardManager.instance.reloadPreferences();
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    final titles = [l10n.clipyHistory, l10n.collector, l10n.settings];
    final bodies = [_buildHistoryTab(), const CollectorPage(), _buildSettingsTab()];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_selectedIndex]),
        actions: _selectedIndex == 0
            ? [
                IconButton(
                  icon: const Icon(Icons.sync),
                  onPressed: () => setState(() => _selectedIndex = 2),
                  tooltip: l10n.authorizedDevices,
                ),
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () => setState(() => _selectedIndex = 1),
                  tooltip: l10n.notificationSync,
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ReceivedFilesPage()),
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
      body: bodies[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.history), label: l10n.history),
          BottomNavigationBarItem(icon: const Icon(Icons.sensors), label: l10n.collector),
          BottomNavigationBarItem(icon: const Icon(Icons.settings), label: l10n.settings),
        ],
      ),
    );
  }
}

class _MobileSettingsContent extends StatefulWidget {
  final VoidCallback onOpenLogs;
  final VoidCallback onOpenReceivedFiles;

  const _MobileSettingsContent({
    required this.onOpenLogs,
    required this.onOpenReceivedFiles,
  });

  @override
  State<_MobileSettingsContent> createState() => _MobileSettingsContentState();
}

class _MobileSettingsContentState extends State<_MobileSettingsContent> {
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
      text: SyncManager.instance.displayName,
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
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(l10n.languageLabel),
          trailing: DropdownButton<AppLanguage>(
            value: AppLanguageController.instance.language,
            onChanged: (language) async {
              if (language == null) return;
              await AppLanguageController.instance.setLanguage(language);
              if (mounted) setState(() {});
            },
            items: AppLanguage.values.map((language) {
              return DropdownMenuItem(
                value: language,
                child: Text(language.displayName),
              );
            }).toList(),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: l10n.deviceNameForSync,
                    border: const OutlineInputBorder(),
                    hintText: l10n.enterDeviceName,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  final newName = _nameController.text.trim();
                  if (newName.isNotEmpty) {
                    final messenger = ScaffoldMessenger.of(context);
                    final message = l10n.deviceNameUpdated;
                    await SyncManager.instance.updateDeviceName(newName);
                    if (mounted) {
                      messenger.showSnackBar(SnackBar(content: Text(message)));
                    }
                  }
                },
                child: Text(l10n.save),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            l10n.syncLocalNameHintFor(
              SyncManager.instance.displayName,
              SyncManager.instance.peerId.length > 8
                  ? SyncManager.instance.peerId.substring(0, 8)
                  : SyncManager.instance.peerId,
            ),
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        const Divider(),
        SwitchListTile(
          title: Text(l10n.enableLanSync),
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
            decoration: InputDecoration(
              labelText: l10n.syncPort,
              border: const OutlineInputBorder(),
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
        const SyncTargetDeviceList(),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.lanDevices,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
        ),
        if (_availableDevices.isEmpty)
          ListTile(
            title: Text(l10n.noDevicesFound),
            subtitle: Text(l10n.sameWifiHint),
          )
        else
          ..._availableDevices.map((deviceName) {
            return ListTile(
              leading: const Icon(Icons.upload_file),
              title: Text(deviceName),
              subtitle: Text(l10n.sendFile),
              onTap: () => pickAndSendFileToDevice(context, deviceName),
            );
          }),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: Text(l10n.receivedFiles),
          onTap: widget.onOpenReceivedFiles,
        ),
        ListTile(
          leading: const Icon(Icons.list_alt),
          title: Text(l10n.viewLogs),
          subtitle: Text(l10n.appRuntimeLogs),
          onTap: widget.onOpenLogs,
        ),
        const Divider(),
        ListTile(
          title: Text(l10n.about),
          subtitle: Text('ClipyClone ${Platform.isIOS ? 'iOS' : 'Android'} v1.0.0'),
        ),
      ],
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
      text: SyncManager.instance.displayName,
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
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          ListTile(
            title: Text(l10n.languageLabel),
            trailing: DropdownButton<AppLanguage>(
              value: AppLanguageController.instance.language,
              onChanged: (language) async {
                if (language == null) return;
                await AppLanguageController.instance.setLanguage(language);
                if (mounted) setState(() {});
              },
              items: AppLanguage.values.map((language) {
                return DropdownMenuItem(
                  value: language,
                  child: Text(language.displayName),
                );
              }).toList(),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: l10n.deviceNameForSync,
                      border: const OutlineInputBorder(),
                      hintText: l10n.enterDeviceName,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    final newName = _nameController.text.trim();
                    if (newName.isNotEmpty) {
                      final messenger = ScaffoldMessenger.of(context);
                      final message = l10n.deviceNameUpdated;
                      await SyncManager.instance.updateDeviceName(newName);
                      if (mounted) {
                        messenger.showSnackBar(SnackBar(content: Text(message)));
                      }
                    }
                  },
                  child: Text(l10n.save),
                ),
              ],
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: Text(l10n.enableLanSync),
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
              decoration: InputDecoration(
                labelText: l10n.syncPort,
                border: const OutlineInputBorder(),
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
          const SyncTargetDeviceList(),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.lanDevices,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
            ),
          ),
          if (_availableDevices.isEmpty)
            ListTile(
              title: Text(l10n.noDevicesFound),
              subtitle: Text(l10n.sameWifiHint),
            )
          else
            ..._availableDevices.map((deviceName) {
              return ListTile(
                leading: const Icon(Icons.upload_file),
                title: Text(deviceName),
                subtitle: Text(l10n.sendFile),
                onTap: () => pickAndSendFileToDevice(context, deviceName),
              );
            }),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: Text(l10n.viewLogs),
            subtitle: Text(l10n.appRuntimeLogs),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogPage()),
              );
            },
          ),
          const Divider(),
          ListTile(
            title: Text(l10n.about),
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
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  final List<FileTransferRecord> _files = [];
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    final offset = reset ? 0 : _files.length;
    final page = await FileTransferRepository.instance.fetchPage(
      offset: offset,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      if (reset) _files.clear();
      _files.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _deleteFile(FileTransferRecord file) async {
    final ioFile = File(file.filePath);
    if (await ioFile.exists()) {
      await ioFile.delete();
    }
    await FileTransferRepository.instance.deleteById(file.id);
    setState(() {
      _files.removeWhere((f) => f.id == file.id);
    });
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
          SnackBar(content: Text(context.l10n.couldNotOpenFolder(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.receivedFiles)),
      body: _files.isEmpty && !_loading
          ? Center(child: Text(l10n.noFilesReceived))
          : ListView.builder(
              controller: _scrollController,
              itemCount: _files.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _files.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final file = _files[index];
                final date =
                    DateTime.fromMillisecondsSinceEpoch(file.createdAt);
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file.fileName),
                  subtitle: Text(
                    '${_formatSize(file.fileSize)} • ${l10n.fromSender(file.senderName)}\n${date.toString().split('.')[0]}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteFile(file),
                  ),
                  onTap: () => _openFolder(file.filePath),
                );
              },
            ),
    );
  }
}
