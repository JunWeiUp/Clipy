import 'dart:async';
import 'package:flutter/material.dart';
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
  const PaginatedClipboardHistoryList({
    super.key,
    this.onFileTap,
    this.controller,
  });

  @override
  State<PaginatedClipboardHistoryList> createState() =>
      _PaginatedClipboardHistoryListState();
}

class _PaginatedClipboardHistoryListState
    extends State<PaginatedClipboardHistoryList> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  late final HistoryFeedController _feed;
  Timer? _refreshTimer;
  Timer? _searchTimer;
  Timer? _copiedTimer;
  HistoryEntry? _copied;

  @override
  void initState() {
    super.initState();
    _feed =
        widget.controller ??
        HistoryFeedController(ClipboardManager.instance.fetchPage);
    _feed.addListener(_changed);
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
    if (widget.controller == null) _feed.dispose();
    _refreshTimer?.cancel();
    _searchTimer?.cancel();
    _copiedTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
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

  void _search({String? filter}) {
    _searchTimer?.cancel();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    unawaited(_feed.search(_searchController.text, filter ?? _feed.filter));
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
    final peer = await showModalBottomSheet<DiscoveredPeer>(
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

  Future<void> _preview(HistoryEntry entry) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.preview,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    entry.item.type == 'text' || entry.item.type == 'fileURL'
                        ? entry.item.value.toString()
                        : entry.item.title,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (entry.item.type == 'text')
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _copy(entry);
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(context.l10n.copyContent),
                    ),
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
    ),
  );

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: TextField(
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
                        _search();
                      },
                    ),
            ),
            onSubmitted: (_) => _search(),
            onChanged: (_) {
              setState(() {});
              _searchTimer?.cancel();
              _searchTimer = Timer(const Duration(milliseconds: 250), _search);
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
                      final isFile = entry.item.type == 'fileURL';
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
                      final title = isFile
                          ? entry.item.value.toString().split('/').last
                          : entry.item.title;
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
                              child: InkWell(
                                borderRadius: BorderRadius.circular(24),
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
                                                  ? entry.item.value.toString()
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
