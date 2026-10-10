import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../app_localizations.dart';
import '../../sync_manager.dart';
import '../../ui/app_components.dart';
import '../devices/devices_page.dart';
import 'incoming_share.dart';

class SharedFilesPage extends StatefulWidget {
  const SharedFilesPage({super.key, required this.share});
  final IncomingShare share;
  @override
  State<SharedFilesPage> createState() => _SharedFilesPageState();
}

class _SharedFilesPageState extends State<SharedFilesPage>
    with WidgetsBindingObserver {
  final _sent = <int>{};
  bool _sending = false;
  int? _current;
  String? _peerId;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncManager.instance.discoveryProgress.addListener(_discoveryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshDevices(automatic: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SyncManager.instance.discoveryProgress.removeListener(_discoveryChanged);
    super.dispose();
  }

  void _discoveryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(_refreshDevices(automatic: true));
    }
  }

  Future<void> _refreshDevices({bool automatic = false}) async {
    final manager = SyncManager.instance;
    if (_sending || _refreshing || !manager.isEnabled) return;
    setState(() => _refreshing = true);
    try {
      await manager.refreshDiscovery(automatic: automatic);
      if (mounted && !automatic) {
        showClipyMessage(
          context,
          context.l10n.discoveryFinished(manager.availablePeers.length),
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _send(DiscoveredPeer peer) async {
    if (_sending) return;
    setState(() => _sending = true);
    var failed = false;
    try {
      for (var index = 0; index < widget.share.files.length; index++) {
        if (_sent.contains(index)) continue;
        setState(() => _current = index);
        final success = await SyncManager.instance.sendFileToPeer(
          File(widget.share.files[index].path),
          peerId: peer.peerId,
        );
        if (!mounted) return;
        if (!success) {
          failed = true;
          break;
        }
        setState(() => _sent.add(index));
      }
    } catch (_) {
      failed = true;
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _current = null;
        });
      }
    }
    if (!mounted) return;
    showClipyMessage(
      context,
      failed
          ? context.l10n.sendFailed
          : context.l10n.fileSentTo(peer.displayName),
    );
    if (!failed && _sent.length == widget.share.files.length) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manager = SyncManager.instance;
    final progress = manager.discoveryProgress.value;
    final refreshing = _refreshing || progress.running;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.sharedFiles)),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(l10n.sharedFilesHint),
            if (widget.share.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.shareImportError(widget.share.error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (var index = 0; index < widget.share.files.length; index++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _sent.contains(index)
                      ? Icons.check_circle
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(widget.share.files[index].name),
                subtitle: Text('${widget.share.files[index].size} B'),
                trailing: _current == index
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(),
                      )
                    : null,
              ),
            if (_sending) const LinearProgressIndicator(),
            const SizedBox(height: 20),
            if (widget.share.files.isNotEmpty &&
                _sent.length < widget.share.files.length)
              StreamBuilder<List<DiscoveredPeer>>(
                stream: manager.onPeersChanged,
                initialData: manager.availablePeers,
                builder: (context, snapshot) {
                  final peers = manager.availablePeers;
                  final selected = peers
                      .where((peer) => peer.peerId == _peerId)
                      .firstOrNull;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.lanDevices,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.refreshDevices,
                            onPressed:
                                !manager.isEnabled || _sending || refreshing
                                ? null
                                : () => _refreshDevices(),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                      if (refreshing) ...[
                        LinearProgressIndicator(value: progress.fraction),
                        const SizedBox(height: 8),
                        Text(
                          l10n.discoveryScanning(
                            progress.completed,
                            progress.total,
                            peers.length,
                          ),
                        ),
                      ],
                      if (peers.isEmpty && !refreshing)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            manager.isEnabled
                                ? l10n.shareNoDevices
                                : l10n.shareSyncDisabled,
                          ),
                        ),
                      for (final peer in peers)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            peer.peerId == _peerId
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                          ),
                          title: Text(peer.displayName),
                          subtitle: Text(peer.host),
                          onTap: _sending
                              ? null
                              : () => setState(() {
                                  if (_peerId != peer.peerId) _sent.clear();
                                  _peerId = peer.peerId;
                                }),
                        ),
                      OutlinedButton.icon(
                        onPressed: _sending
                            ? null
                            : () async {
                                await Navigator.push<void>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => Scaffold(
                                      appBar: AppBar(
                                        title: Text(l10n.lanDevices),
                                      ),
                                      body: const DevicesPage(),
                                    ),
                                  ),
                                );
                                if (mounted) {
                                  setState(() {});
                                  await _refreshDevices(automatic: true);
                                }
                              },
                        icon: const Icon(Icons.settings_ethernet),
                        label: Text(l10n.lanDevices),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _sending || selected == null
                            ? null
                            : () => _send(selected),
                        icon: const Icon(Icons.send),
                        label: Text(_sent.isEmpty ? l10n.send : l10n.retry),
                      ),
                    ],
                  );
                },
              ),
            TextButton(
              onPressed: _sending ? null : () => Navigator.pop(context),
              child: Text(
                _sent.length == widget.share.files.length && _sent.isNotEmpty
                    ? l10n.closeShare
                    : l10n.cancel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
