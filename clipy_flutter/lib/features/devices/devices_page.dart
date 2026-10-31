import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app_localizations.dart';
import '../../notification_manager.dart';
import '../../sync_manager.dart';
import '../../sync/relay_client.dart';
import '../../ui/app_components.dart';
import 'device_widgets.dart';
import 'sync_diagnostics_page.dart';
import 'relay_settings.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, this.windowsLayout});
  @visibleForTesting
  final bool? windowsLayout;
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _busy = false;
  bool _toggleTarget = false;
  Future<List<String>>? _addresses;
  StreamSubscription<List<DiscoveredPeer>>? _windowsPeerSubscription;
  List<DiscoveredPeer> _windowsPeers = [];
  String? _selectedPeerId;
  bool _refreshingWindows = false;
  bool _peerChangeBusy = false;

  @override
  void initState() {
    super.initState();
    _addresses = SyncManager.instance.localIPv4Addresses();
    if (widget.windowsLayout ?? Platform.isWindows) {
      _windowsPeers = SyncManager.instance.availablePeers;
      _windowsPeerSubscription = SyncManager.instance.onPeersChanged.listen((
        peers,
      ) {
        if (mounted) setState(() => _windowsPeers = peers);
      });
      if (SyncManager.instance.isEnabled) {
        SyncManager.instance.triggerCrossBandDiscovery();
      }
    }
    SyncManager.instance.connectionRevision.addListener(_connectionChanged);
    SyncManager.instance.discoveryProgress.addListener(_connectionChanged);
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _windowsPeerSubscription?.cancel();
    SyncManager.instance.connectionRevision.removeListener(_connectionChanged);
    SyncManager.instance.discoveryProgress.removeListener(_connectionChanged);
    super.dispose();
  }

  Future<void> _toggle(bool enabled) async {
    if (_busy) return;
    final manager = SyncManager.instance;
    setState(() {
      _busy = true;
      _toggleTarget = enabled;
    });
    final previous = manager.isEnabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('syncEnabled', enabled);
      manager.isEnabled = enabled;
      if (enabled) {
        if (Platform.isAndroid) {
          unawaited(
            NotificationManager.instance.requestNotificationPermission(),
          );
        }
        await manager.start();
        if (!manager.isServerRunning) throw StateError('Server not listening');
      } else {
        await manager.stop();
      }
      _addresses = manager.localIPv4Addresses();
    } catch (_) {
      manager.isEnabled = previous;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('syncEnabled', previous);
      if (!previous) await manager.stop();
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editConnection() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ConnectionEditor(),
    );
    if (saved == true && mounted) {
      setState(() => _addresses = SyncManager.instance.localIPv4Addresses());
    }
  }

  Future<void> _refreshWindows() async {
    if (_refreshingWindows || !SyncManager.instance.isEnabled) return;
    setState(() => _refreshingWindows = true);
    try {
      await SyncManager.instance.refreshDiscovery();
      if (mounted) {
        setState(() => _windowsPeers = SyncManager.instance.availablePeers);
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _refreshingWindows = false);
    }
  }

  Future<void> _setPeerSync(
    String id,
    bool value, {
    required bool clipboard,
  }) async {
    if (_peerChangeBusy) return;
    setState(() => _peerChangeBusy = true);
    try {
      if (clipboard) {
        await SyncManager.instance.setClipboardSyncTarget(id, enabled: value);
      } else {
        await SyncManager.instance.setNotificationSyncTarget(
          id,
          enabled: value,
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _peerChangeBusy = false);
    }
  }

  Future<void> _removeWindowsPeer(String id) async {
    final confirmed = await confirmRemoval(
      context,
      title: context.l10n.delete,
      message: context.l10n.removeDeviceConfirm,
    );
    if (!confirmed || !mounted) return;
    setState(() => _peerChangeBusy = true);
    try {
      await SyncManager.instance.removeAuthorizedPeer(id);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _peerChangeBusy = false);
    }
  }

  void _openWindowsNetworkSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(context.l10n.connectionSettings)),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.tune),
                  title: Text(context.l10n.connectionSettings),
                  subtitle: Text(SyncManager.instance.displayName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editConnection,
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.monitor_heart_outlined),
                  title: Text(context.l10n.syncDiagnosticsTitle),
                  subtitle: Text(context.l10n.syncDiagnosticsSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SyncDiagnosticsPage(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              RelaySettings(
                onSettingsChanged: () {
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 16),
              const Card(child: ManualPeerSection()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _windowsDevices(BuildContext context) {
    final l10n = context.l10n;
    final manager = SyncManager.instance;
    final colors = Theme.of(context).colorScheme;
    final onlineIds = _windowsPeers.map((p) => p.peerId).toSet();
    final ids = {...manager.authorizedPeerIds, ...onlineIds}.toList()
      ..sort((a, b) {
        if (onlineIds.contains(a) != onlineIds.contains(b)) {
          return onlineIds.contains(a) ? -1 : 1;
        }
        return a.compareTo(b);
      });
    final selectedId = ids.contains(_selectedPeerId)
        ? _selectedPeerId
        : (ids.isEmpty ? null : ids.first);
    final matches = _windowsPeers.where((p) => p.peerId == selectedId);
    final peer = matches.isEmpty ? null : matches.first;
    final progress = manager.discoveryProgress.value;
    final refreshing = _refreshingWindows || progress.running;
    Widget deviceList() => ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 20),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.computer, size: 32),
            title: Text(manager.displayName),
            subtitle: FutureBuilder<List<String>>(
              future: _addresses,
              builder: (context, snapshot) => Text(
                snapshot.data?.isNotEmpty == true
                    ? '${l10n.myIPAddress}: ${snapshot.data!.join(', ')}'
                    : l10n.localNetwork,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: Switch(
              value: manager.isEnabled,
              onChanged: _busy ? null : _toggle,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (refreshing) ...[
          LinearProgressIndicator(value: progress.fraction),
          const SizedBox(height: 6),
          Text(
            l10n.discoveryScanning(
              progress.completed,
              progress.total,
              _windowsPeers.length,
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (ids.isEmpty && !refreshing)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              manager.isEnabled ? l10n.noDevicesFound : l10n.diagSyncOff,
            ),
          ),
        for (final id in ids)
          Builder(
            builder: (context) {
              final found = _windowsPeers.where((p) => p.peerId == id);
              final item = found.isEmpty ? null : found.first;
              final active = selectedId == id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: active
                          ? colors.primary
                          : colors.outlineVariant.withValues(alpha: .5),
                    ),
                  ),
                  child: ListTile(
                    selected: active,
                    leading: Icon(
                      item == null
                          ? Icons.devices_other_outlined
                          : Icons.devices,
                    ),
                    title: Text(
                      item?.displayName ?? manager.resolvedPeerLabel(id),
                    ),
                    subtitle: Text(
                      item == null
                          ? l10n.deviceOffline
                          : '${l10n.deviceOnline} · ${item.host.startsWith('relay:') ? l10n.internetRelay : item.host}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _selectedPeerId = id),
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _openWindowsNetworkSettings,
          icon: const Icon(Icons.settings_ethernet),
          label: Text(l10n.connectionSettings),
        ),
      ],
    );
    Widget detail() => selectedId == null
        ? Center(child: Text(l10n.noDevicesFound))
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 28, 24),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices, size: 36),
                title: Text(
                  peer?.displayName ?? manager.resolvedPeerLabel(selectedId),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                subtitle: Text(
                  peer == null
                      ? l10n.deviceOffline
                      : '${peer.host}:${peer.port}',
                ),
                trailing: manager.authorizedPeerIds.contains(selectedId)
                    ? IconButton(
                        tooltip: l10n.delete,
                        onPressed: _peerChangeBusy
                            ? null
                            : () => _removeWindowsPeer(selectedId),
                        icon: const Icon(Icons.link_off),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(l10n.syncClipboardToDevice),
                      value: manager.clipboardSyncPeerIds.contains(selectedId),
                      onChanged: _peerChangeBusy
                          ? null
                          : (v) => _setPeerSync(selectedId, v, clipboard: true),
                    ),
                    SwitchListTile(
                      title: Text(l10n.syncNotificationsToDevice),
                      value: manager.notificationSyncPeerIds.contains(
                        selectedId,
                      ),
                      onChanged: _peerChangeBusy
                          ? null
                          : (v) =>
                                _setPeerSync(selectedId, v, clipboard: false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.sendFile,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Icon(Icons.upload_file_outlined, size: 30),
                      Text(l10n.sendFile),
                      FilledButton.icon(
                        onPressed: peer == null || !manager.isEnabled
                            ? null
                            : () => pickAndSendFileToDevice(context, peer),
                        icon: const Icon(Icons.attach_file),
                        label: Text(l10n.sendFile),
                      ),
                      OutlinedButton.icon(
                        onPressed: peer == null || !manager.isEnabled
                            ? null
                            : () => showSendTextToDeviceDialog(context, peer),
                        icon: const Icon(Icons.send_outlined),
                        label: Text(l10n.sendText),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.devices,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
              IconButton(
                onPressed: manager.isEnabled && !refreshing
                    ? _refreshWindows
                    : null,
                tooltip: l10n.refreshDevices,
                icon: refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              OutlinedButton.icon(
                onPressed: _openWindowsNetworkSettings,
                icon: const Icon(Icons.add),
                label: Text(l10n.addDevice),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 620) {
                return ListView(
                  shrinkWrap: true,
                  children: [
                    SizedBox(height: 320, child: deviceList()),
                    SizedBox(height: 420, child: detail()),
                  ],
                );
              }
              return Row(
                children: [
                  SizedBox(
                    width: (constraints.maxWidth * .47).clamp(300, 388),
                    child: deviceList(),
                  ),
                  VerticalDivider(width: 1, color: colors.outlineVariant),
                  Expanded(child: detail()),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manager = SyncManager.instance;
    if (widget.windowsLayout ?? Platform.isWindows) {
      return _windowsDevices(context);
    }
    return ListView(
      key: const PageStorageKey('devices'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Platform.isIOS
              ? CupertinoButton.filled(
                  borderRadius: BorderRadius.circular(16),
                  minimumSize: const Size.fromHeight(56),
                  onPressed: _busy ? null : () => _toggle(!manager.isEnabled),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_busy)
                        const CupertinoActivityIndicator(
                          color: CupertinoColors.white,
                        )
                      else
                        Icon(
                          manager.isEnabled
                              ? CupertinoIcons.arrow_2_circlepath
                              : CupertinoIcons.pause_circle,
                        ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          syncButtonLabel(
                            l10n,
                            enabled: _busy ? _toggleTarget : manager.isEnabled,
                            serverRunning: manager.isServerRunning,
                            lan: manager.hasLanSession,
                            relay: manager.hasRelaySession,
                            relayState: manager.relayConnectionState,
                            scanning: manager.discoveryProgress.value.running,
                            busy: _busy,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                )
              : FilledButton.icon(
                  onPressed: _busy ? null : () => _toggle(!manager.isEnabled),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          manager.isEnabled
                              ? Icons.sync_rounded
                              : Icons.sync_disabled_rounded,
                        ),
                  label: Text(
                    syncButtonLabel(
                      l10n,
                      enabled: _busy ? _toggleTarget : manager.isEnabled,
                      serverRunning: manager.isServerRunning,
                      lan: manager.hasLanSession,
                      relay: manager.hasRelaySession,
                      relayState: manager.relayConnectionState,
                      scanning: manager.discoveryProgress.value.running,
                      busy: _busy,
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
        ),
        if (manager.isEnabled && !_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(l10n.syncStopHint, textAlign: TextAlign.center),
          ),
        SyncTargetDeviceList(key: ValueKey(manager.isEnabled), compact: true),
        const SizedBox(height: 20),
        if (Platform.isIOS)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  l10n.localNetwork,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Text(
                  l10n.syncLanFirst,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoDynamicColor.resolve(
                      CupertinoColors.secondaryLabel,
                      context,
                    ),
                  ),
                ),
              ),
              CupertinoListSection.insetGrouped(
                margin: EdgeInsets.zero,
                children: [
                  CupertinoListTile(
                    leading: const Icon(CupertinoIcons.slider_horizontal_3),
                    title: Text(l10n.connectionSettings),
                    subtitle: Text(manager.displayName),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _busy ? null : _editConnection,
                  ),
                  CupertinoListTile(
                    leading: const Icon(CupertinoIcons.heart),
                    title: Text(l10n.syncDiagnosticsTitle),
                    subtitle: Text(l10n.syncDiagnosticsSubtitle),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => Navigator.push(
                      context,
                      CupertinoPageRoute<void>(
                        builder: (_) => const SyncDiagnosticsPage(),
                      ),
                    ),
                  ),
                  FutureBuilder<List<String>>(
                    future: _addresses,
                    builder: (context, snapshot) =>
                        snapshot.hasData && snapshot.data!.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                            child: SelectableText(
                              '${l10n.myIPAddress}: ${snapshot.data!.join(', ')}',
                              style: TextStyle(
                                fontSize: 12,
                                color: CupertinoDynamicColor.resolve(
                                  CupertinoColors.secondaryLabel,
                                  context,
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ],
          )
        else
          ClipySection(
            title: l10n.localNetwork,
            subtitle: l10n.syncLanFirst,
            child: Column(
              children: [
                ListTile(
                  leading: const ClipyIcon(Icons.tune_rounded),
                  title: Text(l10n.connectionSettings),
                  subtitle: Text(manager.displayName),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy ? null : _editConnection,
                ),
                const Divider(indent: 20, endIndent: 20),
                ListTile(
                  leading: const ClipyIcon(Icons.monitor_heart_outlined),
                  title: Text(l10n.syncDiagnosticsTitle),
                  subtitle: Text(l10n.syncDiagnosticsSubtitle),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SyncDiagnosticsPage(),
                    ),
                  ),
                ),
                FutureBuilder<List<String>>(
                  future: _addresses,
                  builder: (context, snapshot) =>
                      snapshot.hasData && snapshot.data!.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(
                              '${l10n.myIPAddress}: ${snapshot.data!.join(', ')}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        RelaySettings(
          onSettingsChanged: () {
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 20),
        const Card(child: ManualPeerSection()),
      ],
    );
  }
}

class ConnectionEditor extends StatefulWidget {
  const ConnectionEditor({super.key});
  @override
  State<ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<ConnectionEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: SyncManager.instance.displayName,
  );
  late final _port = TextEditingController(
    text: '${SyncManager.instance.port}',
  );
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await SyncManager.instance.updateConnectionSettings(
        name: _name.text,
        listeningPort: int.parse(_port.text.trim()),
      );
      if (!mounted) return;
      showClipyMessage(
        context,
        SyncManager.instance.isEnabled && !SyncManager.instance.isServerRunning
            ? context.l10n.diagServerNotBound
            : context.l10n.settingsSaved,
      );
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (Platform.isIOS) {
      return PopScope(
        canPop: !_saving,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.connectionSettings,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  CupertinoFormSection.insetGrouped(
                    margin: EdgeInsets.zero,
                    children: [
                      CupertinoTextFormFieldRow(
                        controller: _name,
                        enabled: !_saving,
                        prefix: Text(l10n.deviceNameForSync),
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? l10n.nameRequired
                            : null,
                      ),
                      CupertinoTextFormFieldRow(
                        controller: _port,
                        enabled: !_saving,
                        prefix: Text(l10n.syncPort),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          final port = int.tryParse(value?.trim() ?? '');
                          return port == null || port < 1 || port > 65535
                              ? l10n.invalidPort
                              : null;
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  CupertinoButton.filled(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const CupertinoActivityIndicator(
                            color: CupertinoColors.white,
                          )
                        : Text(l10n.save),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.connectionSettings,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _name,
                  enabled: !_saving,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.deviceNameForSync,
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? l10n.nameRequired
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _port,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l10n.syncPort),
                  validator: (value) {
                    final port = int.tryParse(value?.trim() ?? '');
                    return port == null || port < 1 || port > 65535
                        ? l10n.invalidPort
                        : null;
                  },
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(l10n.save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String syncButtonLabel(
  AppStrings l10n, {
  required bool enabled,
  required bool serverRunning,
  required bool lan,
  required bool relay,
  required RelayConnectionState relayState,
  required bool scanning,
  bool busy = false,
}) {
  if (busy) return enabled ? l10n.syncStarting : l10n.syncStopping;
  if (!enabled) return l10n.syncStart;
  if (lan && relay) return l10n.syncMixedConnected;
  if (lan) return l10n.syncLanConnected;
  if (relay) return l10n.syncRelayConnected;
  if (!serverRunning) return l10n.diagServerNotBound;
  switch (relayState) {
    case RelayConnectionState.connecting:
      return l10n.syncRelayConnecting;
    case RelayConnectionState.ready:
      return l10n.syncRelayReady;
    case RelayConnectionState.retrying:
      return l10n.syncRelayRetrying;
    case RelayConnectionState.disabled:
      return scanning ? l10n.syncSearching : l10n.syncWaiting;
  }
}
