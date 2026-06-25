import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'clipboard_manager.dart';
import 'sync_manager.dart';
import 'transfer_manager.dart';
import 'notification_manager.dart';
import 'notification_sync_page.dart';
import 'collector_manager.dart';
import 'collector_page.dart';
import 'notification_health_monitor.dart';
import 'log_manager.dart';
import 'models.dart';
import 'app_localizations.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await ClipboardManager.instance.init();
  } catch (e) {
    debugPrint('ClipboardManager init error: $e');
  }
  
  try {
    await SnippetManager.instance.init();
  } catch (e) {
    debugPrint('SnippetManager init error: $e');
  }
  
  try {
    await TransferManager.instance.init();
  } catch (e) {
    debugPrint('TransferManager init error: $e');
  }
  
  try {
    await SyncManager.instance.init();
  } catch (e) {
    debugPrint('SyncManager init error: $e');
  }
  
  try {
    await NotificationManager.instance.init();
  } catch (e) {
    debugPrint('NotificationManager init error: $e');
  }

  try {
    await CollectorManager.instance.init();
  } catch (e) {
    debugPrint('CollectorManager init error: $e');
  }

  try {
    NotificationHealthMonitor.instance.start();
  } catch (e) {
    debugPrint('NotificationHealthMonitor init error: $e');
  }
  
  try {
    await AppLanguageController.instance.init();
  } catch (e) {
    debugPrint('AppLanguageController init error: $e');
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguageController.instance,
      builder: (context, _) {
        final strings = AppLanguageController.instance.strings;
        return MaterialApp(
          title: strings.appTitle,
          locale: AppLanguageController.instance.locale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(
            primarySwatch: Colors.blue,
            useMaterial3: true,
          ),
          home: Platform.isMacOS ? const MacHomePage() : const HomePage(),
        );
      },
    );
  }
}

class MacHomePage extends StatefulWidget {
  const MacHomePage({super.key});

  @override
  State<MacHomePage> createState() => _MacHomePageState();
}

class _MacHomePageState extends State<MacHomePage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    ClipboardManager.instance.onHistoryChanged = _handleDataChanged;
    SnippetManager.instance.onSnippetsChanged = _handleDataChanged;
    TransferManager.instance.onItemsChanged = (_) => _handleDataChanged();
  }

  @override
  void dispose() {
    ClipboardManager.instance.onHistoryChanged = null;
    SnippetManager.instance.onSnippetsChanged = null;
    TransferManager.instance.onItemsChanged = null;
    _tabController.dispose();
    super.dispose();
  }

  void _handleDataChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => _switchTab(2),
            tooltip: l10n.transferStation,
          ),
          IconButton(
            icon: const Icon(Icons.snippet_folder_outlined),
            onPressed: () => _switchTab(1),
            tooltip: l10n.snippets,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: () => _switchTab(3),
            tooltip: l10n.preferences,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => ClipboardManager.instance.clearHistory(),
            tooltip: l10n.clearHistory,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.history),
            Tab(text: l10n.snippets),
            Tab(text: l10n.transferStation),
            Tab(text: l10n.preferences),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          MacHistoryTab(),
          MacSnippetsTab(),
          MacTransferTab(),
          MacSettingsTab(),
        ],
      ),
    );
  }

  void _switchTab(int index) {
    if (index >= 0 && index < _tabController.length) {
      _tabController.animateTo(index);
    }
  }
}

class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appLogs),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => LogManager.instance.clear(),
            tooltip: l10n.clearLogs,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final allLogs = LogManager.instance.logs.join('\n');
              Clipboard.setData(ClipboardData(text: allLogs));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.logsCopied)),
              );
            },
            tooltip: l10n.copyAll,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: LogManager.instance,
        builder: (context, _) {
          final logs = LogManager.instance.logs;
          if (logs.isEmpty) {
            return Center(child: Text(l10n.noLogs));
          }
          return ListView.builder(
            reverse: true,
            itemCount: logs.length,
            itemBuilder: (context, index) {
              // Show newest logs first
              final log = logs[logs.length - 1 - index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                child: Text(
                  log,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class MacHistoryTab extends StatelessWidget {
  const MacHistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final history = ClipboardManager.instance.history;
    if (history.isEmpty) {
      return Center(child: Text(l10n.noClipboardHistory));
    }

    final sections = <Widget>[];
    for (var i = 0; i < history.length; i += 10) {
      final end = (i + 10) > history.length ? history.length : (i + 10);
      final group = history.sublist(i, end);
      sections.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            l10n.historyRange(i + 1, end),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      );
      for (final entry in group) {
        sections.add(
          ListTile(
            leading: _iconForItem(entry.item),
            title: Text(
              entry.item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(l10n.sourceAndDate(entry.sourceApp, entry.date.toString().split('.')[0])),
            onTap: () {
              ClipboardManager.instance.copyToClipboard(entry.item);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.copiedToClipboard)),
              );
            },
          ),
        );
      }
    }

    return ListView(children: sections);
  }

  Widget _iconForItem(HistoryItem item) {
    switch (item.type) {
      case 'image':
        return const Icon(Icons.image_outlined);
      case 'rtf':
        return const Icon(Icons.description_outlined);
      case 'pdf':
        return const Icon(Icons.picture_as_pdf_outlined);
      case 'fileURL':
        return const Icon(Icons.insert_drive_file_outlined);
      default:
        return const Icon(Icons.short_text);
    }
  }
}

class MacSnippetsTab extends StatelessWidget {
  const MacSnippetsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manager = SnippetManager.instance;
    final folders = manager.folders;
    if (folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () => _showAddFolderDialog(context),
              child: Text(l10n.addSnippetFolder),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _showImportXmlDialog(context),
              child: Text(l10n.importXml),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.snippetFolders,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton(
                onPressed: () => _showImportXmlDialog(context),
                child: Text(l10n.importXml),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _showAddFolderDialog(context),
                child: Text(l10n.addFolder),
              ),
            ],
          ),
        ),
        ...folders.map((folder) {
          return ExpansionTile(
            title: Text(folder.title),
            leading: Icon(folder.isEnabled ? Icons.folder_outlined : Icons.folder_off_outlined),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditFolderDialog(context, folder);
                } else if (value == 'toggle') {
                  manager.toggleFolderEnabled(folder.id, !folder.isEnabled);
                } else if (value == 'delete') {
                  _showDeleteFolderDialog(context, folder);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'edit', child: Text(l10n.edit)),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(folder.isEnabled ? l10n.disable : l10n.enable),
                ),
                PopupMenuItem(value: 'delete', child: Text(l10n.delete)),
              ],
            ),
            children: [
              ...folder.snippets.map((snippet) {
                return ListTile(
                  title: Text(snippet.title),
                  subtitle: Text(
                    snippet.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: folder.isEnabled
                      ? () {
                          ClipboardManager.instance.copyToClipboard(
                            HistoryItem(type: 'text', value: snippet.content),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.snippetCopied)),
                          );
                        }
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _showEditSnippetDialog(context, folder, snippet),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _showDeleteSnippetDialog(context, folder, snippet),
                      ),
                    ],
                  ),
                );
              }),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(l10n.addSnippet),
                onTap: () => _showAddSnippetDialog(context, folder),
              ),
            ],
          );
        }),
      ],
    );
  }

  Future<void> _showAddFolderDialog(BuildContext context) async {
    final l10n = context.l10n;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.newFolder),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: l10n.folderName),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l10n.create),
            ),
          ],
        );
      },
    );
    final title = result ?? '';
    if (title.isNotEmpty) {
      await SnippetManager.instance.addFolder(title);
    }
  }

  Future<void> _showImportXmlDialog(BuildContext context) async {
    final l10n = context.l10n;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.importSnippetsXml),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: controller,
              maxLines: 12,
              decoration: InputDecoration(
                labelText: l10n.pasteXmlContent,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l10n.import),
            ),
          ],
        );
      },
    );
    final xml = result ?? '';
    if (xml.isNotEmpty) {
      await SnippetManager.instance.importFromXmlString(xml);
    }
  }

  Future<void> _showEditFolderDialog(BuildContext context, SnippetFolder folder) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: folder.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.editFolder),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: l10n.folderName),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l10n.save),
            ),
          ],
        );
      },
    );
    final title = result ?? '';
    if (title.isNotEmpty) {
      await SnippetManager.instance.updateFolderTitle(folder.id, title);
    }
  }

  Future<void> _showDeleteFolderDialog(BuildContext context, SnippetFolder folder) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.deleteFolder),
          content: Text(l10n.deleteFolderMessage(folder.title)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.delete)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.deleteFolder(folder.id);
    }
  }

  Future<void> _showAddSnippetDialog(BuildContext context, SnippetFolder folder) async {
    final l10n = context.l10n;
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.newSnippet),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: l10n.title),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: InputDecoration(labelText: l10n.content),
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.create)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.addSnippet(
        folder.id,
        titleController.text.trim(),
        contentController.text.trim(),
      );
    }
  }

  Future<void> _showEditSnippetDialog(
    BuildContext context,
    SnippetFolder folder,
    Snippet snippet,
  ) async {
    final l10n = context.l10n;
    final titleController = TextEditingController(text: snippet.title);
    final contentController = TextEditingController(text: snippet.content);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.editSnippet),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: l10n.title),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: InputDecoration(labelText: l10n.content),
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.save)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.updateSnippet(
        folder.id,
        snippet.id,
        titleController.text.trim(),
        contentController.text.trim(),
      );
    }
  }

  Future<void> _showDeleteSnippetDialog(
    BuildContext context,
    SnippetFolder folder,
    Snippet snippet,
  ) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.deleteSnippet),
          content: Text(l10n.deleteSnippetMessage(snippet.title)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.delete)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.deleteSnippet(folder.id, snippet.id);
    }
  }
}

class MacTransferTab extends StatefulWidget {
  const MacTransferTab({super.key});

  @override
  State<MacTransferTab> createState() => _MacTransferTabState();
}

class _MacTransferTabState extends State<MacTransferTab> {
  @override
  void initState() {
    super.initState();
    unawaited(SyncManager.instance.requestTransferListsForAvailableDevices());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manager = TransferManager.instance;
    final items = manager.items;
    final rows = _groupTransferItemsByDevice(items);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: () => _showAddTextDialog(context),
                icon: const Icon(Icons.text_fields, size: 18),
                label: Text(l10n.addText),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _showAddFileDialog(context),
                icon: const Icon(Icons.attach_file, size: 18),
                label: Text(l10n.addFile),
              ),
              const Spacer(),
              if (items.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _confirmClearAll(context),
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: Text(l10n.clearAll),
                ),
            ],
          ),
        ),
        if (items.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                l10n.dragOrAddToTransfer,
                style: TextStyle(color: Colors.grey[500], fontSize: 16),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row is String) {
                  return _TransferDeviceHeader(deviceName: row);
                }
                return _TransferItemTile(item: row as TransferItem);
              },
            ),
          ),
      ],
    );
  }

  void _showAddTextDialog(BuildContext context) {
    final l10n = context.l10n;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.addText),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: InputDecoration(hintText: l10n.enterTextContent),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                TransferManager.instance.addTextItem(text);
              }
              Navigator.pop(ctx);
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddFileDialog(BuildContext context) async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result != null && result.files.isNotEmpty) {
      for (final file in result.files) {
        if (file.path != null) {
          final ioFile = File(file.path!);
          if (ioFile.existsSync()) {
            TransferManager.instance.addFileItem(ioFile);
          }
        }
      }
    }
  }

  void _confirmClearAll(BuildContext context) {
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.clearAllTransfer),
        content: Text(l10n.clearAllTransferConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          TextButton(
            onPressed: () {
              TransferManager.instance.clearAll();
              Navigator.pop(ctx);
            },
            child: Text(l10n.clearAll),
          ),
        ],
      ),
    );
  }
}

class _TransferItemTile extends StatelessWidget {
  final TransferItem item;
  const _TransferItemTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isFile = item.content.type == 'file';
    final isText = item.content.type == 'text';

    return GestureDetector(
      onLongPress: () => _showContextMenu(context),
      child: Dismissible(
        key: ValueKey(item.id),
        background: Container(
          color: Colors.red,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => TransferManager.instance.removeItem(item.id),
        child: ListTile(
          leading: _iconForContent(item.content),
          title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${item.content.typeLabel} • ${item.sourceDevice} • ${item.isPermanent ? l10n.permanent : l10n.temporary}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFile)
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () => _openFile(context),
                  tooltip: l10n.openFile,
                ),
              if (isFile)
                IconButton(
                  icon: const Icon(Icons.save_alt, size: 18),
                  onPressed: () => _saveFile(context),
                  tooltip: l10n.saveFile,
                ),
              IconButton(
                icon: Icon(item.isPermanent ? Icons.lock : Icons.lock_open, size: 18),
                onPressed: () => TransferManager.instance.togglePermanent(item.id),
                tooltip: item.isPermanent ? l10n.setTemporary : l10n.setPermanent,
              ),
            ],
          ),
          onTap: () {
            if (isText) {
              ClipboardManager.instance.copyToClipboard(HistoryItem(type: 'text', value: item.content.value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.copiedToClipboard)),
              );
            } else if (isFile) {
              _openFile(context);
            }
          },
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context) {
    final l10n = context.l10n;
    final isFile = item.content.type == 'file';
    final isText = item.content.type == 'text';

    showModalBottomSheet(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isText)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(l10n.copyContent),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    ClipboardManager.instance.copyToClipboard(HistoryItem(type: 'text', value: item.content.value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.copiedToClipboard)),
                    );
                  },
                ),
              if (isFile)
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: Text(l10n.openFile),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openFile(context);
                  },
                ),
              if (isFile)
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: Text(l10n.saveFile),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _saveFile(context);
                  },
                ),
              ListTile(
                leading: Icon(item.isPermanent ? Icons.lock_open : Icons.lock),
                title: Text(item.isPermanent ? l10n.setTemporary : l10n.setPermanent),
                onTap: () {
                  Navigator.pop(sheetContext);
                  TransferManager.instance.togglePermanent(item.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(l10n.delete, style: const TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  TransferManager.instance.removeItem(item.id);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openFile(BuildContext context) async {
    final l10n = context.l10n;
    if (item.content.type != 'file') return;
    final filePath = item.content.value['filePath'] as String?;
    if (filePath == null) return;

    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.fileOpenFailed)),
      );
    }
  }

  Future<void> _saveFile(BuildContext context) async {
    final l10n = context.l10n;
    if (item.content.type != 'file') return;
    final filePath = item.content.value['filePath'] as String?;
    final fileName = item.content.value['fileName'] as String? ?? 'file';
    if (filePath == null) return;

    final sourceFile = File(filePath);
    if (!await sourceFile.exists()) return;

    final destPath = await FilePicker.saveFile(
      dialogTitle: l10n.saveToLocation,
      fileName: fileName,
    );

    if (destPath != null) {
      await sourceFile.copy(destPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.fileSaved)),
        );
      }
    }
  }

  Widget _iconForContent(TransferContent content) {
    if (content.type == 'file') {
      return _iconForExtension(content.fileExtension);
    }
    switch (content.type) {
      case 'text':
        return const Icon(Icons.short_text);
      case 'rtf':
        return const Icon(Icons.description_outlined);
      case 'image':
        return const Icon(Icons.image_outlined);
      case 'folder':
        return const Icon(Icons.folder_outlined);
      default:
        return const Icon(Icons.help_outline);
    }
  }

  Widget _iconForExtension(String? ext) {
    switch (ext) {
      case 'pdf':
        return const Icon(Icons.picture_as_pdf, color: Colors.red);
      case 'doc':
      case 'docx':
        return const Icon(Icons.description, color: Colors.blue);
      case 'xls':
      case 'xlsx':
      case 'csv':
        return const Icon(Icons.table_chart, color: Colors.green);
      case 'ppt':
      case 'pptx':
        return const Icon(Icons.slideshow, color: Colors.orange);
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return const Icon(Icons.archive, color: Colors.brown);
      case 'mp3':
      case 'wav':
      case 'aac':
      case 'flac':
      case 'ogg':
        return const Icon(Icons.audio_file, color: Colors.purple);
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'mkv':
      case 'flv':
        return const Icon(Icons.video_file, color: Colors.pink);
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
      case 'svg':
        return const Icon(Icons.image, color: Colors.teal);
      case 'txt':
      case 'md':
      case 'json':
      case 'xml':
      case 'yaml':
      case 'yml':
        return const Icon(Icons.article, color: Colors.grey);
      case 'apk':
        return const Icon(Icons.android, color: Colors.green);
      case 'exe':
      case 'dmg':
        return const Icon(Icons.settings_applications, color: Colors.blueGrey);
      default:
        return const Icon(Icons.insert_drive_file, color: Colors.blue);
    }
  }
}

List<Object> _groupTransferItemsByDevice(List<TransferItem> items) {
  final grouped = <String, List<TransferItem>>{};
  for (final item in items) {
    grouped.putIfAbsent(item.sourceDevice, () => []).add(item);
  }

  final rows = <Object>[];
  for (final entry in grouped.entries) {
    rows.add(entry.key);
    rows.addAll(entry.value);
  }
  return rows;
}

class _TransferDeviceHeader extends StatelessWidget {
  final String deviceName;
  const _TransferDeviceHeader({required this.deviceName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        deviceName,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class MacSettingsTab extends StatefulWidget {
  const MacSettingsTab({super.key});

  @override
  State<MacSettingsTab> createState() => _MacSettingsTabState();
}

class _MacSettingsTabState extends State<MacSettingsTab> {
  late TextEditingController _excludedController;
  late TextEditingController _portController;
  late TextEditingController _devicesController;

  @override
  void initState() {
    super.initState();
    _excludedController = TextEditingController(
      text: ClipboardManager.instance.excludedApps.join('\n'),
    );
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _devicesController = TextEditingController(
      text: SyncManager.instance.authorizedDevices.join(', '),
    );
  }

  @override
  void dispose() {
    _excludedController.dispose();
    _portController.dispose();
    _devicesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final clipboardManager = ClipboardManager.instance;
    final historyLimit = clipboardManager.historyLimit;
    return ListView(
      children: [
        ListTile(
          title: Text(l10n.languageLabel),
          trailing: DropdownButton<AppLanguage>(
            value: AppLanguageController.instance.language,
            onChanged: (language) async {
              if (language == null) return;
              await AppLanguageController.instance.setLanguage(language);
              if (mounted) setState(() {});
            },
            items: AppLanguage.values.map((language) {
              return DropdownMenuItem(
                value: language,
                child: Text(language.displayName),
              );
            }).toList(),
          ),
        ),
        const Divider(),
        ListTile(
          title: Text(l10n.historyLimit),
          subtitle: Text(l10n.keepRecentItems(historyLimit)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: historyLimit > 1
                    ? () async {
                        await clipboardManager.updateHistoryLimit(historyLimit - 1);
                        setState(() {});
                      }
                    : null,
              ),
              Text(historyLimit.toString()),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: historyLimit < 200
                    ? () async {
                        await clipboardManager.updateHistoryLimit(historyLimit + 1);
                        setState(() {});
                      }
                    : null,
              ),
            ],
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _excludedController,
            maxLines: null,
            decoration: InputDecoration(
              labelText: l10n.excludedApps,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: ElevatedButton(
            onPressed: () async {
              final apps = _excludedController.text
                  .split(RegExp(r'[\n,]'))
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList();
              await clipboardManager.updateExcludedApps(apps);
            },
            child: Text(l10n.saveExcludedApps),
          ),
        ),
        const Divider(),
        SwitchListTile(
          title: Text(l10n.enableLanSync),
          value: SyncManager.instance.isEnabled,
          onChanged: (value) async {
            SyncManager.instance.isEnabled = value;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('syncEnabled', value);
            if (value) {
              await SyncManager.instance.start();
            } else {
              await SyncManager.instance.stop();
            }
            setState(() {});
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _portController,
            decoration: InputDecoration(
              labelText: l10n.syncPort,
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) async {
              final port = int.tryParse(value);
              if (port != null) {
                SyncManager.instance.port = port;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('syncPort', port);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _devicesController,
            decoration: InputDecoration(
              labelText: l10n.authorizedDevicesComma,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) async {
              final devices = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              SyncManager.instance.authorizedDevices = devices;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setStringList('authorizedDevices', devices);
            },
          ),
        ),
        const Divider(),
        ListTile(
          title: Text(l10n.about),
          subtitle: const Text('ClipyClone macOS v1.0.0'),
        ),
      ],
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  StreamSubscription? _fileSubscription;
  StreamSubscription? _progressSubscription;
  final Map<String, FileProgress> _activeTransfers = {};

  @override
  void initState() {
    super.initState();
    ClipboardManager.instance.onHistoryChanged = _handleDataChanged;
    SnippetManager.instance.onSnippetsChanged = _handleDataChanged;
    
    _progressSubscription = SyncManager.instance.onFileProgress.listen((progress) {
      if (mounted) {
        setState(() {
          if (progress.isCompleted) {
            _activeTransfers.remove(progress.fileId);
          } else {
            _activeTransfers[progress.fileId] = progress;
          }
        });
      }
    });

    _fileSubscription = SyncManager.instance.onFileReceived.listen((fileName) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.receivedFile(fileName)),
            action: SnackBarAction(
              label: context.l10n.view,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ReceivedFilesPage()),
              ),
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    ClipboardManager.instance.onHistoryChanged = null;
    SnippetManager.instance.onSnippetsChanged = null;
    _fileSubscription?.cancel();
    _progressSubscription?.cancel();
    super.dispose();
  }

  void _handleDataChanged() {
    if (mounted) setState(() {});
  }

  static const _channel = MethodChannel('com.clipyclone.clipy_android/open_folder');

  Future<void> _openFolder(String filePath) async {
    try {
      await _channel.invokeMethod('openFolder', {'path': filePath});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotOpenFolder(e))),
        );
      }
    }
  }

  Widget _buildHistoryTab() {
    final l10n = context.l10n;
    final history = ClipboardManager.instance.history;
    return Column(
      children: [
        if (_activeTransfers.isNotEmpty)
            Container(
            color: Colors.blue.withValues(alpha: 0.1),
            child: Column(
              children: _activeTransfers.values.map((progress) {
                return Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.downloading, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.receiving(progress.fileName),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${(progress.progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: progress.progress),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        Expanded(
          child: history.isEmpty
              ? Center(child: Text(l10n.noClipboardHistory, style: TextStyle(color: Colors.grey[500], fontSize: 16)))
              : ListView.builder(
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    final entry = history[index];
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
                      subtitle: Text(l10n.sourceAndDate(entry.sourceApp, entry.date.toString().split('.')[0])),
                      onTap: () {
                        if (isFile) {
                          _openFolder(entry.item.value.toString());
                        } else {
                          ClipboardManager.instance.copyToClipboard(entry.item);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.copiedToClipboard)),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSnippetsTab() {
    final l10n = context.l10n;
    final folders = SnippetManager.instance.folders;
    if (folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.snippet_folder_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(l10n.noSnippetsYet, style: TextStyle(color: Colors.grey[500], fontSize: 16)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _showAddFolderDialog(context),
              child: Text(l10n.addSnippetFolder),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _showImportXmlDialog(context),
              child: Text(l10n.importXml),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.snippetFolders,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton(
                onPressed: () => _showImportXmlDialog(context),
                child: Text(l10n.importXml),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _showAddFolderDialog(context),
                child: Text(l10n.addFolder),
              ),
            ],
          ),
        ),
        ...folders.map((folder) {
          return ExpansionTile(
            title: Text(folder.title),
            leading: Icon(folder.isEnabled ? Icons.folder_outlined : Icons.folder_off_outlined),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditFolderDialog(context, folder);
                } else if (value == 'toggle') {
                  SnippetManager.instance.toggleFolderEnabled(folder.id, !folder.isEnabled);
                } else if (value == 'delete') {
                  _showDeleteFolderDialog(context, folder);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'edit', child: Text(l10n.edit)),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(folder.isEnabled ? l10n.disable : l10n.enable),
                ),
                PopupMenuItem(value: 'delete', child: Text(l10n.delete)),
              ],
            ),
            children: [
              ...folder.snippets.map((snippet) {
                return ListTile(
                  title: Text(snippet.title),
                  subtitle: Text(snippet.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: folder.isEnabled
                      ? () {
                          ClipboardManager.instance.copyToClipboard(
                            HistoryItem(type: 'text', value: snippet.content),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.snippetCopied)),
                          );
                        }
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _showEditSnippetDialog(context, folder, snippet),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _showDeleteSnippetDialog(context, folder, snippet),
                      ),
                    ],
                  ),
                );
              }),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(l10n.addSnippet),
                onTap: () => _showAddSnippetDialog(context, folder),
              ),
            ],
          );
        }),
      ],
    );
  }

  Future<void> _showAddFolderDialog(BuildContext context) async {
    final l10n = context.l10n;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.newFolder),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: l10n.folderName),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l10n.create),
            ),
          ],
        );
      },
    );
    final title = result ?? '';
    if (title.isNotEmpty) {
      await SnippetManager.instance.addFolder(title);
    }
  }

  Future<void> _showImportXmlDialog(BuildContext context) async {
    final l10n = context.l10n;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.importSnippetsXml),
          content: TextField(
            controller: controller,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: l10n.pasteXmlContent,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l10n.import),
            ),
          ],
        );
      },
    );
    final xml = result ?? '';
    if (xml.isNotEmpty) {
      await SnippetManager.instance.importFromXmlString(xml);
    }
  }

  Future<void> _showEditFolderDialog(BuildContext context, SnippetFolder folder) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: folder.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.editFolder),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: l10n.folderName),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l10n.save),
            ),
          ],
        );
      },
    );
    final title = result ?? '';
    if (title.isNotEmpty) {
      await SnippetManager.instance.updateFolderTitle(folder.id, title);
    }
  }

  Future<void> _showDeleteFolderDialog(BuildContext context, SnippetFolder folder) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.deleteFolder),
          content: Text(l10n.deleteFolderMessage(folder.title)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.delete)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.deleteFolder(folder.id);
    }
  }

  Future<void> _showAddSnippetDialog(BuildContext context, SnippetFolder folder) async {
    final l10n = context.l10n;
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.newSnippet),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: l10n.title),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: InputDecoration(labelText: l10n.content),
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.create)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.addSnippet(
        folder.id,
        titleController.text.trim(),
        contentController.text.trim(),
      );
    }
  }

  Future<void> _showEditSnippetDialog(
    BuildContext context,
    SnippetFolder folder,
    Snippet snippet,
  ) async {
    final l10n = context.l10n;
    final titleController = TextEditingController(text: snippet.title);
    final contentController = TextEditingController(text: snippet.content);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.editSnippet),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: l10n.title),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: InputDecoration(labelText: l10n.content),
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.save)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.updateSnippet(
        folder.id,
        snippet.id,
        titleController.text.trim(),
        contentController.text.trim(),
      );
    }
  }

  Future<void> _showDeleteSnippetDialog(
    BuildContext context,
    SnippetFolder folder,
    Snippet snippet,
  ) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.deleteSnippet),
          content: Text(l10n.deleteSnippetMessage(snippet.title)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.delete)),
          ],
        );
      },
    );
    if (result == true) {
      await SnippetManager.instance.deleteSnippet(folder.id, snippet.id);
    }
  }

  Widget _buildSettingsTab() {
    final l10n = context.l10n;
    return ListView(
      children: [
        SwitchListTile(
          title: Text(l10n.collectorEnabled),
          value: CollectorManager.instance.isEnabled,
          onChanged: (value) async {
            await CollectorManager.instance.setEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        SwitchListTile(
          title: Text(l10n.collectorClipboardOnly),
          value: ClipboardManager.instance.collectorClipboardOnly,
          onChanged: (value) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('collectorClipboardOnly', value);
            await ClipboardManager.instance.reloadPreferences();
            if (mounted) setState(() {});
          },
        ),
        const Divider(),
        _MobileSettingsContent(
          onOpenLogs: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const LogPage())),
          onOpenTransfer: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const TransferPage())),
          onOpenReceivedFiles: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ReceivedFilesPage())),
          onOpenNotificationSync: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const NotificationSyncPage())),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    final titles = [l10n.clipyHistory, l10n.snippets, l10n.collector, l10n.settings];
    final bodies = [_buildHistoryTab(), _buildSnippetsTab(), const CollectorPage(), _buildSettingsTab()];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_selectedIndex]),
        actions: _selectedIndex == 0
            ? [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const NotificationSyncPage()),
                  ),
                  tooltip: l10n.notificationSync,
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const TransferPage()),
                  ),
                  tooltip: l10n.transferStation,
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ReceivedFilesPage()),
                  ),
                  tooltip: l10n.receivedFiles,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => ClipboardManager.instance.clearHistory(),
                  tooltip: l10n.clearHistory,
                ),
                IconButton(
                  icon: const Icon(Icons.list_alt),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const LogPage()),
                  ),
                  tooltip: l10n.viewLogs,
                ),
              ]
            : null,
      ),
      body: bodies[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.history), label: l10n.history),
          BottomNavigationBarItem(icon: const Icon(Icons.snippet_folder_outlined), label: l10n.snippets),
          BottomNavigationBarItem(icon: const Icon(Icons.sensors), label: l10n.collector),
          BottomNavigationBarItem(icon: const Icon(Icons.settings), label: l10n.settings),
        ],
      ),
    );
  }
}

class _MobileSettingsContent extends StatefulWidget {
  final VoidCallback onOpenLogs;
  final VoidCallback onOpenTransfer;
  final VoidCallback onOpenReceivedFiles;
  final VoidCallback onOpenNotificationSync;

  const _MobileSettingsContent({
    required this.onOpenLogs,
    required this.onOpenTransfer,
    required this.onOpenReceivedFiles,
    required this.onOpenNotificationSync,
  });

  @override
  State<_MobileSettingsContent> createState() => _MobileSettingsContentState();
}

class _MobileSettingsContentState extends State<_MobileSettingsContent> {
  late TextEditingController _portController;
  late TextEditingController _nameController;
  StreamSubscription? _devicesSubscription;
  List<String> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _nameController = TextEditingController(
      text: SyncManager.instance.deviceId,
    );
    _availableDevices = SyncManager.instance.availableDeviceNames;
    _devicesSubscription = SyncManager.instance.onDevicesChanged.listen((devices) {
      if (mounted) {
        setState(() {
          _availableDevices = devices;
        });
      }
    });
  }

  @override
  void dispose() {
    _portController.dispose();
    _nameController.dispose();
    _devicesSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      children: [
        ListTile(
          title: Text(l10n.languageLabel),
          trailing: DropdownButton<AppLanguage>(
            value: AppLanguageController.instance.language,
            onChanged: (language) async {
              if (language == null) return;
              await AppLanguageController.instance.setLanguage(language);
              if (mounted) setState(() {});
            },
            items: AppLanguage.values.map((language) {
              return DropdownMenuItem(
                value: language,
                child: Text(language.displayName),
              );
            }).toList(),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: l10n.deviceNameForSync,
                    border: const OutlineInputBorder(),
                    hintText: l10n.enterDeviceName,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  final newName = _nameController.text.trim();
                  if (newName.isNotEmpty) {
                    final messenger = ScaffoldMessenger.of(context);
                    final message = l10n.deviceNameUpdated;
                    await SyncManager.instance.updateDeviceName(newName);
                    if (mounted) {
                      messenger.showSnackBar(SnackBar(content: Text(message)));
                    }
                  }
                },
                child: Text(l10n.save),
              ),
            ],
          ),
        ),
        const Divider(),
        SwitchListTile(
          title: Text(l10n.enableLanSync),
          value: SyncManager.instance.isEnabled,
          onChanged: (value) async {
            SyncManager.instance.isEnabled = value;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('syncEnabled', value);
            if (value) {
              await SyncManager.instance.start();
            } else {
              await SyncManager.instance.stop();
            }
            setState(() {});
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _portController,
            decoration: InputDecoration(
              labelText: l10n.syncPort,
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) async {
              final port = int.tryParse(value);
              if (port != null) {
                SyncManager.instance.port = port;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('syncPort', port);
              }
            },
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.authorizedDevices,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
        ),
        if (_availableDevices.isEmpty)
          ListTile(
            title: Text(l10n.noDevicesFound),
            subtitle: Text(l10n.sameWifiHint),
          )
        else
          ..._availableDevices.map((deviceName) {
            final isAuthorized = SyncManager.instance.authorizedDevices.contains(deviceName);
            return CheckboxListTile(
              title: Text(deviceName),
              value: isAuthorized,
              onChanged: (bool? value) async {
                final devices = List<String>.from(SyncManager.instance.authorizedDevices);
                if (value == true) {
                  if (!devices.contains(deviceName)) devices.add(deviceName);
                } else {
                  devices.remove(deviceName);
                }
                SyncManager.instance.authorizedDevices = devices;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setStringList('authorizedDevices', devices);
                if (value == true) {
                  await SyncManager.instance.requestTransferList(deviceName: deviceName);
                }
                setState(() {});
              },
            );
          }),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.notifications_active, color: Colors.blue),
          title: Text(l10n.notificationSync),
          subtitle: Text(l10n.enableNotificationSync),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.onOpenNotificationSync,
        ),
        const Divider(),
        ListTile(
          title: Text(l10n.transferStation),
          onTap: widget.onOpenTransfer,
        ),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: Text(l10n.receivedFiles),
          onTap: widget.onOpenReceivedFiles,
        ),
        ListTile(
          leading: const Icon(Icons.list_alt),
          title: Text(l10n.viewLogs),
          subtitle: Text(l10n.appRuntimeLogs),
          onTap: widget.onOpenLogs,
        ),
        const Divider(),
        ListTile(
          title: Text(l10n.about),
          subtitle: Text('ClipyClone ${Platform.isIOS ? 'iOS' : 'Android'} v1.0.0'),
        ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _portController;
  late TextEditingController _nameController;
  StreamSubscription? _devicesSubscription;
  List<String> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: SyncManager.instance.port.toString(),
    );
    _nameController = TextEditingController(
      text: SyncManager.instance.deviceId,
    );
    _availableDevices = SyncManager.instance.availableDeviceNames;
    _devicesSubscription = SyncManager.instance.onDevicesChanged.listen((devices) {
      if (mounted) {
        setState(() {
          _availableDevices = devices;
        });
      }
    });
  }

  @override
  void dispose() {
    _portController.dispose();
    _nameController.dispose();
    _devicesSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          ListTile(
            title: Text(l10n.languageLabel),
            trailing: DropdownButton<AppLanguage>(
              value: AppLanguageController.instance.language,
              onChanged: (language) async {
                if (language == null) return;
                await AppLanguageController.instance.setLanguage(language);
                if (mounted) setState(() {});
              },
              items: AppLanguage.values.map((language) {
                return DropdownMenuItem(
                  value: language,
                  child: Text(language.displayName),
                );
              }).toList(),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: l10n.deviceNameForSync,
                      border: const OutlineInputBorder(),
                      hintText: l10n.enterDeviceName,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    final newName = _nameController.text.trim();
                    if (newName.isNotEmpty) {
                      final messenger = ScaffoldMessenger.of(context);
                      final message = l10n.deviceNameUpdated;
                      await SyncManager.instance.updateDeviceName(newName);
                      if (mounted) {
                        messenger.showSnackBar(SnackBar(content: Text(message)));
                      }
                    }
                  },
                  child: Text(l10n.save),
                ),
              ],
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: Text(l10n.enableLanSync),
            value: SyncManager.instance.isEnabled,
            onChanged: (value) async {
              SyncManager.instance.isEnabled = value;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('syncEnabled', value);
              if (value) {
                await SyncManager.instance.start();
              } else {
                await SyncManager.instance.stop();
              }
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _portController,
              decoration: InputDecoration(
                labelText: l10n.syncPort,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onChanged: (value) async {
                final port = int.tryParse(value);
                if (port != null) {
                  SyncManager.instance.port = port;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt('syncPort', port);
                }
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.authorizedDevices,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
            ),
          ),
          if (_availableDevices.isEmpty)
            ListTile(
              title: Text(l10n.noDevicesFound),
              subtitle: Text(l10n.sameWifiHint),
            )
          else
            ..._availableDevices.map((deviceName) {
              final isAuthorized = SyncManager.instance.authorizedDevices.contains(deviceName);
              return CheckboxListTile(
                title: Text(deviceName),
                value: isAuthorized,
                onChanged: (bool? value) async {
                  final devices = List<String>.from(SyncManager.instance.authorizedDevices);
                  if (value == true) {
                    if (!devices.contains(deviceName)) devices.add(deviceName);
                  } else {
                    devices.remove(deviceName);
                  }
                  SyncManager.instance.authorizedDevices = devices;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setStringList('authorizedDevices', devices);
                  if (value == true) {
                    await SyncManager.instance.requestTransferList(deviceName: deviceName);
                  }
                  setState(() {});
                },
              );
            }),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications_active, color: Colors.blue),
            title: Text(l10n.notificationSync),
            subtitle: Text(l10n.enableNotificationSync),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const NotificationSyncPage()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: Text(l10n.viewLogs),
            subtitle: Text(l10n.appRuntimeLogs),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogPage()),
              );
            },
          ),
          const Divider(),
          ListTile(
            title: Text(l10n.about),
            subtitle: Text('ClipyClone ${Platform.isIOS ? 'iOS' : 'Android'} v1.0.0'),
          ),
        ],
      ),
    );
  }
}

class ReceivedFilesPage extends StatefulWidget {
  const ReceivedFilesPage({super.key});

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  List<dynamic> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getString('fileHistory') ?? '[]';
    if (mounted) {
      setState(() {
        _files = jsonDecode(historyJson);
      });
    }
  }

  Future<void> _deleteFile(int index) async {
    final file = _files[index];
    final ioFile = File(file['filePath']);
    if (await ioFile.exists()) {
      await ioFile.delete();
    }

    _files.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fileHistory', jsonEncode(_files));
    setState(() {});
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static const _channel = MethodChannel('com.clipyclone.clipy_android/open_folder');

  Future<void> _openFolder(String filePath) async {
    try {
      await _channel.invokeMethod('openFolder', {'path': filePath});
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
      body: _files.isEmpty
          ? Center(child: Text(l10n.noFilesReceived))
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index];
                final date = DateTime.parse(file['timestamp']);
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file['fileName']),
                  subtitle: Text(
                    '${_formatSize(file['fileSize'])} • ${l10n.fromSender(file['senderName'])}\n${date.toString().split('.')[0]}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteFile(index),
                  ),
                  onTap: () => _openFolder(file['filePath']),
                );
              },
            ),
    );
  }
}

class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  @override
  void initState() {
    super.initState();
    unawaited(SyncManager.instance.requestTransferListsForAvailableDevices());
    TransferManager.instance.onItemsChanged = (_) {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    TransferManager.instance.onItemsChanged = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = TransferManager.instance.items;
    final permanentCount = items.where((i) => i.isPermanent).length;
    final rows = _groupTransferItemsByDevice(items);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.transferStation),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () => _confirmClearAll(context),
              tooltip: l10n.clearAll,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _showAddTextDialog(context),
                  icon: const Icon(Icons.text_fields, size: 18),
                  label: Text(l10n.addText),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _showAddFileDialog(context),
                  icon: const Icon(Icons.attach_file, size: 18),
                  label: Text(l10n.addFile),
                ),
                const Spacer(),
                Text(
                  l10n.itemCount(items.length, permanentCount),
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  l10n.dragOrAddToTransfer,
                  style: TextStyle(color: Colors.grey[500], fontSize: 16),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  if (row is String) {
                    return _TransferDeviceHeader(deviceName: row);
                  }
                  return _TransferItemTile(item: row as TransferItem);
                },
              ),
            ),
        ],
      ),
    );
  }

  void _showAddTextDialog(BuildContext context) {
    final l10n = context.l10n;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.addText),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: InputDecoration(hintText: l10n.enterTextContent),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                TransferManager.instance.addTextItem(text);
              }
              Navigator.pop(ctx);
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddFileDialog(BuildContext context) async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result != null && result.files.isNotEmpty) {
      for (final file in result.files) {
        if (file.path != null) {
          final ioFile = File(file.path!);
          if (ioFile.existsSync()) {
            TransferManager.instance.addFileItem(ioFile);
          }
        }
      }
    }
  }

  void _confirmClearAll(BuildContext context) {
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.clearAllTransfer),
        content: Text(l10n.clearAllTransferConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          TextButton(
            onPressed: () {
              TransferManager.instance.clearAll();
              Navigator.pop(ctx);
            },
            child: Text(l10n.clearAll),
          ),
        ],
      ),
    );
  }
}
