import 'package:flutter/material.dart';
import '../app_localizations.dart';
import '../clipboard_manager.dart';
import '../models.dart';

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

  final ScrollController _scrollController = ScrollController();
  final List<HistoryEntry> _entries = [];
  bool _loading = false;
  bool _hasMore = true;
  bool _pendingRefresh = false;

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
    _scrollController.dispose();
    super.dispose();
  }

  void _refreshFromDb() {
    if (!mounted) return;
    if (_loading) {
      _pendingRefresh = true;
      return;
    }
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
    final page = await ClipboardManager.instance.fetchPage(
      offset: offset,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      if (reset) _entries.clear();
      _entries.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
    if (_pendingRefresh) {
      _pendingRefresh = false;
      _loadMore(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_entries.isEmpty && !_loading) {
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.copiedToClipboard)),
              );
            }
          },
        );
      },
    );
  }
}

class MacHistoryTab extends StatelessWidget {
  const MacHistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    return PaginatedClipboardHistoryList(
      onFileTap: null,
    );
  }
}
