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
import 'notification_sync_page.dart';
import 'notification_health_monitor.dart';
import 'log_manager.dart';
import 'models.dart';
import 'app_localizations.dart';
import 'database/app_database.dart';
import 'database/file_transfer_repository.dart';
import 'ui/clipboard_history_list.dart';

Future<void> pickAndSendFileToDevice(BuildContext context, DiscoveredPeer peer) async {
  final l10n = context.l10n;
  final result = await FilePicker.pickFiles(allowMultiple: false);
  if (result == null || result.files.isEmpty) return;
  final path = result.files.single.path;
  if (path == null) return;
  final file = File(path);
  if (!file.existsSync()) return;
  final success = await SyncManager.instance.sendFileToPeer(file, peerId: peer.peerId);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? l10n.fileSentTo(peer.displayName) : l10n.sendFailed)),
    );
  }
}

Future<void> showSendTextToDeviceDialog(
  BuildContext context,
  DiscoveredPeer peer, {
  String? initialText,
}) async {
  final l10n = context.l10n;
  final controller = TextEditingController(text: initialText ?? '');
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sendTextTo(peer.displayName)),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 6,
        minLines: 3,
        decoration: InputDecoration(
          hintText: l10n.enterTextToSend,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.send),
        ),
      ],
    ),
  );
  if (confirmed != true || controller.text.trim().isEmpty) return;
  final success = await SyncManager.instance.sendTextToPeer(
    controller.text,
    peerId: peer.peerId,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? l10n.textSentTo(peer.displayName) : l10n.sendFailed)),
    );
  }
}

class LanDeviceActionTile extends StatelessWidget {
  final DiscoveredPeer peer;

  const LanDeviceActionTile({super.key, required this.peer});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shortId = peer.peerId.length > 8
        ? peer.peerId.substring(0, 8)
        : peer.peerId;
    return ListTile(
      leading: const Icon(Icons.devices),
      title: Text(peer.displayName),
      subtitle: Text(shortId, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'text') {
            showSendTextToDeviceDialog(context, peer);
          } else if (value == 'file') {
            pickAndSendFileToDevice(context, peer);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'text',
            child: ListTile(
              leading: const Icon(Icons.short_text),
              title: Text(l10n.sendText),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'file',
            child: ListTile(
              leading: const Icon(Icons.upload_file),
              title: Text(l10n.sendFile),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      ),
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
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _availablePeers = SyncManager.instance.availablePeers;
    _subscription = SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) {
        setState(() => _availablePeers = peers);
      }
    });
    // On-demand device discovery: this list is the primary place users view
    // the device list, so a single subnet scan is triggered here. Results
    // refresh the list via onPeersChanged. Replaces the old periodic rescan
    // to save power.
    SyncManager.instance.triggerCrossBandDiscovery();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    if (_isRefreshing || !SyncManager.instance.isEnabled) return;
    setState(() => _isRefreshing = true);
    try {
      await SyncManager.instance.refreshDiscovery(
        pruneCache: true,
        scanFullSubnet: true,
      );
      if (mounted) {
        setState(() => _availablePeers = SyncManager.instance.availablePeers);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.devicesRefreshed)),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  List<String> get _authRowIds {
    final online = _availablePeers.map((p) => p.peerId).toSet();
    final auth = SyncManager.instance.authorizedPeerIds.toSet();
    return {...auth, ...online}.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rowIds = _authRowIds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.authorizedDevices,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: SyncManager.instance.isEnabled && !_isRefreshing
                    ? _refreshDevices
                    : null,
                icon: _isRefreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(
                  _isRefreshing ? l10n.refreshingDevices : l10n.refreshDevices,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            l10n.syncTargetsHint,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        if (rowIds.isEmpty)
          ListTile(
            title: Text(l10n.noDevicesFound),
            subtitle: Text(l10n.sameWifiHint),
          )
        else
          ...rowIds.map((peerId) {
            DiscoveredPeer? online;
            for (final p in _availablePeers) {
              if (p.peerId == peerId) {
                online = p;
                break;
              }
            }
            final clipOn = SyncManager.instance.clipboardSyncPeerIds
                .contains(peerId);
            final notifOn = SyncManager.instance.notificationSyncPeerIds
                .contains(peerId);
            final title = online?.displayName ??
                SyncManager.instance.resolvedPeerLabel(peerId);
            final subtitle = online != null
                ? '${online.host}:${online.port}'
                : peerId;
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(title),
                    subtitle: Text(
                      subtitle,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          online != null ? l10n.deviceOnline : l10n.deviceOffline,
                          style: TextStyle(
                            fontSize: 12,
                            color: online != null
                                ? Colors.green[700]
                                : Colors.grey[600],
                          ),
                        ),
                        if (clipOn || notifOn)
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red),
                            tooltip: l10n.delete,
                            onPressed: () async {
                              await SyncManager.instance
                                  .removeAuthorizedPeer(peerId);
                              if (mounted) setState(() {});
                            },
                          ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(l10n.syncClipboardToDevice),
                    value: clipOn,
                    onChanged: (value) async {
                      await SyncManager.instance.setClipboardSyncTarget(
                        peerId,
                        enabled: value,
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(l10n.syncNotificationsToDevice),
                    value: notifOn,
                    onChanged: (value) async {
                      await SyncManager.instance.setNotificationSyncTarget(
                        peerId,
                        enabled: value,
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(height: 1),
                ],
              ),
            );
          }),
      ],
    );
  }
}

/// Manually-configured sync peers (host:port) for cross-band / cross-subnet
/// discovery when mDNS multicast is isolated by the router.
class ManualPeerSection extends StatefulWidget {
  const ManualPeerSection({super.key});

  @override
  State<ManualPeerSection> createState() => _ManualPeerSectionState();
}

class _ManualPeerSectionState extends State<ManualPeerSection> {
  List<String> _manualPeers = [];

  @override
  void initState() {
    super.initState();
    _loadManualPeers();
  }

  Future<void> _loadManualPeers() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _manualPeers = prefs.getStringList('manualSyncPeers') ?? [];
      });
    }
  }

  bool _isValidIPv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false;
    }
    return true;
  }

  Future<void> _addPeer() async {
    final hostController = TextEditingController();
    final portController = TextEditingController(text: '${SyncManager.instance.port}');
    final formKey = GlobalKey<FormState>();

    final entry = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加设备'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: hostController,
                decoration: const InputDecoration(
                  labelText: 'IP 地址',
                  hintText: '192.168.1.20',
                ),
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (!_isValidIPv4(s)) return '请输入合法 IPv4 地址';
                  return null;
                },
              ),
              TextFormField(
                controller: portController,
                decoration: const InputDecoration(labelText: '端口'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final p = int.tryParse(v ?? '');
                  if (p == null || p < 1 || p > 65535) return '端口范围 1-65535';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, '${hostController.text.trim()}:${portController.text.trim()}');
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );

    if (entry == null) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('manualSyncPeers') ?? [];
    if (!list.contains(entry)) {
      list.add(entry);
      await prefs.setStringList('manualSyncPeers', list);
      setState(() => _manualPeers = list);
      SyncManager.instance.triggerCrossBandDiscovery();
    }
  }

  Future<void> _removePeer(String entry) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('manualSyncPeers') ?? [];
    list.remove(entry);
    await prefs.setStringList('manualSyncPeers', list);
    setState(() => _manualPeers = list);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '手动添加设备（跨频段/跨子网）',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: SyncManager.instance.isEnabled ? _addPeer : null,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            '当自动发现失效（如 2.4G/5G 隔离）时，在对端查看 IP 后手动添加。',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        ..._manualPeers.map(
          (entry) => ListTile(
            leading: const Icon(Icons.dns, size: 20),
            title: Text(entry),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _removePeer(entry),
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether core managers finished bootstrap in this isolate.
bool _coreBootstrapped = false;

/// Completes when SyncManager.init (and friends) finish — FGS may call
/// ensureSyncStarted while bootstrap is still in flight.
Completer<void> _coreBootstrapComplete = Completer<void>();

Future<void> _bootstrapCore() async {
  if (_coreBootstrapped) {
    await _coreBootstrapComplete.future;
    return;
  }
  _coreBootstrapped = true;

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
    await NotificationHealthMonitor.instance.startIfNeeded();
  } catch (e) {
    debugPrint('NotificationHealthMonitor init error: $e');
  }

  if (!_coreBootstrapComplete.isCompleted) {
    _coreBootstrapComplete.complete();
  }
}

/// Single entrypoint for UI and for Application-cached engine (FGS / boot).
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register before awaiting bootstrap so sticky-rebuild nudges wait on init.
  const MethodChannel('com.clipyclone.clipy_android/sync_control')
      .setMethodCallHandler((call) async {
    if (call.method == 'ensureSyncStarted') {
      try {
        await _coreBootstrapComplete.future;
        await SyncManager.instance.ensureStartedIfEnabled();
      } catch (e) {
        debugPrint('ensureSyncStarted error: $e');
      }
      return true;
    }
    if (call.method == 'syncTick') {
      // Return next delay ms for FGS adaptive scheduling (busy 30s / idle 90s).
      // Bounded by a hard timeout so a stalled bootstrap or a hung onSyncTick
      // can never wedge the FGS tick chain — we return busyMs and the Kotlin
      // watchdog (SYNC_TICK_WATCHDOG_MS) is the outer backstop regardless.
      const busyMs = 30000;
      try {
        await _coreBootstrapComplete.future
            .timeout(const Duration(seconds: 10));
        final nextMs = await SyncManager.instance.onSyncTick()
            .timeout(const Duration(seconds: 20));
        await NotificationManager.instance.drainNativePendingPosts()
            .timeout(const Duration(seconds: 10));
        return nextMs;
      } catch (e) {
        debugPrint('syncTick error: $e');
        return busyMs;
      }
    }
    if (call.method == 'drainNotificationInbox') {
      try {
        await _coreBootstrapComplete.future;
        await NotificationManager.instance.drainNativePendingPosts();
      } catch (e) {
        debugPrint('drainNotificationInbox error: $e');
      }
      return true;
    }
    return null;
  });

  await _bootstrapCore();

  try {
    await AppLanguageController.instance.init();
  } catch (e) {
    debugPrint('AppLanguageController init error: $e');
  }

  runApp(const MyApp());

  // One-time: sync is enabled but notifications can't surface. Android 13+
  // denies POST_NOTIFICATIONS by default, which hides even the FGS persistent
  // notification — the user then can't tell autostart from a dead service.
  unawaited(_maybeRequestNotificationPermissionOnce());
}

Future<void> _maybeRequestNotificationPermissionOnce() async {
  if (!Platform.isAndroid) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('syncEnabled') != true) return;
    if (prefs.getBool('clipy.notifPermAutoRequested') == true) return;
    // MainActivity registers its method-channel handlers during engine
    // attach; give the first frame a moment.
    await Future<void>.delayed(const Duration(seconds: 2));
    final enabled =
        await NotificationManager.instance.areNotificationsEnabled();
    if (enabled) return;
    // Only stamp after a successful check so a failed probe retries next
    // launch.
    await prefs.setBool('clipy.notifPermAutoRequested', true);
    await NotificationManager.instance.requestNotificationPermission();
  } catch (e) {
    debugPrint('notification permission auto-request error: $e');
  }
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
  List<DiscoveredPeer> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _excludedController = TextEditingController(
      text: ClipboardManager.instance.excludedApps.join('\n'),
    );
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _availableDevices = SyncManager.instance.availablePeers;
    _devicesSubscription = SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) {
        setState(() {
          _availableDevices = peers;
        });
      }
    });
    // On-demand device discovery: this tab shows the device list, so trigger
    // a single subnet scan here. Results refresh via onPeersChanged.
    SyncManager.instance.triggerCrossBandDiscovery();
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
              unawaited(NotificationManager.instance
                  .requestNotificationPermission());
              await SyncManager.instance.start();
            } else {
              await SyncManager.instance.stop();
            }
            setState(() {});
          },
        ),
        if (SyncManager.instance.isEnabled)
          FutureBuilder<List<String>>(
            future: SyncManager.instance.localIPv4Addresses(),
            builder: (context, snapshot) {
              final ips = snapshot.data;
              if (ips == null || ips.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${l10n.myIPAddress}: ${ips.join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              );
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
          ..._availableDevices.map(
            (peer) => LanDeviceActionTile(peer: peer),
          ),
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
                    MaterialPageRoute(builder: (context) => const NotificationSyncPage()),
                  ),
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
      // IndexedStack keeps tab state (scroll position, loaded pages) alive
      // instead of rebuilding and re-querying the DB on every tab switch.
      body: IndexedStack(index: _selectedIndex, children: bodies),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.history), label: l10n.history),
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
  List<DiscoveredPeer> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _nameController = TextEditingController(
      text: SyncManager.instance.displayName,
    );
    _availableDevices = SyncManager.instance.availablePeers;
    _devicesSubscription = SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) {
        setState(() {
          _availableDevices = peers;
        });
      }
    });
    // On-demand device discovery: this page shows the device list, so trigger
    // a single subnet scan here. Results refresh via onPeersChanged.
    SyncManager.instance.triggerCrossBandDiscovery();
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
              unawaited(NotificationManager.instance
                  .requestNotificationPermission());
              await SyncManager.instance.start();
            } else {
              await SyncManager.instance.stop();
            }
            setState(() {});
          },
        ),
        if (SyncManager.instance.isEnabled)
          FutureBuilder<List<String>>(
            future: SyncManager.instance.localIPv4Addresses(),
            builder: (context, snapshot) {
              final ips = snapshot.data;
              if (ips == null || ips.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${l10n.myIPAddress}: ${ips.join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              );
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
          ..._availableDevices.map(
            (peer) => LanDeviceActionTile(peer: peer),
          ),
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
  late TextEditingController _pairingSecretController;
  StreamSubscription? _devicesSubscription;
  List<DiscoveredPeer> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _nameController = TextEditingController(
      text: SyncManager.instance.displayName,
    );
    _pairingSecretController = TextEditingController(
      text: SyncManager.instance.pairingSecret,
    );
    _availableDevices = SyncManager.instance.availablePeers;
    _devicesSubscription = SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) {
        setState(() {
          _availableDevices = peers;
        });
      }
    });
  }

  @override
  void dispose() {
    _portController.dispose();
    _nameController.dispose();
    _pairingSecretController.dispose();
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
          Padding(
            padding:
                const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pairingSecretController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.syncPairingSecret,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final message = l10n.syncPairingSecretUpdated;
                        await SyncManager.instance.updatePairingSecret(
                            _pairingSecretController.text);
                        if (mounted) {
                          messenger
                              .showSnackBar(SnackBar(content: Text(message)));
                        }
                      },
                      child: Text(l10n.save),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.syncPairingSecretHint,
                  style: Theme.of(context).textTheme.bodySmall,
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
                unawaited(NotificationManager.instance
                    .requestNotificationPermission());
                await SyncManager.instance.start();
              } else {
                await SyncManager.instance.stop();
              }
              setState(() {});
            },
          ),
          if (SyncManager.instance.isEnabled)
            FutureBuilder<List<String>>(
              future: SyncManager.instance.localIPv4Addresses(),
              builder: (context, snapshot) {
                final ips = snapshot.data;
                if (ips == null || ips.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${l10n.myIPAddress}: ${ips.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                );
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
            ..._availableDevices.map(
              (peer) => LanDeviceActionTile(peer: peer),
            ),
          const ManualPeerSection(),
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
