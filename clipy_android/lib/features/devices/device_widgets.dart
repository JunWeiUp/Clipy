import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/app_localizations.dart';

Future<void> pickAndSendFileToDevice(
  BuildContext context,
  DiscoveredPeer peer,
) async {
  final l10n = context.l10n;
  final result = await FilePicker.pickFiles(allowMultiple: false);
  if (result == null || result.files.isEmpty) return;
  final path = result.files.single.path;
  if (path == null) return;
  final file = File(path);
  if (!file.existsSync()) return;
  final success = await SyncManager.instance.sendFileToPeer(
    file,
    peerId: peer.peerId,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? l10n.fileSentTo(peer.displayName) : l10n.sendFailed,
        ),
      ),
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
      SnackBar(
        content: Text(
          success ? l10n.textSentTo(peer.displayName) : l10n.sendFailed,
        ),
      ),
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
      subtitle: Text(
        shortId,
        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
      ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.devicesRefreshed)));
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
            final clipOn = SyncManager.instance.clipboardSyncPeerIds.contains(
              peerId,
            );
            final notifOn = SyncManager.instance.notificationSyncPeerIds
                .contains(peerId);
            final title =
                online?.displayName ??
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
                          online != null
                              ? l10n.deviceOnline
                              : l10n.deviceOffline,
                          style: TextStyle(
                            fontSize: 12,
                            color: online != null
                                ? Colors.green[700]
                                : Colors.grey[600],
                          ),
                        ),
                        if (clipOn || notifOn)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            tooltip: l10n.delete,
                            onPressed: () async {
                              await SyncManager.instance.removeAuthorizedPeer(
                                peerId,
                              );
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
    final portController = TextEditingController(
      text: '${SyncManager.instance.port}',
    );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(
                  ctx,
                  '${hostController.text.trim()}:${portController.text.trim()}',
                );
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
