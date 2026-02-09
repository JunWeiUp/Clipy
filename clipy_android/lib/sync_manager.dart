import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nsd/nsd.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class SyncManager extends ChangeNotifier {
  static final SyncManager instance = SyncManager._();
  SyncManager._();

  final String serviceType = '_clipy-sync._tcp';

  Discovery? _discovery;
  Registration? _registration;

  final Map<String, String> _discoveredDeviceIps = {};
  final Map<String, DateTime> _deviceLastSeen = {};
  final Map<String, DateTime> _recentContentHashes = {};
  final Duration _contentHashTtl = const Duration(minutes: 5);
  final Set<String> _resolvingServices = {};

  Set<String> _allowedDevices = {};
  Set<String> _discoveredDevices = {};
  bool _isSyncEnabled = false;
  String _deviceName = 'Android Device';
  String _syncKey = 'clipy-clone-secret-key-32-chars!!';

  static const MethodChannel _serviceControlChannel = MethodChannel('clipy_sync_service_control');
  static const MethodChannel _serviceDataChannel = MethodChannel('clipy_sync_service');
  bool _channelReady = false;

  HttpClient? _httpClient;

  encrypt.Key get _key {
    var keyBytes = utf8.encode(_syncKey);
    if (keyBytes.length < 32) {
      keyBytes = Uint8List.fromList([...keyBytes, ...List.filled(32 - keyBytes.length, 0)]);
    } else if (keyBytes.length > 32) {
      keyBytes = keyBytes.sublist(0, 32);
    }
    return encrypt.Key(Uint8List.fromList(keyBytes));
  }

  encrypt.Encrypter get _encrypter => encrypt.Encrypter(encrypt.AES(_key, mode: encrypt.AESMode.gcm));

  bool get isSyncEnabled => _isSyncEnabled;
  String get deviceName => _deviceName;
  String get syncKey => _syncKey;
  Set<String> get discoveredDevices => _discoveredDevices;
  Set<String> get allowedDevices => _allowedDevices;
  Map<String, DateTime> get deviceLastSeen => _deviceLastSeen;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isSyncEnabled = prefs.getBool('isSyncEnabled') ?? false;
    _deviceName = prefs.getString('syncDeviceName') ?? (Platform.isAndroid ? 'Android' : 'Device');
    _allowedDevices = (prefs.getStringList('allowedDevices') ?? []).toSet();
    _syncKey = prefs.getString('syncKey') ?? 'clipy-clone-secret-key-32-chars!!';
    _setupServiceChannel();
    if (_isSyncEnabled) {
      start();
    }
  }

  Future<void> setSyncKey(String key) async {
    _syncKey = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('syncKey', key);
    notifyListeners();
  }

  Future<void> setSyncEnabled(bool enabled) async {
    _isSyncEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isSyncEnabled', enabled);
    if (enabled) {
      start();
    } else {
      stop();
    }
    notifyListeners();
  }

  Future<void> toggleDeviceAllowance(String deviceName) async {
    if (_allowedDevices.contains(deviceName)) {
      _allowedDevices.remove(deviceName);
    } else {
      _allowedDevices.add(deviceName);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('allowedDevices', _allowedDevices.toList());
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    _deviceName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('syncDeviceName', name);
    if (_isSyncEnabled) {
      stop();
      start();
    }
    notifyListeners();
  }

  void start() async {
    await _startService();
    await _registerService();
    await _startBrowsing();
  }

  void stop() async {
    await _stopBrowsing();
    await _unregisterService();
    await _stopService();
    _discoveredDevices.clear();
    _discoveredDeviceIps.clear();
    notifyListeners();
  }

  void _setupServiceChannel() {
    if (_channelReady) return;
    _serviceDataChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSyncPayload') {
        final payload = call.arguments as String?;
        if (payload != null) {
          await handleIncomingPayload(payload);
        }
      }
    });
    _channelReady = true;
  }

  Future<void> _startService() async {
    if (!Platform.isAndroid) return;
    try {
      await _serviceControlChannel.invokeMethod('startService');
    } catch (e) {
      debugPrint('Start service error: $e');
    }
  }

  Future<void> _stopService() async {
    if (!Platform.isAndroid) return;
    try {
      await _serviceControlChannel.invokeMethod('stopService');
    } catch (e) {
      debugPrint('Stop service error: $e');
    }
  }

  Future<void> _registerService() async {
    if (_registration != null) {
      await unregister(_registration!);
      _registration = null;
    }
    _registration = await register(Service(
      name: _deviceName,
      type: serviceType,
      port: 8080,
    ));
  }

  Future<void> _unregisterService() async {
    if (_registration != null) {
      await unregister(_registration!);
      _registration = null;
    }
  }

  Future<void> _startBrowsing() async {
    _discovery = await startDiscovery(serviceType);
    _discovery!.addListener(() {
      final currentDiscovered = <String>{};
      final currentIps = <String, String>{};
      for (var service in _discovery!.services) {
        final name = service.name;
        if (name == null || name == _deviceName) {
          continue;
        }
        currentDiscovered.add(name);
        final host = service.host;
        if (host != null) {
          currentIps[name] = host;
        } else {
          _resolveService(service);
        }
      }
      _discoveredDevices = currentDiscovered;
      _discoveredDeviceIps
        ..clear()
        ..addAll(currentIps);
      notifyListeners();
    });
  }

  Future<void> _stopBrowsing() async {
    if (_discovery != null) {
      await stopDiscovery(_discovery!);
      _discovery = null;
    }
  }

  Future<void> _resolveService(Service service) async {
    final name = service.name;
    if (name == null) return;
    if (_resolvingServices.contains(name)) return;
    _resolvingServices.add(name);
    try {
      final resolved = await resolve(service);
      final host = resolved.host;
      if (host != null) {
        _discoveredDeviceIps[name] = host;
        _discoveredDevices.add(name);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Resolve service error: $e');
    } finally {
      _resolvingServices.remove(name);
    }
  }

  Future<void> handleIncomingPayload(String payload) async {
    try {
      dynamic json = jsonDecode(payload);
      if (json is Map && json['payload'] != null && json['iv'] != null && json['tag'] != null) {
        final decrypted = _decrypt(json['payload'], json['iv'], json['tag']);
        if (decrypted != null) {
          json = jsonDecode(decrypted);
        }
      }
      if (json is! Map<String, dynamic>) {
        return;
      }
      final origin = json['origin'] as String?;
      if (origin == null || origin == _deviceName) {
        return;
      }
      if (!_allowedDevices.contains(origin)) {
        return;
      }
      final contentHash = json['contentHash'] as String?;
      if (contentHash != null && _hasSeenContentHash(contentHash)) {
        return;
      }
      if (json['historyItem'] != null) {
        final entry = HistoryEntry.fromJson(json['historyItem']);
        final hash = entry.contentHash ?? contentHash ?? _contentHashForHistoryItem(entry.item);
        if (hash != null) {
          _recordContentHash(hash);
        }
        final normalizedEntry = HistoryEntry(
          item: entry.item,
          date: entry.date,
          sourceApp: entry.sourceApp,
          contentHash: hash ?? entry.contentHash,
        );
        _updateLastSeen(origin);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lastSync_$origin', DateTime.now().toIso8601String());
        onHistorySynced?.call(normalizedEntry);
        return;
      }
      if (json['snippetFolders'] != null) {
        final folders = (json['snippetFolders'] as List)
            .map((f) => SnippetFolder.fromJson(f))
            .toList();
        final hash = contentHash ?? _contentHashForSnippetFolders(folders);
        if (hash != null) {
          _recordContentHash(hash);
        }
        _updateLastSeen(origin);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lastSync_$origin', DateTime.now().toIso8601String());
        onSnippetsSynced?.call(folders);
      }
    } catch (e) {
      debugPrint('Handle payload error: $e');
    }
  }

  void broadcastHistory(HistoryEntry entry) {
    if (!_isSyncEnabled) return;
    final hash = entry.contentHash ?? _contentHashForHistoryItem(entry.item);
    if (hash == null) return;
    final normalizedEntry = HistoryEntry(
      item: entry.item,
      date: entry.date,
      sourceApp: entry.sourceApp,
      contentHash: hash,
    );
    _recordContentHash(hash);
    final message = {
      'historyItem': normalizedEntry.toJson(),
      'contentHash': hash,
      'origin': _deviceName,
    };
    final payload = _encodePayload(message);
    if (payload == null) return;
    for (var entry in _discoveredDeviceIps.entries) {
      if (_allowedDevices.contains(entry.key)) {
        _postSync(entry.value, payload);
      }
    }
  }

  void broadcastSnippets(List<SnippetFolder> folders) {
    if (!_isSyncEnabled) return;
    final hash = _contentHashForSnippetFolders(folders);
    if (hash == null) return;
    _recordContentHash(hash);
    final message = {
      'snippetFolders': folders.map((f) => f.toJson()).toList(),
      'contentHash': hash,
      'origin': _deviceName,
    };
    final payload = _encodePayload(message);
    if (payload == null) return;
    for (var entry in _discoveredDeviceIps.entries) {
      if (_allowedDevices.contains(entry.key)) {
        _postSync(entry.value, payload);
      }
    }
  }

  String? _encodePayload(Map<String, dynamic> message) {
    try {
      final jsonStr = jsonEncode(message);
      if (message.containsKey('historyItem') || message.containsKey('snippetFolders')) {
        final encrypted = _encrypt(jsonStr);
        if (encrypted != null) {
          return jsonEncode(encrypted);
        }
      }
      return jsonStr;
    } catch (e) {
      debugPrint('Encode payload error: $e');
      return null;
    }
  }

  Future<void> _postSync(String ip, String payload) async {
    try {
      final client = _httpClient ??= HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final request = await client.post(ip, 8080, '/sync');
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(payload));
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain();
    } catch (e) {
      debugPrint('HTTP sync failed to $ip: $e');
    }
  }

  Map<String, String>? _encrypt(String data) {
    try {
      final iv = encrypt.IV.fromLength(12);
      final encrypted = _encrypter.encrypt(data, iv: iv);
      final bytes = encrypted.bytes;
      if (bytes.length < 16) {
        return null;
      }
      final tag = bytes.sublist(bytes.length - 16);
      final cipher = bytes.sublist(0, bytes.length - 16);
      return {
        'iv': iv.base64,
        'payload': base64Encode(cipher),
        'tag': base64Encode(tag),
      };
    } catch (e) {
      debugPrint('Encryption error: $e');
      return null;
    }
  }

  String? _decrypt(String payload, String ivStr, String tagStr) {
    try {
      final iv = encrypt.IV.fromBase64(ivStr);
      final ciphertext = base64Decode(payload);
      final tag = base64Decode(tagStr);
      final combined = Uint8List.fromList([...ciphertext, ...tag]);
      final encrypted = encrypt.Encrypted(combined);
      return _encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      debugPrint('Decryption error: $e');
      return null;
    }
  }

  void _updateLastSeen(String deviceName) {
    _deviceLastSeen[deviceName] = DateTime.now();
    notifyListeners();
  }

  void _pruneContentHashes(DateTime now) {
    _recentContentHashes.removeWhere((key, value) => now.difference(value) > _contentHashTtl);
  }

  void _recordContentHash(String hash) {
    _recentContentHashes[hash] = DateTime.now();
  }

  bool _hasSeenContentHash(String hash) {
    _pruneContentHashes(DateTime.now());
    return _recentContentHashes.containsKey(hash);
  }

  String _normalizeString(String value) {
    return value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  String? _contentHashForHistoryItem(HistoryItem item) {
    switch (item.type) {
      case 'text':
        final normalized = _normalizeString((item.value as String).trim());
        return sha256.convert(utf8.encode(normalized)).toString();
      default:
        final normalized = _normalizeString(jsonEncode(item.toJson()));
        return sha256.convert(utf8.encode(normalized)).toString();
    }
  }

  String? _contentHashForSnippetFolders(List<SnippetFolder> folders) {
    final sortedFolders = List<SnippetFolder>.from(folders)
      ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    final parts = <String>[];
    for (final folder in sortedFolders) {
      final folderTitle = _normalizeString(folder.title);
      parts.add('F|${folder.id.toLowerCase()}|$folderTitle|${folder.isEnabled ? "1" : "0"}');
      final sortedSnippets = List<Snippet>.from(folder.snippets)
        ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
      for (final snippet in sortedSnippets) {
        final title = _normalizeString(snippet.title);
        final content = _normalizeString(snippet.content);
        parts.add('S|${snippet.id.toLowerCase()}|$title|$content');
      }
    }
    final joined = parts.join('\n');
    return sha256.convert(utf8.encode(joined)).toString();
  }

  void Function(HistoryEntry)? onHistorySynced;
  void Function(List<SnippetFolder>)? onSnippetsSynced;
  List<HistoryEntry> Function()? onGetHistory;
}
