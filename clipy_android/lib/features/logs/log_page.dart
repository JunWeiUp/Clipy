import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipy_android/log_manager.dart';
import 'package:clipy_android/app_localizations.dart';
import '../../ui/app_components.dart';

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
  bool _failed = false;
  bool _pendingRefresh = false;

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
    if (_loading) {
      _pendingRefresh |= reset;
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await LogManager.instance.fetchPage(
        offset: reset ? 0 : _logs.length,
        limit: _pageSize,
      );
      if (mounted) {
        setState(() {
          if (reset) _logs.clear();
          _logs.addAll(page.map((r) => r.formatted));
          _hasMore = page.length == _pageSize;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_pendingRefresh) {
          _pendingRefresh = false;
          unawaited(_loadMore(reset: true));
        }
      }
    }
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
              final confirmed = await confirmRemoval(
                context,
                title: l10n.clearLogs,
                message: l10n.clearLogsConfirm,
              );
              if (!confirmed || !context.mounted) return;
              try {
                await LogManager.instance.clear();
              } catch (_) {
                if (context.mounted) {
                  showClipyMessage(context, l10n.operationFailed);
                }
              }
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
          ? ClipyEmptyState(
              icon: Icons.article_outlined,
              title: _failed ? l10n.loadFailed : l10n.noLogs,
              message: _failed ? l10n.retryHint : l10n.appRuntimeLogs,
              action: _failed
                  ? FilledButton(
                      onPressed: () => _loadMore(reset: true),
                      child: Text(l10n.retry),
                    )
                  : null,
            )
          : ListView.builder(
              controller: _scrollController,
              reverse: true,
              itemCount: _logs.length + (_hasMore || _failed ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _logs.length) {
                  if (_failed) {
                    return Center(
                      child: TextButton(
                        onPressed: () => _loadMore(reset: true),
                        child: Text(l10n.retry),
                      ),
                    );
                  }
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final log = _logs[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20.0,
                    vertical: 8.0,
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
