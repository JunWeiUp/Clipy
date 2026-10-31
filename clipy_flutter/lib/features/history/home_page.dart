import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../ui/ios_tab_scaffold.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../../clipboard_manager.dart';
import '../../sync_manager.dart';
import '../../notification_sync_page.dart';
import 'remote_notifications_page.dart';
import 'windows_quick_panel.dart';
import 'history_feed_controller.dart';
import 'windows_capture_result.dart';
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
import '../settings/windows_settings_page.dart';
import '../settings/windows_hotkeys.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.windowsLayout, this.historyController});
  @visibleForTesting
  final bool? windowsLayout;
  @visibleForTesting
  final HistoryFeedController? historyController;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool get _windows => widget.windowsLayout ?? Platform.isWindows;
  IncomingShareCoordinator? _incomingShares;
  StreamSubscription? _sharePeersSubscription;
  int _selectedIndex = 0;
  final _historyFilter = ValueNotifier<String>('all');
  final _windowsSearch = TextEditingController();
  final _windowsSearchFocus = FocusNode();
  final _windowsRootFocus = FocusNode();
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
  bool _quickPanel = false;
  int _presentationRevision = 0;
  ({String path, bool copied})? _captureResult;
  bool _sendingCapture = false;
  static const _trayChannel = MethodChannel(
    'com.clipyclone.clipy_android/tray',
  );
  static const _screenshotChannel = MethodChannel(
    'com.clipyclone.clipy_android/screenshot',
  );

  @override
  void initState() {
    super.initState();
    if (_windows) {
      _trayChannel.setMethodCallHandler(_handleTrayAction);
      WidgetsBinding.instance.addObserver(this);
      unawaited(_syncWindowsPresentation());
      unawaited(WindowsHotkeys.initialize());
    }
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
    if (_windows) _trayChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _incomingShares?.dispose();
    _sharePeersSubscription?.cancel();
    _fileSubscription?.cancel();
    _progressSubscription?.cancel();
    _transition.dispose();
    _historyFilter.dispose();
    _windowsSearch.dispose();
    _windowsSearchFocus.dispose();
    _windowsRootFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _incomingShares?.drain();
    if (state == AppLifecycleState.resumed && _windows) {
      unawaited(_syncWindowsPresentation());
    }
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

  Future<void> _syncWindowsPresentation() async {
    final revision = ++_presentationRevision;
    try {
      final mode = await _trayChannel.invokeMethod<String>('getWindowMode');
      if (!mounted || revision != _presentationRevision || mode == null) return;
      setState(() {
        _quickPanel = mode == 'quick';
        if (_quickPanel) _captureResult = null;
      });
    } catch (_) {
      /* Older runners can still deliver explicit presentation events. */
    }
  }

  Future<void> _handleTrayAction(MethodCall call) async {
    if (call.method == 'windowMode' && mounted) {
      _presentationRevision++;
      final mode = call.arguments;
      if (mode == 'main' || mode == 'quick' || mode == 'capture') {
        Navigator.of(context).popUntil((route) => route.isFirst);
        setState(() {
          _quickPanel = mode == 'quick';
          if (mode != 'capture') _captureResult = null;
        });
      }
      return;
    }
    if (call.method != 'action' || !mounted) return;
    final action = call.arguments;
    if (action is! String) return;
    _presentationRevision++;
    if (action == 'resultClosed') {
      setState(() => _captureResult = null);
      return;
    }
    if (action == 'quick' || action == 'quickClosed') {
      if (action == 'quick') {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      setState(() => _quickPanel = action == 'quick');
      unawaited(_syncWindowsPresentation());
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _quickPanel = false;
      _captureResult = null;
    });
    switch (action) {
      case 'history':
        _select(0);
      case 'devices':
        _select(1);
      case 'settings':
        _select(3);
      case 'capture':
        await _takeWindowsScreenshot('region');
    }
  }

  void _select(int index) {
    if (_selectedIndex == index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_windows) _windowsRootFocus.requestFocus();
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

  Future<void> _takeWindowsScreenshot(
    String mode, {
    int delaySeconds = 0,
  }) async {
    if (!_windows || _capturingScreenshot) return;
    setState(() => _capturingScreenshot = true);
    try {
      // Let the Flutter popup close before the native runner freezes the screen.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final png = await _screenshotChannel.invokeMethod<Uint8List>('capture', {
        'mode': mode,
        'delaySeconds': delaySeconds,
      });
      if (png == null || png.isEmpty) return; // Esc or right-click cancelled.
      final result = await ClipboardManager.instance.ingestWindowsScreenshot(
        png,
      );
      if (mounted) {
        setState(() {
          _quickPanel = false;
          _captureResult = (path: result.path, copied: result.copied);
        });
        try {
          await _trayChannel.invokeMethod<void>('showCaptureResult');
        } catch (_) {
          if (mounted) {
            setState(() => _captureResult = null);
            showClipyMessage(
              context,
              result.copied
                  ? context.l10n.screenshotSaved
                  : context.l10n.screenshotCopyFailed,
            );
          }
        }
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.screenshotFailed);
    } finally {
      if (mounted) setState(() => _capturingScreenshot = false);
    }
  }

  Future<void> _chooseScreenshotOptions() async {
    var mode = 'region';
    var delay = 0;
    final l10n = context.l10n;
    final selection = await showDialog<(String, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.screenshotOptions),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButton<String>(
                value: mode,
                isExpanded: true,
                onChanged: (value) {
                  if (value != null) update(() => mode = value);
                },
                items: [
                  DropdownMenuItem(
                    value: 'region',
                    child: Text(l10n.screenshotRegion),
                  ),
                  DropdownMenuItem(
                    value: 'window',
                    child: Text(l10n.screenshotWindow),
                  ),
                  DropdownMenuItem(
                    value: 'fullscreen',
                    child: Text(l10n.screenshotFullscreen),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(l10n.screenshotDelay),
              DropdownButton<int>(
                value: delay,
                isExpanded: true,
                onChanged: (value) {
                  if (value != null) update(() => delay = value);
                },
                items: [
                  DropdownMenuItem(
                    value: 0,
                    child: Text(l10n.screenshotNoDelay),
                  ),
                  for (final seconds in [3, 5])
                    DropdownMenuItem(
                      value: seconds,
                      child: Text(l10n.screenshotDelaySeconds(seconds)),
                    ),
                ],
              ),
              if (delay != 0)
                Text(
                  l10n.screenshotDelayHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (mode, delay)),
              child: Text(l10n.screenshot),
            ),
          ],
        ),
      ),
    );
    if (selection != null && mounted) {
      await _takeWindowsScreenshot(selection.$1, delaySeconds: selection.$2);
    }
  }

  void _onScreenshotMenu(String value) {
    if (value == 'options') {
      unawaited(_chooseScreenshotOptions());
    } else {
      unawaited(_takeWindowsScreenshot(value));
    }
  }

  Future<void> _saveScreenshot(String sourcePath) async {
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: context.l10n.saveAs,
        fileName: 'Clipy.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (path == null) return;
      await File(sourcePath).copy(path);
      if (mounted) showClipyMessage(context, context.l10n.fileSaved);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  Future<void> _dismissCaptureResult() async {
    try {
      await _trayChannel.invokeMethod<void>('dismissCaptureResult');
    } catch (_) {
      if (mounted) setState(() => _captureResult = null);
    }
  }

  Future<void> _sendScreenshot(String path) async {
    if (_sendingCapture) return;
    final peers = SyncManager.instance.availablePeers;
    if (peers.isEmpty) {
      showClipyMessage(context, context.l10n.noDevicesFound);
      return;
    }
    final peer = await showDialog<DiscoveredPeer>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.sendFile),
        content: SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in peers)
                  ListTile(
                    title: Text(item.displayName),
                    subtitle: Text(item.host),
                    onTap: () => Navigator.pop(context, item),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );
    if (peer == null || !mounted) return;
    setState(() => _sendingCapture = true);
    try {
      final success = await SyncManager.instance.sendFileToPeer(
        File(path),
        peerId: peer.peerId,
      );
      if (mounted) {
        showClipyMessage(
          context,
          success
              ? context.l10n.fileSentTo(peer.displayName)
              : context.l10n.sendFailed,
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.sendFailed);
    } finally {
      if (mounted) setState(() => _sendingCapture = false);
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
          filterNotifier: _historyFilter,
          controller: widget.historyController,
          windowsLayout: _windows,
          searchController: _windows ? _windowsSearch : null,
          searchFocus: _windows ? _windowsSearchFocus : null,
          onClearHistory: _windows && !_clearing ? _clearHistory : null,
          onFileTap: (entry) => _openFolder(
            entry.item.type == 'fileURLs'
                ? (entry.item.value as List<String>).first
                : entry.item.value.toString(),
          ),
        ),
      ),
    ],
  );
  Widget _settings() => _windows
      ? WindowsSettingsPage(
          onOpenLogs: _openLogs,
          onBack: () => _select(0),
          onOpenReceivedFiles: _openFiles,
        )
      : ListView(
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
    final result = _captureResult;
    if (result != null) {
      return WindowsCaptureResult(
        path: result.path,
        copied: result.copied,
        onClose: () => unawaited(_dismissCaptureResult()),
        onSave: () => unawaited(_saveScreenshot(result.path)),
        onReveal: () => unawaited(_openFolder(result.path)),
        onSend: () => unawaited(_sendScreenshot(result.path)),
      );
    }
    if (_quickPanel) {
      return WindowsQuickPanel(
        controller: widget.historyController,
        onOpenFull: () async {
          try {
            await _trayChannel.invokeMethod<void>('openMainWindow');
            if (mounted) {
              setState(() => _quickPanel = false);
            }
          } catch (_) {
            if (mounted) {
              showClipyMessage(this.context, this.context.l10n.operationFailed);
            }
          }
        },
      );
    }
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
    final wide = _windows || MediaQuery.sizeOf(context).width >= 720;
    final colors = Theme.of(context).colorScheme;
    final content = SafeArea(
      top: false,
      child: ScrollCollapsingHeader(
        enabled: !_windows && _selectedIndex != 1,
        pageIdentity: _selectedIndex,
        scrollDepth: _selectedIndex == 2 && Platform.isAndroid ? 1 : 0,
        header: _selectedIndex == 1 || (_windows && _selectedIndex == 3)
            ? const SizedBox.shrink()
            : Padding(
                padding: _windows
                    ? const EdgeInsets.fromLTRB(36, 28, 36, 16)
                    : const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titles[_selectedIndex],
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    if (!_windows) const SizedBox(height: 6),
                    if (!_windows)
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
    if (Platform.isIOS) {
      return IosTabScaffold(
        body: content,
        selectedIndex: _selectedIndex,
        onSelected: _select,
        titles: titles,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: const EdgeInsets.all(8),
              onPressed: _openFiles,
              child: Semantics(
                label: l10n.receivedFiles,
                child: const Icon(CupertinoIcons.folder, size: 22),
              ),
            ),
            if (_selectedIndex == 0)
              CupertinoButton(
                padding: const EdgeInsets.all(8),
                onPressed: _clearing ? null : _clearHistory,
                child: Semantics(
                  label: l10n.clearHistory,
                  child: const Icon(CupertinoIcons.trash, size: 22),
                ),
              ),
          ],
        ),
      );
    }
    return CallbackShortcuts(
      bindings: _windows
          ? {
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () {
                _select(0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _windowsSearchFocus.requestFocus();
                });
              },
            }
          : {},
      child: Focus(
        focusNode: _windowsRootFocus,
        canRequestFocus: _windows,
        autofocus: _windows,
        child: PopScope(
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
                    width: _windows ? 16 : 32,
                    height: _windows ? 16 : 32,
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(width: 10),
                  const Text('Clipy'),
                  if (_windows && _selectedIndex == 0) ...[
                    const SizedBox(width: 136),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: TextField(
                          controller: _windowsSearch,
                          focusNode: _windowsSearchFocus,
                          decoration: InputDecoration(
                            hintText: '${l10n.searchHistory}  Ctrl+F',
                            prefixIcon: const Icon(Icons.search, size: 16),
                            suffixIcon: IconButton(
                              tooltip: l10n.clearSearch,
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: _windowsSearch.clear,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                if (_windows && _selectedIndex == 0)
                  PopupMenuButton<String>(
                    tooltip: l10n.screenshot,
                    icon: const Icon(Icons.crop_free_rounded),
                    enabled: !_capturingScreenshot,
                    onSelected: _onScreenshotMenu,
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
                      PopupMenuItem(
                        value: 'options',
                        child: Text(l10n.screenshotOptions),
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
                if (wide && _windows && _selectedIndex != 3)
                  SizedBox(
                    width: 260,
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(
                            child: Column(
                              children: [
                                for (var i = 0; i < titles.length; i++) ...[
                                  if (i == 3) ...[
                                    if (_selectedIndex == 0) ...[
                                      const SizedBox(height: 24),
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          0,
                                          16,
                                          8,
                                        ),
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            l10n.filter,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelMedium,
                                          ),
                                        ),
                                      ),
                                      for (final filter in [
                                        (
                                          'all',
                                          l10n.allItems,
                                          Icons.filter_list,
                                        ),
                                        ('text', l10n.textItems, Icons.notes),
                                        ('links', l10n.linkItems, Icons.link),
                                        (
                                          'images',
                                          l10n.imageItems,
                                          Icons.image_outlined,
                                        ),
                                        (
                                          'files',
                                          l10n.fileItems,
                                          Icons.folder_outlined,
                                        ),
                                      ])
                                        ValueListenableBuilder<String>(
                                          valueListenable: _historyFilter,
                                          builder: (context, selected, _) =>
                                              ListTile(
                                                dense: true,
                                                minTileHeight: 36,
                                                selected:
                                                    _selectedIndex == 0 &&
                                                    selected == filter.$1,
                                                leading: Icon(
                                                  filter.$3,
                                                  size: 18,
                                                ),
                                                title: Text(
                                                  filter.$2,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                onTap: () {
                                                  _select(0);
                                                  _historyFilter.value =
                                                      filter.$1;
                                                },
                                              ),
                                        ),
                                    ],
                                    const Spacer(),
                                  ],
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    child: Material(
                                      color: _selectedIndex == i
                                          ? colors.onSurface.withValues(
                                              alpha: 0.06,
                                            )
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(4),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(4),
                                        onTap: () => _select(i),
                                        child: SizedBox(
                                          height: 36,
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 3,
                                                height: 18,
                                                decoration: BoxDecoration(
                                                  color: _selectedIndex == i
                                                      ? colors.primary
                                                      : Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(2),
                                                ),
                                              ),
                                              const SizedBox(width: 9),
                                              Icon(icons[i], size: 18),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  titles[i],
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (i == 1)
                                    ListTile(
                                      dense: true,
                                      minTileHeight: 36,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                      leading: const Icon(
                                        Icons.swap_vert,
                                        size: 18,
                                      ),
                                      title: Text(
                                        l10n.fileTransfer,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                      onTap: () => _select(1),
                                    ),
                                  if (i == 2)
                                    ListTile(
                                      dense: true,
                                      minTileHeight: 36,
                                      leading: const Icon(
                                        Icons.crop_free,
                                        size: 18,
                                      ),
                                      title: Text(
                                        l10n.screenshot,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                      onTap: _capturingScreenshot
                                          ? null
                                          : () => _takeWindowsScreenshot(
                                              'region',
                                            ),
                                      trailing: PopupMenuButton<String>(
                                        enabled: !_capturingScreenshot,
                                        tooltip: l10n.screenshotOptions,
                                        icon: const Icon(
                                          Icons.keyboard_arrow_down,
                                          size: 18,
                                        ),
                                        onSelected: _onScreenshotMenu,
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
                                            child: Text(
                                              l10n.screenshotFullscreen,
                                            ),
                                          ),
                                          PopupMenuItem(
                                            value: 'options',
                                            child: Text(l10n.screenshotOptions),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                else if (wide && !_windows)
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
                  child: _windows
                      ? Container(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLowest.withValues(
                              alpha: 0.62,
                            ),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(8),
                            ),
                            border: Border.all(
                              color: colors.onSurface.withValues(alpha: 0.06),
                            ),
                          ),
                          child: content,
                        )
                      : Center(
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
        ),
      ),
    );
  }
}
