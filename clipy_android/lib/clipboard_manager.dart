import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'models.dart';
import 'sync_manager.dart';

class ClipboardManager {
  static final ClipboardManager instance = ClipboardManager._();
  ClipboardManager._();

  List<HistoryEntry> history = [];
  Timer? _timer;
  String? _lastText;
  late File _storageFile;

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _storageFile = File('${dir.path}/history.json');
    await _loadHistory();
    _startMonitoring();
    
    SyncManager.instance.onHistorySynced = (entry) {
      _addToHistory(entry, broadcast: false);
    };
  }

  Future<void> _loadHistory() async {
    if (await _storageFile.exists()) {
      try {
        final content = await _storageFile.readAsString();
        final List jsonList = jsonDecode(content);
        history = jsonList.map((j) => HistoryEntry.fromJson(j)).toList();
      } catch (e) {
        print('Load history error: $e');
      }
    }
  }

  Future<void> _saveHistory() async {
    final jsonList = history.map((e) => e.toJson()).toList();
    await _storageFile.writeAsString(jsonEncode(jsonList));
  }

  void _startMonitoring() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty && data.text != _lastText) {
        _lastText = data.text;
        final entry = HistoryEntry(
          item: HistoryItem(type: 'text', value: _lastText!),
          date: DateTime.now(),
          sourceApp: 'Android',
        );
        _addToHistory(entry);
      }
    });
  }

  void _addToHistory(HistoryEntry entry, {bool broadcast = true}) {
    // Deduplication
    history.removeWhere((existing) {
      if (existing.item.type == entry.item.type && existing.item.type == 'text') {
        return existing.item.value == entry.item.value;
      }
      return false;
    });

    history.insert(0, entry);
    if (history.length > 50) {
      history.removeLast();
    }

    _saveHistory();
    if (broadcast) {
      SyncManager.instance.broadcastHistory(entry);
    }
    onHistoryChanged?.call();
  }

  void copyToClipboard(HistoryItem item) {
    if (item.type == 'text') {
      Clipboard.setData(ClipboardData(text: item.value as String));
      _lastText = item.value as String;
    }
  }

  void clearHistory() {
    history.clear();
    _saveHistory();
    onHistoryChanged?.call();
  }

  void Function()? onHistoryChanged;
}
