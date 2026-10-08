import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import '../../clipboard_manager.dart';
import '../../sync_manager.dart';
import '../../notification_sync_page.dart';
import 'remote_notifications_page.dart';
import '../../app_localizations.dart';
import '../../ui/clipboard_history_list.dart';
import '../../ui/app_components.dart';
import '../../ui/active_page_stack.dart';
import '../../ui/scroll_collapsing_header.dart';
import '../devices/devices_page.dart';
import '../transfers/received_files_page.dart';
import '../transfers/incoming_share.dart';
import '../transfers/shared_files_page.dart';
import '../logs/log_page.dart';
import '../settings/mobile_settings_content.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  IncomingShareCoordinator? _incomingShares;
  StreamSubscription? _sharePeersSubscription;
  int _selectedIndex = 0;
  final _visited = <int>{0};
  late final _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  StreamSubscription? _fileSubscription;
  StreamSubscription? _progressSubscription;
  final Map<String, FileProgress> _activeTransfers = {};
  bool _clearing = false;
  bool _capturingScreenshot = false;
  static const _screenshotChannel = MethodChannel(
    'com.clipyclone.clipy_android/screenshot',
  );

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.addObserver(this);
      _incomingShares = IncomingShareCoordinator(
        present: (share) async {
          if (!mounted) return;
          await Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => SharedFilesPage(share: share)),
          );
        },
        onError: () {
          if (mounted) {
            showClipyMessage(context, context.l10n.shareImportFailed);
          }
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _incomingShares?.start();
      });
      if (Platform.isIOS) {
        _sharePeersSubscription = SyncManager.instance.onPeersChanged.listen(
          (_) => _updateShareConfiguration(),
        );
        unawaited(_updateShareConfiguration());
      }
    }
    _progressSubscription = SyncManager.instance.onFileProgress.listen((
      progress,
    ) {
      if (!mounted) return;
      setState(() {
        if (progress.isCompleted || progress.isFailed) {
          _activeTransfers.remove(progress.fileId);
        } else {
          _activeTransfers[progress.fileId] = progress;
        }
      });
    });
    _fileSubscription = SyncManager.instance.onFileReceived.listen((fileName) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.receivedFile(fileName)),
          action: SnackBarAction(
            label: context.l10n.view,
            onPressed: _openFiles,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingShares?.dispose();
    _sharePeersSubscription?.cancel();
    _fileSubscription?.cancel();
    _progressSubscription?.cancel();
    _transition.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _incomingShares?.drain();
    if (state == AppLifecycleState.resumed && Platform.isIOS) {
      unawaited(_updateShareConfiguration());
    }
  }

  Future<void> _updateShareConfiguration() async {
    try {
      final config = await SyncManager.instance.shareExtensionConfiguration();
      if (!mounted) return;
      config['language'] = AppLanguageController.instance.locale.languageCode;
      await const MethodChannel(
        'com.clipyclone.clipy_android/incoming_share',
      ).invokeMethod<void>('configure', config);
    } catch (_) {
      // The extension can still discover peers itself; never block normal app startup.
    }
  }

  void _select(int index) {
    if (_selectedIndex == index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selectedIndex = index;
      _visited.add(index);
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _transition.value = 1;
    } else {
      _transition.forward(from: 0);
    }
  }

  void _openFiles() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const ReceivedFilesPage()),
  );
  void _openLogs() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const LogPage()),
  );

  Future<void> _clearHistory() async {
    if (_clearing) return;
    final confirmed = await confirmRemoval(
      context,
      title: context.l10n.clearHistory,
      message: context.l10n.clearHistoryConfirm,
    );
    if (!confirmed || !mounted) return;
    setState(() => _clearing = true);
    try {
      await ClipboardManager.instance.clearHistory();
      if (mounted) showClipyMessage(context, context.l10n.historyCleared);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _takeWindowsScreenshot(String mode) async {
    if (!Platform.isWindows || _capturingScreenshot) return;
    setState(() => _capturingScreenshot = true);
    try {
      // Let the Flutter popup close before the native runner freezes the screen.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final png = await _screenshotChannel.invokeMethod<Uint8List>('capture', {
        'mode': mode,
      });
      if (png == null || png.isEmpty) return; // Esc or right-click cancelled.
      final copied = await ClipboardManager.instance.ingestWindowsScreenshot(
        png,
      );
      if (mounted) {
        showClipyMessage(
          context,
          copied
              ? context.l10n.screenshotSaved
              : context.l10n.screenshotCopyFailed,
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.screenshotFailed);
    } finally {
      if (mounted) setState(() => _capturingScreenshot = false);
    }
  }

  static const _channel = MethodChannel(
    'com.clipyclone.clipy_android/open_folder',
  );
  Future<void> _openFolder(String path) async {
    try {
      final opened = await _channel.invokeMethod<bool>('openFolder', {
        'path': path,
      });
      if (opened == false && mounted) {
        showClipyMessage(context, context.l10n.fileNotFound);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        showClipyMessage(
          context,
          e.code == 'FILE_NOT_FOUND'
              ? context.l10n.fileNotFound
              : e.code == 'NO_ACTIVITY'
              ? context.l10n.noFileManager
              : context.l10n.couldNotOpenFolder(e.code),
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  Widget _history() => Column(
    children: [
      if (Platform.isIOS)
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 160,
              height: 44,
              child: UiKitView(viewType: 'clipy/iosPasteControl'),
            ),
          ),
        ),
      Expanded(
        child: PaginatedClipboardHistoryList(
          onFileTap: (entry) => _openFolder(
            entry.item.type == 'fileURLs'
                ? (entry.item.value as List<String>).first
                : entry.item.value.toString(),
          ),
        ),
      ),
    ],
  );
  Widget _settings() => ListView(
    key: const PageStorageKey('settings'),
    children: [
      MobileSettingsContent(
        onOpenLogs: _openLogs,
        onOpenReceivedFiles: _openFiles,
      ),
    ],
  );

  Widget _transfers() => Column(
    children: [
      for (final progress in _activeTransfers.values)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        progress.isOutgoing
                            ? Icons.upload_rounded
                            : Icons.download_rounded,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          progress.isOutgoing
                              ? context.l10n.sending(progress.fileName)
                              : context.l10n.receiving(progress.fileName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${(progress.progress * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: progress.progress.clamp(0, 1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final titles = [
      l10n.history,
      l10n.devices,
      l10n.notifications,
      l10n.settings,
    ];
    final subtitles = [
      Platform.isIOS ? l10n.iosHistoryTagline : l10n.historyTagline,
      l10n.localNetwork,
      Platform.isAndroid
          ? l10n.notificationIntro
          : l10n.remoteNotificationIntro,
      l10n.settingsTagline,
    ];
    final icons = [
      Icons.content_paste_rounded,
      Icons.devices_rounded,
      Icons.notifications_outlined,
      Icons.tune_rounded,
    ];
    final pages = <Widget Function()>[
      _history,
      () => const DevicesPage(),
      () => Platform.isAndroid
          ? const NotificationSyncPage(embedded: true)
          : const RemoteNotificationsPage(),
      _settings,
    ];
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final colors = Theme.of(context).colorScheme;
    final content = SafeArea(
      top: false,
      child: ScrollCollapsingHeader(
        enabled: _selectedIndex == 0,
        header: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titles[_selectedIndex],
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 6),
              Text(
                subtitles[_selectedIndex],
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_activeTransfers.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: SingleChildScrollView(child: _transfers()),
              ),
            Expanded(
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: _transition,
                  curve: Curves.easeOutCubic,
                ),
                child: ActivePageStack(
                  index: _selectedIndex,
                  children: [
                    for (var i = 0; i < pages.length; i++)
                      _visited.contains(i)
                          ? pages[i]()
                          : const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/branding/clipy-logo.png',
                width: 32,
                height: 32,
                excludeFromSemantics: true,
              ),
              const SizedBox(width: 10),
              const Text('Clipy'),
            ],
          ),
          actions: [
            if (Platform.isWindows && _selectedIndex == 0)
              PopupMenuButton<String>(
                tooltip: l10n.screenshot,
                icon: const Icon(Icons.crop_free_rounded),
                enabled: !_capturingScreenshot,
                onSelected: (mode) => unawaited(_takeWindowsScreenshot(mode)),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'region',
                    child: Text(l10n.screenshotRegion),
                  ),
                  PopupMenuItem(
                    value: 'window',
                    child: Text(l10n.screenshotWindow),
                  ),
                  PopupMenuItem(
                    value: 'fullscreen',
                    child: Text(l10n.screenshotFullscreen),
                  ),
                ],
              ),
            IconButton(
              onPressed: _openFiles,
              tooltip: l10n.receivedFiles,
              icon: const Icon(Icons.folder_open_rounded),
            ),
            if (_selectedIndex == 0)
              PopupMenuButton<String>(
                tooltip: l10n.moreActions,
                onSelected: (value) {
                  if (value == 'clear') _clearHistory();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'clear',
                    enabled: !_clearing,
                    child: Text(
                      l10n.clearHistory,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                ],
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: Row(
          children: [
            if (wide)
              NavigationRail(
                selectedIndex: _selectedIndex,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (var i = 0; i < titles.length; i++)
                    NavigationRailDestination(
                      icon: Icon(icons[i]),
                      label: Text(titles[i]),
                    ),
                ],
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: content,
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _selectedIndex,
                onDestinationSelected: _select,
                destinations: [
                  for (var i = 0; i < titles.length; i++)
                    NavigationDestination(
                      icon: Icon(icons[i]),
                      label: titles[i],
                    ),
                ],
              ),
      ),
    );
  }
}
