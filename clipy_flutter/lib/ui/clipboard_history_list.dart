import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../app_localizations.dart';
import '../clipboard_manager.dart';
import '../features/history/history_feed_controller.dart';
import '../models.dart';
import '../sync_manager.dart';
import 'app_components.dart';

class PaginatedClipboardHistoryList extends StatefulWidget {
  final void Function(HistoryEntry entry)? onFileTap;
  final HistoryFeedController? controller;
  final ValueNotifier<String>? filterNotifier;
  final TextEditingController? searchController;
  final FocusNode? searchFocus;
  final VoidCallback? onClearHistory;
  @visibleForTesting
  final bool? windowsLayout;
  const PaginatedClipboardHistoryList({
    super.key,
    this.onFileTap,
    this.controller,
    this.filterNotifier,
    this.searchController,
    this.searchFocus,
    this.onClearHistory,
    this.windowsLayout,
  });

  @override
  State<PaginatedClipboardHistoryList> createState() =>
      _PaginatedClipboardHistoryListState();
}

class _PaginatedClipboardHistoryListState
    extends State<PaginatedClipboardHistoryList> {
  final _scrollController = ScrollController();
  late final _searchController =
      widget.searchController ?? TextEditingController();
  late final _searchFocus = widget.searchFocus ?? FocusNode();
  late final HistoryFeedController _feed;
  Timer? _refreshTimer;
  Timer? _searchTimer;
  Timer? _copiedTimer;
  HistoryEntry? _copied;
  String? _selectedHistoryKey;

  @override
  void initState() {
    super.initState();
    _feed =
        widget.controller ??
        HistoryFeedController(ClipboardManager.instance.fetchPage);
    _feed.addListener(_changed);
    if (widget.searchController != null) {
      _searchController.addListener(_externalSearchChanged);
    }
    widget.filterNotifier?.addListener(_externalFilterChanged);
    if (_feed.entries.isEmpty) unawaited(_feed.refresh());
    _scrollController.addListener(_onScroll);
    if (widget.controller == null) {
      ClipboardManager.instance.addListener(_refreshFromDb);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // Small windows / large screens can fit an entire page without scrolling.
    // Continue only while content does not fill the viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _scrollController.hasClients &&
          !_feed.failed &&
          _scrollController.position.maxScrollExtent == 0 &&
          _feed.hasMore &&
          !_feed.loading) {
        unawaited(_feed.loadMore());
      }
    });
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      ClipboardManager.instance.removeListener(_refreshFromDb);
    }
    _feed.removeListener(_changed);
    widget.filterNotifier?.removeListener(_externalFilterChanged);
    if (widget.controller == null) _feed.dispose();
    _refreshTimer?.cancel();
    _searchTimer?.cancel();
    _copiedTimer?.cancel();
    _scrollController.dispose();
    _searchController.removeListener(_externalSearchChanged);
    if (widget.searchController == null) _searchController.dispose();
    if (widget.searchFocus == null) _searchFocus.dispose();
    super.dispose();
  }

  void _refreshFromDb() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      const Duration(milliseconds: 300),
      () => _feed.refresh(),
    );
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 240 && !_feed.failed) {
      unawaited(_feed.loadMore());
    }
  }

  void _externalSearchChanged() {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), _search);
  }

  void _externalFilterChanged() {
    final filter = widget.filterNotifier?.value;
    if (filter != null && filter != _feed.filter) _search(filter: filter);
  }

  void _search({String? filter}) {
    _searchTimer?.cancel();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    final next = filter ?? _feed.filter;
    unawaited(_feed.search(_searchController.text, next));
    widget.filterNotifier?.value = next;
  }

  Future<void> _copy(HistoryEntry entry) async {
    try {
      await ClipboardManager.instance.copyToClipboard(entry.item);
      if (!mounted) return;
      unawaited(HapticFeedback.selectionClick());
      setState(() => _copied = entry);
      showClipyMessage(context, context.l10n.copiedToClipboard);
      _copiedTimer?.cancel();
      _copiedTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = null);
      });
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.operationFailed);
    }
  }

  Future<void> _send(String text) async {
    final l10n = context.l10n;
    final peers = SyncManager.instance.availablePeers;
    if (peers.isEmpty) {
      showClipyMessage(context, l10n.noDevicesFound);
      return;
    }
    final selection = Theme.of(context).platform == TargetPlatform.iOS
        ? showCupertinoModalPopup<DiscoveredPeer>(
            context: context,
            builder: (sheetContext) => CupertinoActionSheet(
              title: Text(l10n.sendText),
              actions: [
                for (final peer in peers)
                  CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(sheetContext, peer),
                    child: Column(
                      children: [
                        Text(peer.displayName),
                        Text(peer.host, style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
              ],
              cancelButton: CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(sheetContext),
                child: Text(l10n.cancel),
              ),
            ),
          )
        : showModalBottomSheet<DiscoveredPeer>(
            context: context,
            isScrollControlled: true,
            builder: (sheetContext) => SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * .65,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        l10n.sendText,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    ...peers.map(
                      (p) => ListTile(
                        leading: const ClipyIcon(Icons.devices_rounded),
                        title: Text(p.displayName),
                        subtitle: Text(p.host),
                        onTap: () => Navigator.pop(sheetContext, p),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    final peer = await selection;
    if (peer == null || !mounted) return;
    try {
      final success = await SyncManager.instance.sendTextToPeer(
        text,
        peerId: peer.peerId,
      );
      if (mounted) {
        showClipyMessage(
          context,
          success ? l10n.textSentTo(peer.displayName) : l10n.sendFailed,
        );
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, l10n.sendFailed);
    }
  }

  Future<void> _preview(HistoryEntry entry) {
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    Widget content(BuildContext sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.preview,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (ios)
                    CupertinoButton(
                      padding: const EdgeInsets.all(4),
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 26,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: entry.item.type == 'image'
                      ? Image.file(
                          File(entry.item.value as String),
                          errorBuilder: (_, _, _) =>
                              Text(context.l10n.fileNotFound),
                        )
                      : SelectableText(
                          entry.item.type == 'fileURLs'
                              ? (entry.item.value as List<String>).join('\n')
                              : entry.item.value.toString(),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              if (entry.item.type == 'text' || Platform.isWindows)
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (ios)
                      CupertinoButton.filled(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _copy(entry);
                        },
                        child: Text(context.l10n.copyContent),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _copy(entry);
                        },
                        icon: const Icon(Icons.copy_rounded),
                        label: Text(context.l10n.copyContent),
                      ),
                    if (entry.item.type == 'text')
                      if (ios)
                        CupertinoButton(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _send(entry.item.value.toString());
                          },
                          child: Text(context.l10n.send),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _send(entry.item.value.toString());
                          },
                          icon: const Icon(Icons.send_outlined),
                          label: Text(context.l10n.send),
                        ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
    if (ios) {
      return showCupertinoModalPopup<void>(
        context: context,
        builder: (sheetContext) => CupertinoPopupSurface(
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            child: content(sheetContext),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: content,
    );
  }

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day == today) return context.l10n.today;
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return context.l10n.yesterday;
    }
    return MaterialLocalizations.of(context).formatMediumDate(date);
  }

  String _entryKey(HistoryEntry entry) =>
      entry.contentHash ??
      '${entry.date.microsecondsSinceEpoch}:${entry.item.type}:${entry.sourceApp}';

  Widget _windowsHistory(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final entries = _feed.entries;
    final selected =
        entries.where((e) => _entryKey(e) == _selectedHistoryKey).firstOrNull ??
        (entries.isEmpty ? null : entries.first);
    Widget list({bool narrow = false}) => Column(
      children: [
        if (widget.searchController == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: TextField(
              focusNode: _searchFocus,
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.searchHistory,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.clearSearch,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                          _search();
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _search(),
              onChanged: (_) {
                setState(() {});
                _searchTimer?.cancel();
                _searchTimer = Timer(
                  const Duration(milliseconds: 250),
                  _search,
                );
              },
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Row(
              children: [
                for (final filter in [
                  ('all', l10n.allItems),
                  ('today', l10n.today),
                  if (widget.filterNotifier == null) ...[
                    ('text', l10n.textItems),
                    ('links', l10n.linkItems),
                    ('images', l10n.imageItems),
                    ('files', l10n.fileItems),
                  ],
                ])
                  TextButton(
                    onPressed: () => _search(filter: filter.$1),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.onSurface,
                      shape: const RoundedRectangleBorder(),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _feed.filter == filter.$1
                                ? colors.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(
                        filter.$2,
                        style: TextStyle(
                          fontWeight: _feed.filter == filter.$1
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                if (widget.onClearHistory != null)
                  IconButton(
                    tooltip: l10n.clearHistory,
                    onPressed: widget.onClearHistory,
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: _feed.loading
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _feed.failed
                                  ? l10n.loadFailed
                                  : (_feed.query.isNotEmpty ||
                                            _feed.filter != 'all'
                                        ? l10n.nothingFound
                                        : l10n.noClipboardHistory),
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
                  key: const PageStorageKey('windows-clipboard-history'),
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(28, 0, 12, 20),
                  itemCount: entries.length + 1,
                  itemBuilder: (context, index) {
                    if (index == entries.length) {
                      if (_feed.failed) {
                        return TextButton(
                          onPressed: _feed.refresh,
                          child: Text(l10n.retry),
                        );
                      }
                      return _feed.loading
                          ? const Center(child: CircularProgressIndicator())
                          : const SizedBox(height: 8);
                    }
                    final entry = entries[index];
                    final isSelected =
                        selected != null &&
                        _entryKey(selected) == _entryKey(entry);
                    final type = entry.item.type;
                    final uri = type == 'text'
                        ? Uri.tryParse(entry.item.value.toString().trim())
                        : null;
                    final link =
                        uri?.scheme == 'http' || uri?.scheme == 'https';
                    final typeColor = link
                        ? const Color(0xFF0E9F8E)
                        : type == 'image'
                        ? const Color(0xFFC2410C)
                        : type == 'text'
                        ? colors.primary
                        : const Color(0xFF7C3AED);
                    final icon = link
                        ? Icons.link
                        : type == 'text'
                        ? Icons.notes
                        : type == 'image'
                        ? Icons.image_outlined
                        : Icons.folder_outlined;
                    final date = _dateLabel(entry.date);
                    final showDate =
                        index == 0 ||
                        _dateLabel(entries[index - 1].date) != date;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showDate)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                            child: Text(
                              date,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ),
                        Material(
                          color: isSelected
                              ? colors.onSurface.withValues(alpha: .07)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () {
                              setState(
                                () => _selectedHistoryKey = _entryKey(entry),
                              );
                              if (narrow) _preview(entry);
                            },
                            onDoubleTap: () => _copy(entry),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 3,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? colors.primary
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: typeColor.withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Icon(
                                      icon,
                                      size: 17,
                                      color: typeColor,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.item.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${entry.sourceApp ?? 'Clipy'} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(entry.date))}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        if (narrow) return list(narrow: true);
        return Row(
          children: [
            SizedBox(
              width: (constraints.maxWidth - 320).clamp(300, 420),
              child: list(),
            ),
            VerticalDivider(
              width: 1,
              color: colors.onSurface.withValues(alpha: .08),
            ),
            Expanded(
              child: selected == null
                  ? Center(child: Text(l10n.noClipboardHistory))
                  : _windowsPreview(selected),
            ),
          ],
        );
      },
    );
  }

  Widget _windowsPreview(HistoryEntry entry) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final isText = entry.item.type == 'text';
    final isFile =
        entry.item.type == 'fileURL' || entry.item.type == 'fileURLs';
    final value = entry.item.type == 'fileURLs'
        ? (entry.item.value as List<String>).join('\n')
        : entry.item.value.toString();
    final uri = isText ? Uri.tryParse(value.trim()) : null;
    final isLink = uri?.scheme == 'http' || uri?.scheme == 'https';
    final typeColor = isLink
        ? const Color(0xFF0E9F8E)
        : isText
        ? colors.primary
        : isFile
        ? const Color(0xFF7C3AED)
        : const Color(0xFFC2410C);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 36, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isLink
                          ? Icons.link
                          : isText
                          ? Icons.title
                          : isFile
                          ? Icons.folder_outlined
                          : Icons.image_outlined,
                      size: 13,
                      color: typeColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isLink
                          ? l10n.linkItems
                          : isText
                          ? l10n.textItems
                          : isFile
                          ? l10n.fileItems
                          : l10n.imageItems,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: typeColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (isText)
                Text(
                  l10n.historyCharacterCount(value.characters.length),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                border: Border.all(
                  color: colors.onSurface.withValues(alpha: .07),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: entry.item.type == 'image'
                    ? Image.file(
                        File(value),
                        errorBuilder: (_, _, _) => Text(l10n.fileNotFound),
                      )
                    : SelectableText(value),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final metadata in [
                (l10n.historySource, entry.sourceApp ?? 'Clipy'),
                (
                  l10n.historyCopiedAt,
                  '${MaterialLocalizations.of(context).formatMediumDate(entry.date)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(entry.date))}',
                ),
              ])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: colors.onSurface.withValues(alpha: .07),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            metadata.$1,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            metadata.$2,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _copy(entry),
                icon: const Icon(Icons.copy, size: 18),
                label: Text(l10n.copyContent),
              ),
              if (isText)
                OutlinedButton.icon(
                  onPressed: () => _send(value),
                  icon: const Icon(Icons.send_outlined, size: 18),
                  label: Text(l10n.send),
                ),
              if (isFile)
                OutlinedButton.icon(
                  onPressed: () => widget.onFileTap?.call(entry),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(l10n.openFolder),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    if (widget.windowsLayout ?? Platform.isWindows) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              _searchFocus.requestFocus(),
        },
        child: _windowsHistory(context),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Theme.of(context).platform == TargetPlatform.iOS
              ? CupertinoSearchTextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  placeholder: l10n.searchHistory,
                  onSubmitted: (_) => _search(),
                  onChanged: (_) {
                    setState(() {});
                    _searchTimer?.cancel();
                    _searchTimer = Timer(
                      const Duration(milliseconds: 250),
                      _search,
                    );
                  },
                  onSuffixTap: () {
                    _searchController.clear();
                    setState(() {});
                    _search();
                  },
                )
              : TextField(
                  focusNode: _searchFocus,
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: l10n.searchHistory,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.clearSearch,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                              _search();
                            },
                          ),
                  ),
                  onSubmitted: (_) => _search(),
                  onChanged: (_) {
                    setState(() {});
                    _searchTimer?.cancel();
                    _searchTimer = Timer(
                      const Duration(milliseconds: 250),
                      _search,
                    );
                  },
                ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(
            children: [
              for (final filter in [
                ('all', l10n.allItems),
                ('text', l10n.textItems),
                ('links', l10n.linkItems),
                ('files', l10n.fileItems),
                ('images', l10n.imageItems),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    selectedColor:
                        Theme.of(context).platform == TargetPlatform.iOS
                        ? colors.primary
                        : colors.primaryContainer,
                    labelStyle: TextStyle(
                      color:
                          Theme.of(context).platform == TargetPlatform.iOS &&
                              _feed.filter == filter.$1
                          ? Colors.white
                          : colors.onSurface,
                    ),
                    label: Text(filter.$2),
                    selected: _feed.filter == filter.$1,
                    onSelected: (_) => _search(filter: filter.$1),
                    showCheckmark: false,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _feed.entries.isEmpty
              ? (_feed.loading
                    ? const Center(child: CircularProgressIndicator())
                    : ClipyEmptyState(
                        icon: _feed.failed
                            ? Icons.cloud_off_rounded
                            : (_feed.query.isNotEmpty || _feed.filter != 'all'
                                  ? Icons.search_off_rounded
                                  : Icons.content_paste_rounded),
                        title: _feed.failed
                            ? l10n.loadFailed
                            : (_feed.query.isNotEmpty || _feed.filter != 'all'
                                  ? l10n.nothingFound
                                  : l10n.noClipboardHistory),
                        message: _feed.failed
                            ? l10n.retryHint
                            : (_feed.query.isNotEmpty || _feed.filter != 'all'
                                  ? l10n.changeSearchHint
                                  : Platform.isIOS
                                  ? l10n.iosHistoryEmptyHint
                                  : l10n.historyEmptyHint),
                        action: _feed.failed
                            ? FilledButton(
                                onPressed: _feed.refresh,
                                child: Text(l10n.retry),
                              )
                            : null,
                      ))
              : RefreshIndicator(
                  onRefresh: _feed.refresh,
                  child: ListView.builder(
                    key: const PageStorageKey('clipboard-history'),
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    itemCount: _feed.entries.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _feed.entries.length) {
                        if (_feed.failed) {
                          return Center(
                            child: TextButton(
                              onPressed: _feed.refresh,
                              child: Text(l10n.retry),
                            ),
                          );
                        }
                        return _feed.loading
                            ? const Padding(
                                padding: EdgeInsets.all(20),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : const SizedBox(height: 8);
                      }
                      final entry = _feed.entries[index];
                      final isFile =
                          entry.item.type == 'fileURL' ||
                          entry.item.type == 'fileURLs';
                      final isText = entry.item.type == 'text';
                      final uri = isText
                          ? Uri.tryParse(entry.item.value.toString().trim())
                          : null;
                      final isLink =
                          uri?.scheme == 'http' || uri?.scheme == 'https';
                      final icon = isFile
                          ? Icons.description_outlined
                          : isLink
                          ? Icons.link_rounded
                          : isText
                          ? Icons.notes_rounded
                          : Icons.image_outlined;
                      final label = _dateLabel(entry.date);
                      final showDate =
                          index == 0 ||
                          _dateLabel(_feed.entries[index - 1].date) != label;
                      final title = entry.item.title;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDate)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
                              child: Text(
                                label,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Card(
                              color:
                                  Theme.of(context).platform ==
                                      TargetPlatform.iOS
                                  ? colors.surfaceContainerLowest
                                  : colors.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  Theme.of(context).platform ==
                                          TargetPlatform.iOS
                                      ? 18
                                      : 24,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(
                                  Theme.of(context).platform ==
                                          TargetPlatform.iOS
                                      ? 18
                                      : 24,
                                ),
                                onTap: () {
                                  if (isFile) {
                                    widget.onFileTap?.call(entry);
                                  } else if (isText) {
                                    _copy(entry);
                                  } else {
                                    _preview(entry);
                                  }
                                },
                                onLongPress: () => _preview(entry),
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            icon,
                                            size: 18,
                                            color: colors.primary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              entry.sourceApp ?? 'Clipy',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelMedium
                                                  ?.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                          Text(
                                            MaterialLocalizations.of(
                                              context,
                                            ).formatTimeOfDay(
                                              TimeOfDay.fromDateTime(
                                                entry.date,
                                              ),
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        title,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.copyWith(height: 1.45),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              isFile
                                                  ? (entry.item.type ==
                                                            'fileURLs'
                                                        ? (entry.item.value
                                                                  as List<
                                                                    String
                                                                  >)
                                                              .first
                                                        : entry.item.value
                                                              .toString())
                                                  : isText
                                                  ? l10n.tapToCopy
                                                  : l10n.preview,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                          AnimatedSwitcher(
                                            duration:
                                                MediaQuery.disableAnimationsOf(
                                                  context,
                                                )
                                                ? Duration.zero
                                                : const Duration(
                                                    milliseconds: 180,
                                                  ),
                                            child: Icon(
                                              _copied == entry
                                                  ? Icons.check_rounded
                                                  : isFile
                                                  ? Icons.folder_open_rounded
                                                  : isText
                                                  ? Icons.copy_rounded
                                                  : Icons.open_in_full_rounded,
                                              key: ValueKey(_copied == entry),
                                              size: 18,
                                              color: colors.primary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class MacHistoryTab extends StatelessWidget {
  const MacHistoryTab({super.key});
  @override
  Widget build(BuildContext context) => const PaginatedClipboardHistoryList();
}
