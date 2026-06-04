import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'log_manager.dart';
import 'sync_manager.dart';

class TransferManager {
  static final TransferManager instance = TransferManager._();
  TransferManager._();

  List<TransferItem> items = [];
  Function(List<TransferItem>)? onItemsChanged;

  static const String _storageKey = 'transfer_items';
  static const int _tempItemLifetimeHours = 24;

  Future<void> init() async {
    await _load();
    _cleanupTempItems();
    appLog('TransferManager initialized with ${items.length} items');
  }

  Future<void> addItem(
    TransferContent content, {
    String? title,
    bool isPermanent = false,
    bool broadcast = true,
  }) async {
    final hash = _computeHash(content);
    final deviceName = SyncManager.instance.deviceId;

    // Check for duplicates
    final existingIndex = items.indexWhere(
      (item) => item.contentHash == hash && item.sourceDevice == deviceName,
    );

    if (existingIndex >= 0) {
      final existing = items[existingIndex];
      final updated = TransferItem(
        id: existing.id,
        title: title ?? existing.title,
        content: content,
        createdAt: DateTime.now(),
        isPermanent: isPermanent,
        sourceDevice: deviceName,
        contentHash: hash,
      );
      items.removeAt(existingIndex);
      items.insert(0, updated);
    } else {
      final item = TransferItem(
        id: const Uuid().v4(),
        title: title ?? content.displayTitle,
        content: content,
        createdAt: DateTime.now(),
        isPermanent: isPermanent,
        sourceDevice: deviceName,
        contentHash: hash,
      );
      items.insert(0, item);
    }

    await _save();
    onItemsChanged?.call(items);

    if (broadcast) {
      _broadcastAdd(items[0]);
    }

    appLog('Transfer: added item "${items[0].title}" (permanent: $isPermanent)');
  }

  Future<void> removeItem(String id) async {
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) return;

    final item = items[index];
    items.removeAt(index);
    await _save();
    onItemsChanged?.call(items);
    _broadcastRemove(id);

    // Clean up local files
    if (item.content.type == 'file') {
      try {
        final file = File(item.content.value['filePath']);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    } else if (item.content.type == 'folder') {
      try {
        final dir = Directory(item.content.value['folderPath']);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }

    appLog('Transfer: removed item "${item.title}"');
  }

  Future<void> togglePermanent(String id) async {
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) return;

    items[index].isPermanent = !items[index].isPermanent;
    await _save();
    onItemsChanged?.call(items);
    appLog('Transfer: toggled permanent for "${items[index].title}" -> ${items[index].isPermanent}');
  }

  Future<void> clearAll() async {
    for (final item in items) {
      if (item.content.type == 'file') {
        try {
          final file = File(item.content.value['filePath']);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      } else if (item.content.type == 'folder') {
        try {
          final dir = Directory(item.content.value['folderPath']);
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
    items.clear();
    await _save();
    onItemsChanged?.call(items);
    _broadcastList();
    appLog('Transfer: cleared all items');
  }

  // MARK: - Remote Sync Handling

  void handleRemoteAdd(String json, String device) {
    try {
      final payload = jsonDecode(json) as Map<String, dynamic>;
      _upsertRemotePayload(payload, device);
      _save();
      onItemsChanged?.call(items);
      appLog('Transfer: received remote item "${payload['title'] ?? ''}" from $device');
    } catch (e) {
      appLog('Transfer: failed to decode remote add: $e', level: 'error');
    }
  }

  void handleRemoteList(String jsonStr, String device) {
    try {
      final payload = jsonDecode(jsonStr) as Map<String, dynamic>;
      final rawItems = (payload['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final remoteIds = rawItems.map((item) => item['id']?.toString()).whereType<String>().toSet();

      items.removeWhere((item) => item.sourceDevice == device && !remoteIds.contains(item.id));
      for (final itemPayload in rawItems) {
        _upsertRemotePayload(itemPayload, device);
      }
      _sortItems();
      _save();
      onItemsChanged?.call(items);
      appLog('Transfer: synced ${rawItems.length} transfer items from $device');
    } catch (e) {
      appLog('Transfer: failed to decode remote list: $e', level: 'error');
    }
  }

  void handleRemoteRemove(String jsonStr) {
    try {
      final dict = jsonDecode(jsonStr) as Map<String, dynamic>;
      final id = dict['id'] as String?;
      if (id == null) return;

      final index = items.indexWhere((item) => item.id == id);
      if (index >= 0) {
        final item = items[index];
        items.removeAt(index);
        _save();
        onItemsChanged?.call(items);
        appLog('Transfer: remote removed item "${item.title}"');
      }
    } catch (e) {
      appLog('Transfer: failed to decode remote remove: $e', level: 'error');
    }
  }

  void syncAllTo(String deviceName) {
    final jsonStr = jsonEncode({
      'items': _localItems.map((item) => item.toPayload()).toList(),
    });
    SyncManager.instance.sendTransferMessage(
      type: 'transfer/list',
      content: jsonStr,
      hash: '',
      targetDevice: deviceName,
    );
    for (final item in _localItems) {
      if (item.content.type == 'file') {
        SyncManager.instance.sendTransferFile(
          File(item.content.value['filePath']),
          targetDevice: deviceName,
        );
      }
    }
  }

  void _broadcastList() {
    if (!SyncManager.instance.isEnabled) return;
    final jsonStr = jsonEncode({
      'items': _localItems.map((item) => item.toPayload()).toList(),
    });
    SyncManager.instance.broadcastTransferMessage(
      type: 'transfer/list',
      content: jsonStr,
      hash: '',
    );
  }

  // MARK: - Broadcasting

  void _broadcastAdd(TransferItem item, {String? targetDevice}) {
    if (!SyncManager.instance.isEnabled) return;

    final payload = item.toPayload();
    final jsonStr = jsonEncode(payload);

    if (targetDevice != null) {
      SyncManager.instance.sendTransferMessage(
        type: 'transfer/add',
        content: jsonStr,
        hash: item.contentHash,
        targetDevice: targetDevice,
      );
    } else {
      SyncManager.instance.broadcastTransferMessage(
        type: 'transfer/add',
        content: jsonStr,
        hash: item.contentHash,
      );
    }
  }

  void _broadcastRemove(String id) {
    if (!SyncManager.instance.isEnabled) return;

    final jsonStr = jsonEncode({'id': id});
    SyncManager.instance.broadcastTransferMessage(
      type: 'transfer/remove',
      content: jsonStr,
      hash: '',
    );
  }

  // MARK: - File Helpers

  Future<void> addFileItem(File file, {bool isPermanent = false}) async {
    final fileName = file.uri.pathSegments.last;
    final fileSize = await file.length();

    final destDir = await _transferFilesDirectory();
    final destFile = File('${destDir.path}/$fileName');

    if (destFile.path != file.path) {
      if (await destFile.exists()) await destFile.delete();
      await file.copy(destFile.path);
    }

    await addItem(
      TransferContent(type: 'file', value: {
        'filePath': destFile.path,
        'fileName': fileName,
        'fileSize': fileSize,
      }),
      title: fileName,
      isPermanent: isPermanent,
    );

    if (SyncManager.instance.isEnabled) {
      await SyncManager.instance.broadcastTransferFile(destFile);
    }
  }

  Future<void> addReceivedFileItem({
    required File file,
    required String fileName,
    required int fileSize,
    required String sourceDevice,
  }) async {
    final content = TransferContent(type: 'file', value: {
      'filePath': file.path,
      'fileName': fileName,
      'fileSize': fileSize,
    });
    final hash = _computeHash(content);
    final item = TransferItem(
      id: const Uuid().v4(),
      title: fileName,
      content: content,
      createdAt: DateTime.now(),
      sourceDevice: sourceDevice,
      contentHash: hash,
    );

    items.removeWhere((existing) =>
        existing.contentHash == hash && existing.sourceDevice == sourceDevice);
    items.insert(0, item);
    await _save();
    onItemsChanged?.call(items);
    appLog('Transfer: received file item "$fileName" from $sourceDevice');
  }

  Future<void> addTextItem(String text, {bool isPermanent = false}) async {
    await addItem(
      TransferContent(type: 'text', value: text),
      isPermanent: isPermanent,
    );
  }

  // MARK: - Cleanup

  void _cleanupTempItems() {
    final cutoff = DateTime.now().subtract(const Duration(hours: _tempItemLifetimeHours));
    final expired = items.where((item) => !item.isPermanent && item.createdAt.isBefore(cutoff)).toList();

    for (final item in expired) {
      if (item.content.type == 'file') {
        try {
          File(item.content.value['filePath']).deleteSync();
        } catch (_) {}
      } else if (item.content.type == 'folder') {
        try {
          Directory(item.content.value['folderPath']).deleteSync(recursive: true);
        } catch (_) {}
      }
    }

    final before = items.length;
    items.removeWhere((item) => !item.isPermanent && item.createdAt.isBefore(cutoff));
    if (items.length != before) {
      _save();
      appLog('Transfer: cleaned up ${before - items.length} expired temp items');
    }
  }

  // MARK: - Persistence

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(items.map((item) => item.toJson()).toList());
      await prefs.setString(_storageKey, json);
    } catch (e) {
      appLog('Transfer: failed to save items: $e', level: 'error');
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr == null) return;

      final List<dynamic> jsonList = jsonDecode(jsonStr);
      items = jsonList.map((json) => TransferItem.fromJson(json)).toList();
      appLog('Transfer: loaded ${items.length} items');
    } catch (e) {
      appLog('Transfer: failed to load items: $e', level: 'error');
    }
  }

  // MARK: - Helpers

  Future<Directory> _transferFilesDirectory() async {
    final appDir = await _getAppStorageDir();
    final dir = Directory('${appDir.path}/TransferFiles');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _getAppStorageDir() async {
    final base = Platform.isAndroid
        ? Directory('/data/data/com.clipyclone.clipy_android/files')
        : Directory('${Platform.environment['HOME']}/.clipy');
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }

  String _computeHash(TransferContent content) {
    String data;
    switch (content.type) {
      case 'text':
        data = (content.value as String).trim().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        break;
      case 'rtf':
      case 'image':
        data = content.value.toString();
        break;
      case 'file':
        data = '${content.value['fileName']}:${content.value['fileSize']}';
        break;
      case 'folder':
        data = '${content.value['folderName']}:${content.value['fileCount']}';
        break;
      default:
        data = content.value.toString();
    }
    return sha256.convert(utf8.encode(data)).toString();
  }

  void _upsertRemotePayload(Map<String, dynamic> payload, String device) {
    final contentHash = payload['contentHash'] ?? '';
    final index = items.indexWhere(
      (existing) =>
          existing.id == payload['id'] ||
          (existing.contentHash == contentHash && existing.sourceDevice == device),
    );
    var content = TransferContent.fromJson(payload['content']);
    if (index >= 0 &&
        content.type == 'file' &&
        items[index].content.type == 'file' &&
        File(items[index].content.value['filePath']).existsSync()) {
      content = items[index].content;
    }

    final item = TransferItem(
      id: payload['id'] ?? const Uuid().v4(),
      title: payload['title'] ?? '',
      content: content,
      createdAt: payload['createdAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(((payload['createdAt'] as num) * 1000).toInt())
          : DateTime.now(),
      isPermanent: payload['isPermanent'] ?? false,
      sourceDevice: device,
      contentHash: contentHash,
    );

    if (index >= 0) {
      items[index] = item;
    } else {
      items.add(item);
    }
    _sortItems();
  }

  void _sortItems() {
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Iterable<TransferItem> get _localItems =>
      items.where((item) => item.sourceDevice == SyncManager.instance.deviceId);
}
