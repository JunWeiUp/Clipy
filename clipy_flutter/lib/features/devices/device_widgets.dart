import 'dart:async';
import 'mac_screen_controls.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../../sync_manager.dart';
import '../../app_localizations.dart';
import '../../ui/app_components.dart';

Future<void> pickAndSendFileToDevice(
  BuildContext context,
  DiscoveredPeer peer,
) async {
  final l10n = context.l10n;
  try {
    final result = await FilePicker.pickFiles(allowMultiple: false);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      if (context.mounted) showClipyMessage(context, l10n.fileNotFound);
      return;
    }
    final success = await SyncManager.instance.sendFileToPeer(
      file,
      peerId: peer.peerId,
    );
    if (context.mounted) {
      showClipyMessage(
        context,
        success ? l10n.fileSentTo(peer.displayName) : l10n.sendFailed,
      );
    }
  } catch (_) {
    if (context.mounted) showClipyMessage(context, l10n.sendFailed);
  }
}

Future<void> showSendTextToDeviceDialog(
  BuildContext context,
  DiscoveredPeer peer, {
  String? initialText,
}) async {
  final l10n = context.l10n;
  final text = await (Platform.isIOS
      ? showCupertinoDialog<String>(
          context: context,
          builder: (_) => _SendTextDialog(peer: peer, initialText: initialText),
        )
      : showDialog<String>(
          context: context,
          builder: (_) => _SendTextDialog(peer: peer, initialText: initialText),
        ));
  if (text == null || !context.mounted) return;
  try {
    final success = await SyncManager.instance.sendTextToPeer(
      text,
      peerId: peer.peerId,
    );
    if (context.mounted) {
      showClipyMessage(
        context,
        success
            ? l10n.textSentTo(peer.displayName)
            : l10n.textDeliveryUnconfirmed,
      );
    }
  } catch (_) {
    if (context.mounted) showClipyMessage(context, l10n.sendFailed);
  }
}

class _SendTextDialog extends StatefulWidget {
  const _SendTextDialog({required this.peer, this.initialText});
  final DiscoveredPeer peer;
  final String? initialText;
  @override
  State<_SendTextDialog> createState() => _SendTextDialogState();
}

class _SendTextDialogState extends State<_SendTextDialog> {
  late final _text = TextEditingController(text: widget.initialText);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Platform.isIOS
      ? CupertinoAlertDialog(
          title: Text(context.l10n.sendTextTo(widget.peer.displayName)),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              placeholder: context.l10n.enterTextToSend,
              onChanged: (_) => setState(() {}),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            CupertinoDialogAction(
              onPressed: _text.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, _text.text),
              child: Text(context.l10n.send),
            ),
          ],
        )
      : AlertDialog(
          title: Text(context.l10n.sendTextTo(widget.peer.displayName)),
          content: TextField(
            controller: _text,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(hintText: context.l10n.enterTextToSend),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: _text.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, _text.text),
              child: Text(context.l10n.send),
            ),
          ],
        );
}

class LanDeviceActionTile extends StatelessWidget {
  final DiscoveredPeer peer;
  const LanDeviceActionTile({super.key, required this.peer});
  @override
  Widget build(BuildContext context) => ListTile(
    leading: const ClipyIcon(Icons.devices_rounded),
    title: Text(peer.displayName),
    subtitle: Text(
      peer.host.startsWith('relay:') ? context.l10n.internetRelay : peer.host,
    ),
    trailing: PopupMenuButton<String>(
      tooltip: context.l10n.moreActions,
      onSelected: (value) => value == 'text'
          ? showSendTextToDeviceDialog(context, peer)
          : pickAndSendFileToDevice(context, peer),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'text', child: Text(context.l10n.sendText)),
        PopupMenuItem(value: 'file', child: Text(context.l10n.sendFile)),
      ],
    ),
  );
}

class SyncTargetDeviceList extends StatefulWidget {
  const SyncTargetDeviceList({super.key, this.compact = false});

  final bool compact;
  @override
  State<SyncTargetDeviceList> createState() => _SyncTargetDeviceListState();
}

class _SyncTargetDeviceListState extends State<SyncTargetDeviceList> {
  StreamSubscription? _subscription;
  List<DiscoveredPeer> _peers = [];
  bool _refreshing = false;
  final Set<String> _busy = {};
  String? _expandedPeerId;
  @override
  void initState() {
    super.initState();
    _peers = SyncManager.instance.availablePeers;
    SyncManager.instance.discoveryProgress.addListener(_scanChanged);
    _subscription = SyncManager.instance.onPeersChanged.listen((peers) {
      if (mounted) setState(() => _peers = peers);
    });
    if (SyncManager.instance.isEnabled) {
      SyncManager.instance.triggerCrossBandDiscovery();
    }
  }

  void _scanChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SyncManager.instance.discoveryProgress.removeListener(_scanChanged);
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || !SyncManager.instance.isEnabled) return;
    setState(() => _refreshing = true);
    try {
      await SyncManager.instance.refreshDiscovery();
      if (mounted) {
        setState(() => _peers = SyncManager.instance.availablePeers);
        showClipyMessage(
          context,
          context.l10n.discoveryFinished(_peers.length),
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _change(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _removePeer(String id) async {
    final confirmed = await confirmRemoval(
      context,
      title: context.l10n.delete,
      message: context.l10n.removeDeviceConfirm,
    );
    if (confirmed && mounted) {
      await _change(id, () => SyncManager.instance.removeAuthorizedPeer(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manager = SyncManager.instance;
    final colors = Theme.of(context).colorScheme;
    final progress = manager.discoveryProgress.value;
    final refreshing = _refreshing || progress.running;
    final onlineIds = _peers.map((peer) => peer.peerId).toSet();
    final ids =
        {...manager.authorizedPeerIds, ..._peers.map((p) => p.peerId)}.toList()
          ..sort((a, b) {
            if (widget.compact &&
                onlineIds.contains(a) != onlineIds.contains(b)) {
              return onlineIds.contains(a) ? -1 : 1;
            }
            return a.compareTo(b);
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.authorizedDevices,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              onPressed: manager.isEnabled && !refreshing ? _refresh : null,
              tooltip: l10n.refreshDevices,
              icon: refreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (!widget.compact)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              l10n.syncTargetsSummary,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        if (refreshing)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: progress.fraction),
                const SizedBox(height: 8),
                Text(
                  l10n.discoveryScanning(
                    progress.completed,
                    progress.total,
                    _peers.length,
                  ),
                ),
              ],
            ),
          ),
        if (ids.isEmpty && !refreshing)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const ClipyIcon(Icons.devices_other_rounded, size: 64),
                  const SizedBox(height: 16),
                  Text(
                    l10n.noDevicesFound,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    manager.isEnabled ? l10n.sameWifiHint : l10n.diagSyncOff,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        for (final id in ids)
          Builder(
            builder: (context) {
              final matches = _peers.where((p) => p.peerId == id);
              final peer = matches.isEmpty ? null : matches.first;
              final clipboard = manager.clipboardSyncPeerIds.contains(id);
              final notifications = manager.notificationSyncPeerIds.contains(
                id,
              );
              final busy = _busy.contains(id);
              final syncControls = <Widget>[
                SwitchListTile.adaptive(
                  title: Text(l10n.syncClipboardToDevice),
                  value: clipboard,
                  onChanged: busy
                      ? null
                      : (value) => _change(
                          id,
                          () => manager.setClipboardSyncTarget(
                            id,
                            enabled: value,
                          ),
                        ),
                ),
                SwitchListTile.adaptive(
                  title: Text(l10n.syncNotificationsToDevice),
                  value: notifications,
                  onChanged: busy
                      ? null
                      : (value) => _change(
                          id,
                          () => manager.setNotificationSyncTarget(
                            id,
                            enabled: value,
                          ),
                        ),
                ),
              ];
              return Padding(
                padding: EdgeInsets.only(bottom: widget.compact ? 8 : 12),
                child: Card(
                  child: Column(
                    children: [
                      ListTile(
                        minTileHeight: widget.compact ? 64 : null,
                        contentPadding: widget.compact
                            ? const EdgeInsets.only(left: 12, right: 4)
                            : null,
                        minVerticalPadding: widget.compact ? 4 : null,
                        leading: ClipyIcon(
                          Icons.computer_rounded,
                          size: widget.compact ? 36 : 44,
                        ),
                        title: Text(
                          peer?.displayName ?? manager.resolvedPeerLabel(id),
                        ),
                        subtitle: Text(
                          peer == null
                              ? l10n.deviceOffline
                              : '${l10n.deviceOnline} · ${peer.host.startsWith('relay:') ? l10n.internetRelay : peer.host}',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                        trailing: widget.compact
                            ? IconButton(
                                tooltip: l10n.deviceSyncSettings,
                                isSelected: _expandedPeerId == id,
                                icon: const Icon(Icons.tune_rounded, size: 20),
                                onPressed: () => setState(() {
                                  _expandedPeerId = _expandedPeerId == id
                                      ? null
                                      : id;
                                }),
                              )
                            : clipboard || notifications
                            ? IconButton(
                                onPressed: busy ? null : () => _removePeer(id),
                                tooltip: l10n.delete,
                                icon: const Icon(Icons.link_off_rounded),
                              )
                            : null,
                      ),
                      if (peer != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            12,
                            0,
                            12,
                            widget.compact ? 8 : 16,
                          ),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (Platform.isIOS) ...[
                                CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  minimumSize: const Size(44, 36),
                                  color: CupertinoColors.systemBlue.withValues(
                                    alpha: .12,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                  onPressed: !manager.isEnabled || busy
                                      ? null
                                      : () => _change(
                                          id,
                                          () => showSendTextToDeviceDialog(
                                            context,
                                            peer,
                                          ),
                                        ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        CupertinoIcons.text_alignleft,
                                        size: 16,
                                        color: CupertinoColors.systemBlue,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        l10n.sendText,
                                        style: const TextStyle(
                                          color: CupertinoColors.systemBlue,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  minimumSize: const Size(44, 36),
                                  borderRadius: BorderRadius.circular(10),
                                  onPressed: !manager.isEnabled || busy
                                      ? null
                                      : () => _change(
                                          id,
                                          () => pickAndSendFileToDevice(
                                            context,
                                            peer,
                                          ),
                                        ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(CupertinoIcons.doc, size: 16),
                                      const SizedBox(width: 6),
                                      Text(
                                        l10n.sendFile,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                              ] else ...[
                                FilledButton.tonalIcon(
                                  onPressed: !manager.isEnabled || busy
                                      ? null
                                      : () => _change(
                                          id,
                                          () => showSendTextToDeviceDialog(
                                            context,
                                            peer,
                                          ),
                                        ),
                                  icon: const Icon(
                                    Icons.notes_rounded,
                                    size: 18,
                                  ),
                                  label: Text(l10n.sendText),
                                ),
                                OutlinedButton.icon(
                                  onPressed: !manager.isEnabled || busy
                                      ? null
                                      : () => _change(
                                          id,
                                          () => pickAndSendFileToDevice(
                                            context,
                                            peer,
                                          ),
                                        ),
                                  icon: const Icon(
                                    Icons.upload_file_outlined,
                                    size: 18,
                                  ),
                                  label: Text(l10n.sendFile),
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (peer != null && macScreenControlSupported)
                        MacScreenControls(
                          key: ValueKey('screen.$id'),
                          peerId: id,
                        ),
                      if (!widget.compact || _expandedPeerId == id) ...[
                        const Divider(indent: 12, endIndent: 12),
                        ...syncControls,
                        if (widget.compact && (clipboard || notifications))
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              onPressed: busy ? null : () => _removePeer(id),
                              tooltip: l10n.delete,
                              icon: const Icon(Icons.link_off_rounded),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class ManualPeerSection extends StatefulWidget {
  const ManualPeerSection({super.key});
  @override
  State<ManualPeerSection> createState() => _ManualPeerSectionState();
}

class _ManualPeerSectionState extends State<ManualPeerSection> {
  List<String> _peers = [];
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _peers = prefs.getStringList('manualSyncPeers') ?? []);
    }
  }

  Future<void> _save(String entry, {bool remove = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final peers = prefs.getStringList('manualSyncPeers') ?? [];
      if (remove) {
        peers.remove(entry);
      } else if (!peers.contains(entry)) {
        peers.add(entry);
      }
      await prefs.setStringList('manualSyncPeers', peers);
      if (mounted) setState(() => _peers = peers);
      if (!remove) {
        final parts = entry.split(':');
        await SyncManager.instance.connectManualPeer(
          parts.first,
          parts.length > 1 ? int.parse(parts[1]) : SyncManager.instance.port,
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final entry = await showDialog<String>(
      context: context,
      builder: (_) => const _ManualPeerDialog(),
    );
    if (entry != null && mounted) await _save(entry);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.manualDevices,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              onPressed: SyncManager.instance.isEnabled && !_busy ? _add : null,
              tooltip: context.l10n.addDevice,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        Text(
          context.l10n.manualDevicesHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        for (final peer in _peers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(peer),
            leading: const Icon(Icons.dns_outlined),
            trailing: IconButton(
              tooltip: context.l10n.delete,
              onPressed: _busy ? null : () => _save(peer, remove: true),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
      ],
    ),
  );
}

class _ManualPeerDialog extends StatefulWidget {
  const _ManualPeerDialog();
  @override
  State<_ManualPeerDialog> createState() => _ManualPeerDialogState();
}

class _ManualPeerDialogState extends State<_ManualPeerDialog> {
  final _host = TextEditingController();
  late final _port = TextEditingController(
    text: '${SyncManager.instance.port}',
  );
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.addDevice),
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _host,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: context.l10n.ipAddress,
              hintText: '192.168.1.20',
            ),
            validator: (value) {
              final parts = value?.trim().split('.') ?? [];
              if (parts.length != 4 ||
                  parts.any(
                    (part) =>
                        !RegExp(r'^\d{1,3}$').hasMatch(part) ||
                        int.parse(part) > 255,
                  )) {
                return context.l10n.invalidIP;
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: context.l10n.syncPort),
            validator: (value) {
              final number = int.tryParse(value?.trim() ?? '');
              return number == null || number < 1 || number > 65535
                  ? context.l10n.invalidPort
                  : null;
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              '${_host.text.trim()}:${int.parse(_port.text.trim())}',
            );
          }
        },
        child: Text(context.l10n.add),
      ),
    ],
  );
}
