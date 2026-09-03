import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipy_android/log_manager.dart';
import 'package:clipy_android/app_localizations.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  static const _pageSize = 100;

  final ScrollController _scrollController = ScrollController();
  final List<String> _logs = [];
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
    LogManager.instance.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    LogManager.instance.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (!mounted) return;
    _logs.clear();
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
    final offset = reset ? 0 : _logs.length;
    final page = await LogManager.instance.fetchPage(
      offset: offset,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      if (reset) _logs.clear();
      _logs.addAll(page.map((r) => r.formatted));
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appLogs),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              await LogManager.instance.clear();
            },
            tooltip: l10n.clearLogs,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () async {
              final count = await LogManager.instance.count();
              final buffer = StringBuffer();
              var offset = 0;
              while (offset < count) {
                final page = await LogManager.instance.fetchPage(
                  offset: offset,
                  limit: 200,
                );
                for (final record in page) {
                  buffer.writeln(record.formatted);
                }
                offset += page.length;
                if (page.isEmpty) break;
              }
              await Clipboard.setData(ClipboardData(text: buffer.toString()));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l10n.logsCopied)));
              }
            },
            tooltip: l10n.copyAll,
          ),
        ],
      ),
      body: _logs.isEmpty && !_loading
          ? Center(child: Text(l10n.noLogs))
          : ListView.builder(
              controller: _scrollController,
              reverse: true,
              itemCount: _logs.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _logs.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final log = _logs[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12.0,
                    vertical: 4.0,
                  ),
                  child: Text(
                    log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
