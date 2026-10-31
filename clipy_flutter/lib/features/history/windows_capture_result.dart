import 'dart:io';
import 'package:flutter/material.dart';

import '../../app_localizations.dart';

class WindowsCaptureResult extends StatelessWidget {
  const WindowsCaptureResult({
    super.key,
    required this.path,
    required this.copied,
    required this.onClose,
    required this.onSave,
    required this.onReveal,
    required this.onSend,
  });
  final String path;
  final bool copied;
  final VoidCallback onClose;
  final VoidCallback onSave;
  final VoidCallback onReveal;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    copied ? Icons.check_circle_outline : Icons.error_outline,
                    color: copied
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      copied ? l10n.screenshotSaved : l10n.screenshotCopyFailed,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          Center(child: Text(l10n.fileNotFound)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 4,
                runSpacing: 4,
                children: [
                  FilledButton.icon(
                    onPressed: onSave,
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: Text(l10n.saveAs),
                  ),
                  OutlinedButton.icon(
                    onPressed: onReveal,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: Text(l10n.openFolder),
                  ),
                  OutlinedButton.icon(
                    onPressed: onSend,
                    icon: const Icon(Icons.send_outlined, size: 16),
                    label: Text(l10n.send),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
