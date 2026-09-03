import 'dart:async';
import 'package:flutter/material.dart';
import '../app_localizations.dart';
import '../clipboard_manager.dart';
import '../log_manager.dart';
import '../models.dart';
import '../sync_manager.dart';

class PaginatedClipboardHistoryList extends StatefulWidget {
  final void Function(HistoryEntry entry)? onFileTap;

  const PaginatedClipboardHistoryList({super.key, this.onFileTap});

  @override
  State<PaginatedClipboardHistoryList> createState() =>
      _PaginatedClipboardHistoryListState();
}

class _PaginatedClipboardHistoryListState
    extends State<PaginatedClipboardHistoryList> {
  static const _pageSize = 50;
  // Coalesce a burst of ClipboardManager notifications (e.g. a reconnect-driven
  // pending-frame resend that fires one notify per frame) into a single list
  // rebuild. Without this, N notifies => N full clear+rebuild passes — a visible
  // refresh storm.
  static const _refreshDebounce = Duration(milliseconds: 300);

  final ScrollController _scrollController = ScrollController();
  final List<HistoryEntry> _entries = [];
  bool _loading = false;
  bool _hasMore = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
    ClipboardManager.instance.addListener(_refreshFromDb);
  }

  @override
  void dispose() {
    ClipboardManager.instance.removeListener(_refreshFromDb);
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _refreshFromDb() {
    if (!mounted) return;
    // Debounce: a rapid burst of notifications only schedules one rebuild once
    // the burst settles. Each new notification reschedules the timer.
    _refreshTimer?.cancel();
    _refreshTimer = Timer(_refreshDebounce, _applyRefresh);
  }

  void _applyRefresh() {
    if (!mounted) return;
    // If a load is in progress, do nothing here — the debounce timer in
    // _refreshFromDb will re-fire _applyRefresh once the current load settles
    // and the next notification arrives. This avoids the old _pendingRefresh
    // self-recursion that caused the endless refresh cascade.
    if (_loading) return;
    _hasMore = true;
    _loadMore(reset: true);
  }

  void _onScroll() {
    if (!_hasMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore({bool reset = false}) async {
    if (_loading) return;
    _loading = true;
    final offset = reset ? 0 : _entries.length;
    List<HistoryEntry> page;
    try {
      page = await ClipboardManager.instance.fetchPage(
        offset: offset,
        limit: _pageSize,
      );
    } catch (e) {
      // Database not ready / locked / corrupted — must reset _loading or the
      // UI spins forever (empty list + _loading=true renders an endless
      // CircularProgressIndicator at the bottom of an empty ListView).
      appLog('_loadMore fetchPage error: $e', level: 'warning');
      if (mounted) {
        setState(() {
          _loading = false;
          _hasMore = false;
        });
      }
      return;
    }
    if (!mounted) {
      _loading = false;
      return;
    }
    setState(() {
      if (reset) {
        if (_entriesSameContent(page)) {
          _loading = false;
          return;
        }
        _entries.clear();
      }
      _entries.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  /// True if [page] contains the same content hashes as the currently
  /// displayed entries (order-independent). Used to suppress a pointless
  /// rebuild during a notify storm. Order-insensitive because insertBatch uses
  /// INSERT OR IGNORE (existing rows keep their created_at), but a genuinely
  // new entry landing at the top is a real change worth showing.
  bool _entriesSameContent(List<HistoryEntry> page) {
    if (page.length != _entries.length) return false;
    final current = _entries.map((e) => e.contentHash).toSet();
    for (final e in page) {
      if (!current.contains(e.contentHash)) return false;
    }
    return true;
  }

  Future<void> _showSendTextSheet(BuildContext context, String text) async {
    final l10n = context.l10n;
    final peers = SyncManager.instance.availablePeers;
    if (peers.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.noDevicesFound)));
      return;
    }

    final peer = await showModalBottomSheet<DiscoveredPeer>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.sendText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ...peers.map((p) {
              final shortId = p.peerId.length > 8
                  ? p.peerId.substring(0, 8)
                  : p.peerId;
              return ListTile(
                leading: const Icon(Icons.devices),
                title: Text(p.displayName),
                subtitle: Text(
                  shortId,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                onTap: () => Navigator.pop(sheetContext, p),
              );
            }),
          ],
        ),
      ),
    );

    if (peer == null || !context.mounted) return;
    final success = await SyncManager.instance.sendTextToPeer(
      text,
      peerId: peer.peerId,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? l10n.textSentTo(peer.displayName) : l10n.sendFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Empty + loading: show a centered spinner instead of an empty ListView
    // with a bottom CircularProgressIndicator (which looks like endless
    // spinning on a blank screen — the "一直转圈圈" symptom).
    if (_entries.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          l10n.noClipboardHistory,
          style: TextStyle(color: Colors.grey[500], fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _entries.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _entries.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final entry = _entries[index];
        final isFile = entry.item.type == 'fileURL';
        return ListTile(
          leading: Icon(
            isFile ? Icons.insert_drive_file_outlined : Icons.short_text,
            color: isFile ? Colors.blue : null,
          ),
          title: Text(
            entry.item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            l10n.sourceAndDate(
              entry.sourceApp,
              entry.date.toString().split('.')[0],
            ),
          ),
          onTap: () {
            if (isFile) {
              widget.onFileTap?.call(entry);
            } else {
              ClipboardManager.instance.copyToClipboard(entry.item);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(l10n.copiedToClipboard)));
            }
          },
          onLongPress: !isFile && entry.item.type == 'text'
              ? () => _showSendTextSheet(context, entry.item.value as String)
              : null,
        );
      },
    );
  }
}

class MacHistoryTab extends StatelessWidget {
  const MacHistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const PaginatedClipboardHistoryList(onFileTap: null);
  }
}
