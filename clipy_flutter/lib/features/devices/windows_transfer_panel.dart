import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../app_localizations.dart';
import '../../sync_manager.dart';
import '../../ui/app_components.dart';
import 'windows_transfer_controller.dart';

String windowsDeviceText(BuildContext context, String zh, String en) =>
    context.l10n.language == AppLanguage.zh ? zh : en;

class WindowsTransferPanel extends StatefulWidget {
  const WindowsTransferPanel({
    super.key,
    required this.peerId,
    required this.enabled,
    this.controller,
  });
  final String peerId;
  final bool enabled;
  final WindowsTransferController? controller;
  @override
  State<WindowsTransferPanel> createState() => _WindowsTransferPanelState();
}

class _WindowsTransferPanelState extends State<WindowsTransferPanel> {
  bool _hover = false;
  WindowsTransferController get _controller =>
      widget.controller ?? WindowsTransferController.instance;

  Future<void> _sendPaths(List<String> paths, {String? target}) async {
    // Capture the target before any await; changing selection never redirects a batch.
    final peerId = target ?? widget.peerId;
    if (paths.length > 32) {
      showClipyMessage(
        context,
        windowsDeviceText(
          context,
          '每次最多选择 32 个文件',
          'Select up to 32 files at a time',
        ),
      );
      return;
    }
    if (!widget.enabled) return;
    final controller = _controller;
    for (final path in paths) {
      // Explicit sends continue for the captured peer when the page is hidden.
      if (!controller.canSendTo(peerId)) {
        if (mounted) {
          showClipyMessage(
            context,
            windowsDeviceText(
              context,
              '正在发送的文件较多，请稍后重试剩余文件',
              'Too many active transfers. Retry the remaining files shortly.',
            ),
          );
        }
        break;
      }
      if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
        if (mounted) {
          showClipyMessage(
            context,
            windowsDeviceText(
              context,
              '文件夹请先压缩为 ZIP',
              'Compress folders into ZIP files first',
            ),
          );
        }
        continue;
      }
      if (await File(path).length() > SyncManager.fileMaxBytes) {
        if (mounted) {
          showClipyMessage(
            context,
            windowsDeviceText(
              context,
              '单个文件最大 1 GB',
              'Maximum file size: 1 GB',
            ),
          );
        }
        continue;
      }
      await controller.sendPath(path, peerId);
    }
  }

  Future<void> _pick() async {
    final peerId = widget.peerId;
    try {
      final result = await FilePicker.pickFiles(allowMultiple: true);
      if (result == null || !mounted) return;
      await _sendPaths(
        result.files.map((f) => f.path).whereType<String>().toList(),
        target: peerId,
      );
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.sendFailed);
    }
  }

  String _bytes(num value) => value >= 1024 * 1024
      ? '${(value / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(value / 1024).toStringAsFixed(0)} KB';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final enabled = widget.enabled && _controller.canSendTo(widget.peerId);
      final rows = _controller.rows
          .where((r) => r.peerId == widget.peerId)
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropTarget(
            enable: enabled,
            onDragEntered: (_) => setState(() => _hover = true),
            onDragExited: (_) => setState(() => _hover = false),
            onDragDone: (details) async {
              setState(() => _hover = false);
              try {
                await _sendPaths(details.files.map((f) => f.path).toList());
              } catch (_) {
                if (context.mounted) {
                  showClipyMessage(context, context.l10n.sendFailed);
                }
              }
            },
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: _hover ? .14 : .04),
                border: Border.all(
                  color: enabled ? colors.primary : colors.outlineVariant,
                  width: _hover ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.drive_folder_upload_outlined,
                        size: 30,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          windowsDeviceText(
                            context,
                            '拖放文件到这里',
                            'Drop files here',
                          ),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    windowsDeviceText(
                      context,
                      '单个文件最大 1 GB · 文件夹请先压缩为 ZIP',
                      'Up to 1 GB per file · Compress folders into ZIP files first',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: enabled ? _pick : null,
                    icon: const Icon(Icons.attach_file),
                    label: Text(context.l10n.sendFile),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            context.l10n.fileTransfer,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                windowsDeviceText(context, '暂无传输记录', 'No transfers yet'),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          if (rows.isNotEmpty)
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i != 0) const Divider(height: 1),
                    _row(context, rows[i]),
                  ],
                ],
              ),
            ),
        ],
      );
    },
  );

  Widget _row(BuildContext context, WindowsTransfer row) {
    final active = row.status == WindowsTransferStatus.sending;
    final failed = row.status == WindowsTransferStatus.failed;
    final cancelled = row.status == WindowsTransferStatus.cancelled;
    final label = switch (row.status) {
      WindowsTransferStatus.sending =>
        row.bytes == 0
            ? windowsDeviceText(context, '准备传输…', 'Preparing…')
            : row.fraction >= 1
            ? windowsDeviceText(context, '等待接收确认…', 'Waiting for confirmation…')
            : '${(row.fraction * 100).floor()}% · ${_bytes(row.bytesPerSecond)}/s',
      WindowsTransferStatus.completed =>
        '${windowsDeviceText(context, row.outgoing ? '已送达' : '已接收', row.outgoing ? 'Delivered' : 'Received')} · ${_bytes(row.total)}',
      WindowsTransferStatus.failed => windowsDeviceText(
        context,
        '传输失败',
        'Transfer failed',
      ),
      WindowsTransferStatus.cancelled => windowsDeviceText(
        context,
        '本机已停止发送',
        'Sending stopped locally',
      ),
    };
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            row.outgoing
                ? Icons.upload_file_outlined
                : Icons.file_download_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: failed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                      value: row.bytes == 0 || row.fraction >= 1
                          ? null
                          : row.fraction,
                    ),
                  ),
              ],
            ),
          ),
          if (active && row.outgoing && row.path != null)
            IconButton(
              tooltip: context.l10n.cancel,
              onPressed: () => _controller.cancel(row),
              icon: const Icon(Icons.close, size: 18),
            ),
          if ((failed || cancelled) && row.path != null)
            TextButton(
              onPressed: widget.enabled && _controller.canSendTo(row.peerId)
                  ? () => _controller.retry(row)
                  : null,
              child: Text(context.l10n.retry),
            ),
          if (row.status == WindowsTransferStatus.completed)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(
                Icons.check_circle_outline,
                color: Colors.green,
                size: 20,
              ),
            ),
        ],
      ),
    );
  }
}
