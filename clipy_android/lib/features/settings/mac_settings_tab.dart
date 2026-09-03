import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_android/clipboard_manager.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/notification_manager.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/features/devices/device_widgets.dart';

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
                        await clipboardManager.updateHistoryLimit(
                          historyLimit - 1,
                        );
                        setState(() {});
                      }
                    : null,
              ),
              Text(historyLimit.toString()),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: historyLimit < 200
                    ? () async {
                        await clipboardManager.updateHistoryLimit(
                          historyLimit + 1,
                        );
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
        ListTile(
          title: Text(l10n.about),
          subtitle: const Text('ClipyClone macOS v1.0.0'),
        ),
      ],
    );
  }
}
