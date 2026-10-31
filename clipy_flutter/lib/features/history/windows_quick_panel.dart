import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_localizations.dart';
import '../../clipboard_manager.dart';
import '../../models.dart';
import '../../ui/app_components.dart';
import 'history_feed_controller.dart';

/// Compact tray history, using the same paginated repository as the main view.
class WindowsQuickPanel extends StatefulWidget {
  const WindowsQuickPanel({
    super.key,
    required this.onOpenFull,
    this.controller,
    this.copy,
    this.paste,
    this.setPinned,
    this.onClose,
  });
  final VoidCallback onOpenFull;
  final VoidCallback? onClose;
  @visibleForTesting
  final HistoryFeedController? controller;
  @visibleForTesting
  final Future<void> Function(HistoryEntry)? copy;
  @visibleForTesting
  final Future<bool> Function()? paste;
  @visibleForTesting
  final Future<void> Function(bool)? setPinned;

  @override
  State<WindowsQuickPanel> createState() => _WindowsQuickPanelState();
}

class _WindowsQuickPanelState extends State<WindowsQuickPanel> {
  late final HistoryFeedController _feed;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  Timer? _refresh;
  Timer? _copyFeedback;
  bool _copied = false;
  bool _pinned = false;
  static const _tray = MethodChannel('com.clipyclone.clipy_android/tray');
  String? _copying;

  @override
  void initState() {
    super.initState();
    _feed =
        widget.controller ??
        HistoryFeedController(ClipboardManager.instance.fetchPage);
    _feed.addListener(_changed);
    _scroll.addListener(_loadMore);
    if (widget.controller == null) {
      ClipboardManager.instance.addListener(_historyChanged);
    }
    if (_feed.entries.isEmpty) unawaited(_feed.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _historyChanged() {
    _refresh?.cancel();
    _refresh = Timer(const Duration(milliseconds: 300), () => _feed.refresh());
  }

  void _loadMore() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 200 &&
        !_feed.failed) {
      unawaited(_feed.loadMore());
    }
  }

  void _applySearch({String? filter}) {
    _debounce?.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_feed.search(_search.text, filter ?? _feed.filter));
  }

  Future<void> _copy(HistoryEntry entry, {bool paste = true}) async {
    if (_copying != null) return;
    setState(
      () => _copying = entry.contentHash ?? entry.date.toIso8601String(),
    );
    try {
      if (widget.copy != null) {
        await widget.copy!(entry);
      } else {
        await ClipboardManager.instance.copyToClipboard(entry.item);
      }
      final pasted = !paste
          ? true
          : widget.paste != null
          ? await widget.paste!()
          : Platform.isWindows
          ? await _tray.invokeMethod<bool>('pasteQuick') ?? false
          : true;
      if (mounted && !pasted) {
        showClipyMessage(context, context.l10n.pasteUnavailable);
      }
      if (mounted) {
        setState(() => _copied = true);
        _copyFeedback?.cancel();
        _copyFeedback = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _copied = false);
        });
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    } finally {
      if (mounted) setState(() => _copying = null);
    }
  }

  Future<void> _close() async {
    try {
      if (widget.onClose != null) {
        widget.onClose!();
      } else {
        await _tray.invokeMethod<void>('dismissQuickPanel');
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  Future<void> _togglePinned() async {
    final next = !_pinned;
    try {
      if (widget.setPinned != null) {
        await widget.setPinned!(next);
      } else {
        await _tray.invokeMethod<void>('setQuickPinned', next);
      }
      if (mounted) setState(() => _pinned = next);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      ClipboardManager.instance.removeListener(_historyChanged);
    }
    _feed.removeListener(_changed);
    if (widget.controller == null) _feed.dispose();
    _debounce?.cancel();
    _refresh?.cancel();
    _copyFeedback?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/branding/clipy-logo.png',
                        width: 22,
                        height: 22,
                        excludeFromSemantics: true,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _copied ? l10n.copiedToClipboard : 'Clipy',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        tooltip: _pinned
                            ? l10n.unpinQuickPanel
                            : l10n.pinQuickPanel,
                        isSelected: _pinned,
                        onPressed: _togglePinned,
                        icon: Icon(
                          _pinned ? Icons.push_pin : Icons.push_pin_outlined,
                          size: 19,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.openMainWindow,
                        onPressed: widget.onOpenFull,
                        icon: const Icon(Icons.open_in_full, size: 19),
                      ),
                      IconButton(
                        tooltip: l10n.closeQuickPanel,
                        onPressed: _close,
                        icon: const Icon(Icons.close, size: 19),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: l10n.searchHistory,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      _debounce?.cancel();
                      _debounce = Timer(
                        const Duration(milliseconds: 250),
                        _applySearch,
                      );
                    },
                    onSubmitted: (_) => _applySearch(),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      for (final filter in [
                        ('all', l10n.allItems),
                        ('text', l10n.textItems),
                        ('images', l10n.imageItems),
                        ('files', l10n.fileItems),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(filter.$2),
                            shape: const StadiumBorder(),
                            selectedColor: colors.primary,
                            backgroundColor: Colors.transparent,
                            side: BorderSide(
                              color: _feed.filter == filter.$1
                                  ? colors.primary
                                  : colors.outlineVariant,
                            ),
                            labelStyle: TextStyle(
                              fontSize: 13,
                              color: _feed.filter == filter.$1
                                  ? colors.onPrimary
                                  : colors.onSurfaceVariant,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            showCheckmark: false,
                            selected: _feed.filter == filter.$1,
                            onSelected: (_) => _applySearch(filter: filter.$1),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _feed.entries.isEmpty && !_feed.loading
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _feed.failed
                                    ? l10n.loadFailed
                                    : (_feed.query.isEmpty &&
                                              _feed.filter == 'all'
                                          ? l10n.noClipboardHistory
                                          : l10n.nothingFound),
                              ),
                              if (_feed.failed)
                                TextButton(
                                  onPressed: _feed.refresh,
                                  child: Text(l10n.retry),
                                ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          itemCount:
                              _feed.entries.length +
                              (_feed.loading || _feed.failed ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _feed.entries.length) {
                              return _feed.failed
                                  ? TextButton(
                                      onPressed: _feed.refresh,
                                      child: Text(l10n.retry),
                                    )
                                  : const Center(
                                      child: CircularProgressIndicator(),
                                    );
                            }
                            final entry = _feed.entries[index];
                            final type = entry.item.type;
                            final icon = type == 'text'
                                ? Icons.notes
                                : type == 'image'
                                ? Icons.image_outlined
                                : Icons.folder_outlined;
                            return Card(
                              color: colors.surfaceContainerLow,
                              margin: const EdgeInsets.only(bottom: 6),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: _copying == null
                                    ? () => _copy(entry)
                                    : null,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    6,
                                    10,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                entry.item.title,
                                                maxLines: 3,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(height: 1.45),
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: l10n.copyContent,
                                            constraints: const BoxConstraints(
                                              minWidth: 32,
                                              minHeight: 32,
                                            ),
                                            padding: const EdgeInsets.all(6),
                                            onPressed: _copying == null
                                                ? () =>
                                                      _copy(entry, paste: false)
                                                : null,
                                            icon: const Icon(
                                              Icons.copy_outlined,
                                              size: 16,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (type == 'image')
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 6,
                                            right: 6,
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            child: Image.file(
                                              File(entry.item.value.toString()),
                                              height: 92,
                                              fit: BoxFit.cover,
                                              cacheHeight: 184,
                                              errorBuilder: (_, _, _) =>
                                                  SizedBox(
                                                    height: 48,
                                                    child: Center(
                                                      child: Icon(
                                                        icon,
                                                        color: colors
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                          ),
                                        ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Icon(
                                            icon,
                                            size: 13,
                                            color: colors.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              '${entry.sourceApp ?? 'Clipy'} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(entry.date))}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: widget.onOpenFull,
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: Text(l10n.openMainWindow),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
