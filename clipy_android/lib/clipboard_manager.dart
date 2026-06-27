import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_manager.dart';
import 'models.dart';
import 'storage_paths.dart';
import 'sync_manager.dart';
import 'collector_manager.dart';

class ClipboardManager {
  static final ClipboardManager instance = ClipboardManager._();
  ClipboardManager._();

  List<HistoryEntry> history = [];
  String? _lastText;
  String? _lastSyncHash;
  late File _storageFile;
  int _historyLimit = 1000;
  List<String> _excludedApps = [];
  bool _collectorClipboardOnly = false;

  int get historyLimit => _historyLimit;
  List<String> get excludedApps => List.unmodifiable(_excludedApps);
  bool get collectorClipboardOnly => _collectorClipboardOnly;

  Future<void> reloadPreferences() async {
    await _loadPreferences();
  }

  Future<void> init() async {
    appLog('Initializing ClipboardManager...');
    final dir = await StoragePaths.appStorageDirectory();
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
    _historyLimit = prefs.getInt('historyLimit') ?? 1000;
    _excludedApps = prefs.getStringList('excludedApps') ?? [];
    _collectorClipboardOnly = prefs.getBool('collectorClipboardOnly') ?? false;
    appLog('Preferences loaded: limit=$_historyLimit, excludedCount=${_excludedApps.length}, collectorClipboardOnly=$_collectorClipboardOnly');
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

    appLog('New history entry: ${normalizedEntry.item.title}');

    // Broadcast if it's a new text item and not from sync
    if (broadcast && normalizedEntry.contentHash != _lastSyncHash) {
      if (normalizedEntry.item.type == 'text') {
        appLog('Broadcasting new local copy...');
        CollectorManager.instance.emitClipboard(
          text: normalizedEntry.item.value as String,
          hash: normalizedEntry.contentHash!,
        );
        if (!_collectorClipboardOnly) {
          SyncManager.instance.broadcastSync(
            normalizedEntry.item.value as String,
            normalizedEntry.contentHash!,
          );
        }
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
    if (hash == _lastSyncHash) {
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
