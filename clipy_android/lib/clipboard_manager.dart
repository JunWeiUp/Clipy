import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'log_manager.dart';
import 'models.dart';
import 'sync_manager.dart';

class ClipboardManager {
  static final ClipboardManager instance = ClipboardManager._();
  ClipboardManager._();

  List<HistoryEntry> history = [];
  String? _lastText;
  String? _lastSyncHash;
  late File _storageFile;
  int _historyLimit = 50;
  List<String> _excludedApps = [];

  int get historyLimit => _historyLimit;
  List<String> get excludedApps => List.unmodifiable(_excludedApps);

  Future<void> init() async {
    appLog('Initializing ClipboardManager...');
    final dir = await getApplicationSupportDirectory();
    _storageFile = File('${dir.path}/history.json');
    await _loadPreferences();
    await _loadHistory();
    _startMonitoring();
  }

  Future<void> _loadHistory() async {
    if (await _storageFile.exists()) {
      try {
        final content = await _storageFile.readAsString();
        final List jsonList = jsonDecode(content);
        history = jsonList.map((j) => HistoryEntry.fromJson(j)).toList();
        appLog('Loaded ${history.length} history entries');
      } catch (e) {
        appLog('Load history error: $e');
      }
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _historyLimit = prefs.getInt('historyLimit') ?? 50;
    _excludedApps = prefs.getStringList('excludedApps') ?? [];
    appLog('Preferences loaded: limit=$_historyLimit, excludedCount=${_excludedApps.length}');
  }

  Future<void> _saveHistory() async {
    final jsonList = history.map((e) => e.toJson()).toList();
    await _storageFile.writeAsString(jsonEncode(jsonList));
  }

  void _startMonitoring() {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty && data.text != _lastText) {
        // If this is the first time monitoring, or if we are not the source of this change
        if (_lastText != null) {
          final item = HistoryItem(type: 'text', value: data.text!);
          final entry = HistoryEntry(
            item: item,
            date: DateTime.now(),
            sourceApp: Platform.isMacOS ? 'macOS' : (Platform.isIOS ? 'iOS' : 'Android'),
            contentHash: _contentHashForItem(item),
          );
          _addToHistory(entry);
        }
        _lastText = data.text;
      }
    });
  }

  void _addToHistory(HistoryEntry entry, {bool broadcast = true}) {
    if (entry.sourceApp != null && _excludedApps.contains(entry.sourceApp)) {
      appLog('Entry excluded by app name: ${entry.sourceApp}');
      return;
    }
    
    final normalizedEntry = entry.contentHash != null
        ? entry
        : HistoryEntry(
            item: entry.item,
            date: entry.date,
            sourceApp: entry.sourceApp,
            contentHash: _contentHashForItem(entry.item),
          );

    // Check for duplicates
    if (history.any((e) => e.contentHash == normalizedEntry.contentHash)) {
      return;
    }

    appLog('New history entry: ${normalizedEntry.item.title}');

    // Broadcast if it's a new text item and not from sync
    if (broadcast && normalizedEntry.contentHash != _lastSyncHash) {
      if (normalizedEntry.item.type == 'text') {
        appLog('Broadcasting new local copy...');
        SyncManager.instance.broadcastSync(
          normalizedEntry.item.value as String,
          normalizedEntry.contentHash!,
        );
      }
    }

    history.removeWhere((existing) {
      if (existing.contentHash != null && normalizedEntry.contentHash != null) {
        return existing.contentHash == normalizedEntry.contentHash;
      }
      if (existing.item.type == normalizedEntry.item.type && existing.item.type == 'text') {
        return existing.item.value == normalizedEntry.item.value;
      }
      return false;
    });

    history.insert(0, normalizedEntry);
    if (history.length > _historyLimit) {
      history.removeLast();
    }

    _saveHistory();
    onHistoryChanged?.call();
  }

  void copyToClipboard(HistoryItem item) {
    if (item.type == 'text') {
      Clipboard.setData(ClipboardData(text: item.value as String));
      _lastText = item.value as String;
    }
  }

  Future<void> handleRemoteSync(String text, String hash) async {
    if (hash == _lastSyncHash || history.any((e) => e.contentHash == hash)) {
      appLog('Ignoring duplicate sync or loop');
      return;
    }

    appLog('Processing remote sync: ${text.substring(0, text.length > 20 ? 20 : text.length)}...');
    _lastSyncHash = hash;
    _lastText = text;
    
    final item = HistoryItem(type: 'text', value: text);
    final entry = HistoryEntry(
      item: item,
      date: DateTime.now(),
      sourceApp: 'Remote Sync',
      contentHash: hash,
    );
    
    _addToHistory(entry, broadcast: false);
    await Clipboard.setData(ClipboardData(text: text));
    appLog('Clipboard updated from remote sync');
  }

  void clearHistory() {
    history.clear();
    _saveHistory();
    onHistoryChanged?.call();
  }

  Future<void> updateHistoryLimit(int limit) async {
    _historyLimit = limit;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('historyLimit', limit);
    if (history.length > _historyLimit) {
      history = history.take(_historyLimit).toList();
      await _saveHistory();
      onHistoryChanged?.call();
    }
  }

  Future<void> updateExcludedApps(List<String> apps) async {
    _excludedApps = apps;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('excludedApps', apps);
  }

  void Function()? onHistoryChanged;

  String? _contentHashForItem(HistoryItem item) {
    switch (item.type) {
      case 'text':
        final text = (item.value as String).trim();
        final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        final bytes = utf8.encode(normalized);
        return sha256.convert(bytes).toString();
      default:
        final bytes = utf8.encode(jsonEncode(item.toJson()));
        return sha256.convert(bytes).toString();
    }
  }
}

class SnippetManager {
  static final SnippetManager instance = SnippetManager._();
  SnippetManager._();

  List<SnippetFolder> folders = [];
  late File _storageFile;
  final Uuid _uuid = const Uuid();

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _storageFile = File('${dir.path}/snippets.json');
    await _loadSnippets();
    if (folders.isEmpty) {
      _createDefaultSnippets();
    }
  }

  Future<void> _loadSnippets() async {
    if (await _storageFile.exists()) {
      try {
        final content = await _storageFile.readAsString();
        final List jsonList = jsonDecode(content);
        folders = jsonList.map((j) => SnippetFolder.fromJson(j)).toList();
      } catch (e) {
        appLog('Load snippets error: $e');
      }
    }
  }

  Future<void> _saveSnippets() async {
    final jsonList = folders.map((f) => f.toJson()).toList();
    await _storageFile.writeAsString(jsonEncode(jsonList));
    onSnippetsChanged?.call();
  }

  void _createDefaultSnippets() {
    folders = [
      SnippetFolder(
        id: _uuid.v4(),
        title: 'Greetings',
        snippets: [
          Snippet(id: _uuid.v4(), title: 'Hi', content: 'Hi there!'),
          Snippet(id: _uuid.v4(), title: 'Hello', content: 'Hello,'),
          Snippet(id: _uuid.v4(), title: 'Regards', content: 'Regards,'),
        ],
      ),
      SnippetFolder(
        id: _uuid.v4(),
        title: 'Work',
        snippets: [
          Snippet(id: _uuid.v4(), title: 'Thanks', content: 'Thank you!'),
          Snippet(id: _uuid.v4(), title: 'Check', content: "I'll check it."),
          Snippet(id: _uuid.v4(), title: 'Email', content: 'My Email: example@gmail.com'),
        ],
      ),
    ];
    _saveSnippets();
  }

  Future<void> addFolder(String title) async {
    folders.add(SnippetFolder(id: _uuid.v4(), title: title, snippets: []));
    await _saveSnippets();
  }

  Future<void> deleteFolder(String folderId) async {
    folders.removeWhere((folder) => folder.id == folderId);
    await _saveSnippets();
  }

  Future<void> updateFolderTitle(String folderId, String title) async {
    final index = folders.indexWhere((folder) => folder.id == folderId);
    if (index != -1) {
      folders[index].title = title;
      await _saveSnippets();
    }
  }

  Future<void> toggleFolderEnabled(String folderId, bool isEnabled) async {
    final index = folders.indexWhere((folder) => folder.id == folderId);
    if (index != -1) {
      folders[index].isEnabled = isEnabled;
      await _saveSnippets();
    }
  }

  Future<void> addSnippet(String folderId, String title, String content) async {
    final index = folders.indexWhere((folder) => folder.id == folderId);
    if (index != -1) {
      folders[index].snippets.add(
            Snippet(id: _uuid.v4(), title: title, content: content),
          );
      await _saveSnippets();
    }
  }

  Future<void> updateSnippet(
    String folderId,
    String snippetId,
    String title,
    String content,
  ) async {
    final fIndex = folders.indexWhere((folder) => folder.id == folderId);
    if (fIndex != -1) {
      final sIndex = folders[fIndex].snippets.indexWhere((s) => s.id == snippetId);
      if (sIndex != -1) {
        final snippet = folders[fIndex].snippets[sIndex];
        snippet.title = title;
        snippet.content = content;
        await _saveSnippets();
      }
    }
  }

  Future<void> deleteSnippet(String folderId, String snippetId) async {
    final fIndex = folders.indexWhere((folder) => folder.id == folderId);
    if (fIndex != -1) {
      folders[fIndex].snippets.removeWhere((snippet) => snippet.id == snippetId);
      await _saveSnippets();
    }
  }

  Future<void> importFromXmlString(String xml) async {
    final parsedFolders = _parseClipyXml(xml);
    if (parsedFolders.isEmpty) {
      return;
    }
    folders.addAll(parsedFolders);
    await _saveSnippets();
  }

  List<SnippetFolder> _parseClipyXml(String xml) {
    final sanitized = xml.replaceAll('\r\n', '\n');
    final folderMatches = RegExp(r'<folder\b[^>]*>([\s\S]*?)<\/folder>', caseSensitive: false)
        .allMatches(sanitized);
    final result = <SnippetFolder>[];
    for (final match in folderMatches) {
      final folderBody = match.group(1) ?? '';
      final title = _firstTagValue(folderBody, ['title', 'name', 'foldertitle']).trim();
      final folderTitle = title.isNotEmpty ? title : 'Imported';
      final snippetMatches = RegExp(r'<snippet\b[^>]*>([\s\S]*?)<\/snippet>', caseSensitive: false)
          .allMatches(folderBody);
      final snippets = <Snippet>[];
      for (final snippetMatch in snippetMatches) {
        final snippetBody = snippetMatch.group(1) ?? '';
        final snippetTitle = _firstTagValue(snippetBody, ['title', 'name']).trim();
        final snippetContent = _firstTagValue(snippetBody, ['content', 'text', 'value']);
        final resolvedTitle = snippetTitle.isNotEmpty ? snippetTitle : 'Snippet';
        snippets.add(
          Snippet(
            id: _uuid.v4(),
            title: resolvedTitle,
            content: snippetContent,
          ),
        );
      }
      if (snippets.isNotEmpty) {
        result.add(
          SnippetFolder(
            id: _uuid.v4(),
            title: folderTitle,
            snippets: snippets,
          ),
        );
      }
    }
    return result;
  }

  String _firstTagValue(String source, List<String> tags) {
    for (final tag in tags) {
      final regex = RegExp(
        '<$tag\\b[^>]*>([\\s\\S]*?)<\\/$tag>',
        caseSensitive: false,
      );
      final match = regex.firstMatch(source);
      if (match != null) {
        final raw = match.group(1) ?? '';
        return _decodeXmlEntities(_stripCdata(raw).trim());
      }
    }
    return '';
  }

  String _stripCdata(String value) {
    final cdataMatch = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>', caseSensitive: false)
        .firstMatch(value);
    return cdataMatch != null ? (cdataMatch.group(1) ?? '') : value;
  }

  String _decodeXmlEntities(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  void Function()? onSnippetsChanged;
}
