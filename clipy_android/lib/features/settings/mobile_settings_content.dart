import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/notification_manager.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/features/devices/device_widgets.dart';

class MobileSettingsContent extends StatefulWidget {
  final VoidCallback onOpenLogs;
  final VoidCallback onOpenReceivedFiles;

  const MobileSettingsContent({
    super.key,
    required this.onOpenLogs,
    required this.onOpenReceivedFiles,
  });

  @override
  State<MobileSettingsContent> createState() => _MobileSettingsContentState();
}

class _MobileSettingsContentState extends State<MobileSettingsContent> {
  static const _widgetChannel = MethodChannel(
    'com.clipyclone.clipy_android/widget',
  );
  late TextEditingController _portController;
  late TextEditingController _nameController;
  StreamSubscription? _devicesSubscription;
  List<DiscoveredPeer> _availableDevices = [];
  bool _timerWidgetPinned = false;

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
    _refreshTimerWidgetPinned();
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

  Future<void> _refreshTimerWidgetPinned() async {
    try {
      final pinned =
          await _widgetChannel.invokeMethod<bool>('isTimerWidgetPinned') ??
          false;
      if (mounted) {
        setState(() => _timerWidgetPinned = pinned);
      }
    } catch (_) {
      // Native side unavailable — keep the current state.
    }
  }

  Future<void> _requestPinTimerWidget(AppStrings l10n) async {
    var ok = false;
    try {
      ok =
          await _widgetChannel.invokeMethod<bool>('requestPinTimerWidget') ??
          false;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.timerWidgetPinRequested : l10n.timerWidgetPinFailed,
        ),
      ),
    );
    if (ok) {
      // Give the user time to confirm the system pin dialog before re-checking.
      await Future<void>.delayed(const Duration(seconds: 3));
      await _refreshTimerWidgetPinned();
    }
  }

  Widget _buildTimerWidgetCard(AppStrings l10n) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, color: Colors.blue, size: 36),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.timerWidgetTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.timerWidgetDesc,
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
            ),
            if (_timerWidgetPinned)
              const Icon(Icons.check_circle, color: Colors.green)
            else
              ElevatedButton(
                onPressed: () => _requestPinTimerWidget(l10n),
                child: Text(l10n.addToHomeScreen),
              ),
          ],
        ),
      ),
    );
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
              unawaited(
                NotificationManager.instance.requestNotificationPermission(),
              );
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
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        if (_availableDevices.isEmpty)
          ListTile(
            title: Text(l10n.noDevicesFound),
            subtitle: Text(l10n.sameWifiHint),
          )
        else
          ..._availableDevices.map((peer) => LanDeviceActionTile(peer: peer)),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.homeWidgetSection,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        _buildTimerWidgetCard(l10n),
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
          subtitle: Text(
            'ClipyClone ${Platform.isIOS ? 'iOS' : 'Android'} v1.0.0',
          ),
        ),
      ],
    );
  }
}
