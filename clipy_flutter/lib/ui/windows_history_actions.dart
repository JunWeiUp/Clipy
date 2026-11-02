import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_localizations.dart';
import '../models.dart';
import '../sync_manager.dart';
import 'app_components.dart';

/// A desktop picker shared by text, image and file-location history entries.
/// Sends existing files through the bounded transfer pipeline; never serializes
/// their contents into a text frame or pretends directories are supported.
Future<void> sendWindowsHistoryEntry(
  BuildContext context,
  HistoryEntry entry,
) async {
  final l10n = context.l10n;
  final peers = SyncManager.instance.availablePeers;
  if (peers.isEmpty) {
    showClipyMessage(context, l10n.noDevicesFound);
    return;
  }
  final peer = await showDialog<DiscoveredPeer>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.send),
      content: SizedBox(
        width: 360,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final peer in peers)
                ListTile(
                  leading: const Icon(Icons.devices_outlined),
                  title: Text(peer.displayName),
                  subtitle: Text(peer.host),
                  onTap: () => Navigator.pop(dialogContext, peer),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
      ],
    ),
  );
  if (peer == null || !context.mounted) return;
  try {
    bool success;
    if (entry.item.type == 'text') {
      success = await SyncManager.instance.sendTextToPeer(
        entry.item.value.toString(),
        peerId: peer.peerId,
      );
    } else {
      final paths = entry.item.type == 'fileURLs'
          ? (entry.item.value as List).cast<String>()
          : [entry.item.value.toString()];
      // Validate the whole selection before sending, so a missing second file
      // does not leave the user with an unexplained partially sent selection.
      for (final path in paths) {
        if (await Directory(path).exists()) {
          if (context.mounted) {
            showClipyMessage(
              context,
              l10n.language == AppLanguage.zh
                  ? '请先将文件夹压缩为 ZIP，再发送文件。'
                  : 'Compress the folder to a ZIP file before sending.',
            );
          }
          return;
        }
        if (!await File(path).exists()) {
          if (context.mounted) showClipyMessage(context, l10n.fileNotFound);
          return;
        }
      }
      success = paths.isNotEmpty;
      for (final path in paths) {
        if (!await SyncManager.instance.sendFileToPeer(
          File(path),
          peerId: peer.peerId,
        )) {
          success = false;
          break;
        }
      }
    }
    if (context.mounted) {
      showClipyMessage(
        context,
        success
            ? (entry.item.type == 'text'
                  ? l10n.textSentTo(peer.displayName)
                  : l10n.fileSentTo(peer.displayName))
            : l10n.sendFailed,
      );
    }
  } catch (_) {
    if (context.mounted) showClipyMessage(context, l10n.sendFailed);
  }
}

/// Only the selected preview owns its metadata request. No image cache, timer
/// or decoded full-size bitmap remains when selection/window changes.
class WindowsHistoryMediaMetadata extends StatefulWidget {
  const WindowsHistoryMediaMetadata({super.key, required this.entry});
  final HistoryEntry entry;

  @override
  State<WindowsHistoryMediaMetadata> createState() =>
      _WindowsHistoryMediaMetadataState();
}

class _WindowsHistoryMediaMetadataState
    extends State<WindowsHistoryMediaMetadata> {
  late Future<String?> _metadata = _load();

  @override
  void didUpdateWidget(covariant WindowsHistoryMediaMetadata oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.item.value != widget.entry.item.value ||
        oldWidget.entry.date != widget.entry.date) {
      _metadata = _load();
    }
  }

  Future<String?> _load() async {
    final entry = widget.entry;
    if (entry.item.type != 'image') return null;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      final path = entry.item.value.toString();
      final bytes = await File(path).length();
      buffer = await ui.ImmutableBuffer.fromFilePath(path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = bytes >= 1024 * 1024
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
          : '${(bytes / 1024).ceil()} KB';
      return '${descriptor.width} × ${descriptor.height} · $size';
    } catch (_) {
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _metadata,
    builder: (context, snapshot) => snapshot.data == null
        ? const SizedBox.shrink()
        : Text(
            snapshot.data!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
  );
}
