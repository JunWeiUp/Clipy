import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/database/file_transfer_repository.dart';

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

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
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
    if (_loading) return;
    _loading = true;
    final offset = reset ? 0 : _files.length;
    final page = await FileTransferRepository.instance.fetchPage(
      offset: offset,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      if (reset) _files.clear();
      _files.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _deleteFile(FileTransferRecord file) async {
    try {
      final ioFile = File(file.filePath);
      if (await ioFile.exists()) {
        await ioFile.delete();
      }
    } catch (_) {
      // Best-effort: drop the record even when the file itself
      // cannot be removed (e.g. shared storage without permission).
    }
    await FileTransferRepository.instance.deleteById(file.id);
    setState(() {
      _files.removeWhere((f) => f.id == file.id);
    });
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
      body: _files.isEmpty && !_loading
          ? Center(child: Text(l10n.noFilesReceived))
          : ListView.builder(
              controller: _scrollController,
              itemCount: _files.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _files.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final file = _files[index];
                final date = DateTime.fromMillisecondsSinceEpoch(
                  file.createdAt,
                );
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file.fileName),
                  subtitle: Text(
                    '${_formatSize(file.fileSize)} • ${l10n.fromSender(file.senderName)}\n${date.toString().split('.')[0]}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteFile(file),
                  ),
                  onTap: () => _openFolder(file.filePath),
                );
              },
            ),
    );
  }
}
