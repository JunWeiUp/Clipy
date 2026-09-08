import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/database/file_transfer_repository.dart';
import '../../sync_manager.dart';
import '../../ui/app_components.dart';

class ReceivedFilesPage extends StatefulWidget {
  const ReceivedFilesPage({super.key});

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  final List<FileTransferRecord> _files = [];
  bool _loading = false;
  bool _hasMore = true;
  bool _failed = false;
  bool _refreshPending = false;
  final Set<int> _deleting = {};
  StreamSubscription? _received;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _received = SyncManager.instance.onFileReceived.listen(
      (_) => _loadMore(reset: true),
    );
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _received?.cancel();
    _scrollController.dispose();
    super.dispose();
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
      _refreshPending |= reset;
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await FileTransferRepository.instance.fetchPage(
        offset: reset ? 0 : _files.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _files.clear();
        _files.addAll(page);
        _hasMore = page.length == _pageSize;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_loadMore(reset: true));
        }
      }
    }
  }

  Future<void> _deleteFile(FileTransferRecord file) async {
    if (_deleting.contains(file.id)) return;
    final confirmed = await confirmRemoval(
      context,
      title: context.l10n.delete,
      message: context.l10n.deleteFileConfirm,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting.add(file.id));
    try {
      final ioFile = File(file.filePath);
      if (await ioFile.exists()) await ioFile.delete();
      await FileTransferRepository.instance.deleteById(file.id);
      if (mounted) await _loadMore(reset: true);
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.fileDeleteFailed);
    } finally {
      if (mounted) setState(() => _deleting.remove(file.id));
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static const _channel = MethodChannel(
    'com.clipyclone.clipy_android/open_folder',
  );

  Future<void> _openFolder(String filePath) async {
    try {
      await _channel.invokeMethod('openFolder', {'path': filePath});
    } on PlatformException catch (e) {
      if (!mounted) return;
      final message = e.code == 'FILE_NOT_FOUND'
          ? context.l10n.fileNotFound
          : e.code == 'NO_ACTIVITY'
          ? context.l10n.noFileManager
          : context.l10n.couldNotOpenFolder(e.code);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotOpenFolder(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.receivedFiles)),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Text(
                l10n.filesHint,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: _files.isEmpty
                  ? (_loading
                        ? const Center(child: CircularProgressIndicator())
                        : ClipyEmptyState(
                            icon: _failed
                                ? Icons.cloud_off_rounded
                                : Icons.folder_open_rounded,
                            title: _failed
                                ? l10n.loadFailed
                                : l10n.noFilesReceived,
                            message: _failed
                                ? l10n.retryHint
                                : l10n.filesEmptyHint,
                            action: _failed
                                ? FilledButton(
                                    onPressed: () => _loadMore(reset: true),
                                    child: Text(l10n.retry),
                                  )
                                : null,
                          ))
                  : RefreshIndicator(
                      onRefresh: () => _loadMore(reset: true),
                      child: ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: _files.length + 1,
                        itemBuilder: (context, index) {
                          if (index >= _files.length) {
                            if (_failed) {
                              return TextButton(
                                onPressed: _loadMore,
                                child: Text(l10n.retry),
                              );
                            }
                            return _loading
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  )
                                : const SizedBox.shrink();
                          }
                          final file = _files[index];
                          final date = DateTime.fromMillisecondsSinceEpoch(
                            file.createdAt,
                          );
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Card(
                              child: ListTile(
                                leading: const ClipyIcon(
                                  Icons.description_outlined,
                                ),
                                title: Text(
                                  file.fileName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_formatSize(file.fileSize)} · ${l10n.fromSender(file.senderName)}\n${MaterialLocalizations.of(context).formatMediumDate(date)}',
                                ),
                                trailing: IconButton(
                                  tooltip: l10n.delete,
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                  ),
                                  onPressed: _deleting.contains(file.id)
                                      ? null
                                      : () => _deleteFile(file),
                                ),
                                onTap: () => _openFolder(file.filePath),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
