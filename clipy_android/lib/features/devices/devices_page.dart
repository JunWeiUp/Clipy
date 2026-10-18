import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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
  const DevicesPage({super.key});
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _busy = false;
  bool _toggleTarget = false;
  Future<List<String>>? _addresses;

  @override
  void initState() {
    super.initState();
    _addresses = SyncManager.instance.localIPv4Addresses();
    SyncManager.instance.connectionRevision.addListener(_connectionChanged);
    SyncManager.instance.discoveryProgress.addListener(_connectionChanged);
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manager = SyncManager.instance;
    return ListView(
      key: const PageStorageKey('devices'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        // 开启同步按钮（顶部）
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: FilledButton.icon(
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
