import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app_localizations.dart';
import '../../notification_manager.dart';
import '../../sync_manager.dart';
import '../../ui/app_components.dart';
import 'device_widgets.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _busy = false;
  Future<List<String>>? _addresses;

  @override
  void initState() {
    super.initState();
    _addresses = SyncManager.instance.localIPv4Addresses();
  }

  Future<void> _toggle(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    final manager = SyncManager.instance;
    final previous = manager.isEnabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('syncEnabled', enabled);
      manager.isEnabled = enabled;
      if (enabled) {
        unawaited(NotificationManager.instance.requestNotificationPermission());
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
    final colors = Theme.of(context).colorScheme;
    return ListView(
      key: const PageStorageKey('devices'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colors.primaryContainer,
                colors.secondaryContainer.withValues(alpha: .6),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.devices_rounded,
                size: 36,
                color: colors.onPrimaryContainer,
              ),
              const SizedBox(height: 20),
              Text(
                l10n.devicesTagline,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.connectionHint,
                style: TextStyle(color: colors.onPrimaryContainer, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ClipySection(
          title: l10n.localNetwork,
          child: Column(
            children: [
              SwitchListTile(
                secondary: _busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const ClipyIcon(Icons.wifi_rounded),
                title: Text(l10n.enableLanSync),
                subtitle: Text(
                  manager.isEnabled
                      ? (manager.isServerRunning
                            ? l10n.syncReady
                            : l10n.diagServerNotBound)
                      : l10n.syncPaused,
                ),
                value: manager.isEnabled,
                onChanged: _busy ? null : _toggle,
              ),
              const Divider(indent: 20, endIndent: 20),
              ListTile(
                leading: const ClipyIcon(Icons.tune_rounded),
                title: Text(l10n.connectionSettings),
                subtitle: Text(manager.displayName),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _busy ? null : _editConnection,
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
        SyncTargetDeviceList(key: ValueKey(manager.isEnabled)),
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
  late final _secret = TextEditingController(
    text: SyncManager.instance.pairingSecret,
  );
  bool _saving = false;
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await SyncManager.instance.updateConnectionSettings(
        name: _name.text,
        listeningPort: int.parse(_port.text.trim()),
        secret: _secret.text,
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
                  controller: _secret,
                  enabled: !_saving,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l10n.syncPairingSecret,
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      tooltip: _obscure ? l10n.showSecret : l10n.hideSecret,
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.syncPairingSecretHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
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
