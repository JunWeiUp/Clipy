import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/notification_manager.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/features/devices/device_widgets.dart';
import 'package:clipy_android/features/logs/log_page.dart';

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
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 16.0,
            ),
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
                        messenger.showSnackBar(
                          SnackBar(content: Text(message)),
                        );
                      }
                    }
                  },
                  child: Text(l10n.save),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 16.0,
              right: 16.0,
              bottom: 16.0,
            ),
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
                          _pairingSecretController.text,
                        );
                        if (mounted) {
                          messenger.showSnackBar(
                            SnackBar(content: Text(message)),
                          );
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
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
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
            subtitle: Text(
              'ClipyClone ${Platform.isIOS ? 'iOS' : 'Android'} v1.0.0',
            ),
          ),
        ],
      ),
    );
  }
}
