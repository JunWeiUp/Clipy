import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:nsd/nsd.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'log_manager.dart';
import 'clipboard_manager.dart';
import 'notification_manager.dart';
import 'compression_utils.dart';
import 'storage_paths.dart';
import 'database/file_transfer_repository.dart';
import 'database/collector_repository.dart';

class SyncMessage {
  final String deviceId;
  final double timestamp;
  final String type;
  final String content;
  final String hash;

  SyncMessage({
    required this.deviceId,
    required this.timestamp,
    required this.type,
    required this.content,
    required this.hash,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'timestamp': timestamp,
        'type': type,
        'content': content,
        'hash': hash,
      };

  factory SyncMessage.fromJson(Map<String, dynamic> json) => SyncMessage(
        deviceId: json['deviceId'],
        timestamp: json['timestamp'],
        type: json['type'],
        content: json['content'],
        hash: json['hash'],
      );
}

class FileHeader {
  final String fileId;
  final String fileName;
  final int fileSize;

  FileHeader({required this.fileId, required this.fileName, required this.fileSize});

  factory FileHeader.fromJson(Map<String, dynamic> json) => FileHeader(
        fileId: json['fileId'],
        fileName: json['fileName'],
        fileSize: json['fileSize'],
      );
}

class FileChunk {
  final String fileId;
  final int chunkIndex;
  final String data;
  final bool isLast;
  final bool isCompressed;
  final int? originalSize;

  FileChunk({
    required this.fileId, 
    required this.chunkIndex, 
    required this.data, 
    required this.isLast,
    this.isCompressed = false,
    this.originalSize,
  });

  factory FileChunk.fromJson(Map<String, dynamic> json) => FileChunk(
        fileId: json['fileId'],
        chunkIndex: json['chunkIndex'],
        data: json['data'],
        isLast: json['isLast'],
        isCompressed: json['isCompressed'] ?? false,
        originalSize: json['originalSize'],
      );
}

class FileProgress {
  final String fileId;
  final String fileName;
  final double progress; // 0.0 to 1.0
  final int receivedBytes;
  final int totalBytes;
  final bool isCompleted;
  final bool isFailed;

  FileProgress({
    required this.fileId,
    required this.fileName,
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    this.isCompleted = false,
    this.isFailed = false,
  });
}

class _PendingFile {
  final FileHeader header;
  final String senderName;
  final File file;
  final IOSink sink;
  int receivedBytes = 0;

  _PendingFile({required this.header, required this.senderName, required this.file, required this.sink});
}

class DiscoveredPeer {
  final String peerId;
  final String displayName;
  final Service service;

  const DiscoveredPeer({
    required this.peerId,
    required this.displayName,
    required this.service,
  });
}

class SyncManager {
  static final SyncManager instance = SyncManager._();
  SyncManager._();

  Registration? _registration;
  Discovery? _discovery;
  ServerSocket? _server;
  final Map<String, DiscoveredPeer> _discoveredPeers = {};
  
  final _devicesChangedController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get onDevicesChanged => _devicesChangedController.stream;

  final _peersChangedController = StreamController<List<DiscoveredPeer>>.broadcast();
  Stream<List<DiscoveredPeer>> get onPeersChanged => _peersChangedController.stream;
  
  final _fileReceivedController = StreamController<String>.broadcast();
  Stream<String> get onFileReceived => _fileReceivedController.stream;

  final _fileProgressController = StreamController<FileProgress>.broadcast();
  Stream<FileProgress> get onFileProgress => _fileProgressController.stream;

  final Map<String, _PendingFile> _pendingFiles = {};
  final Map<String, DateTime> _lastProgressUpdate = {};
  
  List<DiscoveredPeer> get availablePeers {
    final peers = _discoveredPeers.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return peers;
  }

  List<String> get availableDeviceNames => availablePeers.map((p) => p.displayName).toList();

  bool isEnabled = false;
  int port = 5566;
  List<String> authorizedPeerIds = [];

  String _deviceName = '';
  String _peerId = '';

  String get peerId => _peerId;
  String get displayName => _deviceName.isEmpty ? _peerId : _deviceName;
  /// SyncMessage.deviceId and legacy call sites.
  String get deviceId => peerId;

  final String _serviceType = '_clipy-sync._tcp';

  static String _peerIdFromService(Service service, String displayName) {
    final txt = service.txt;
    if (txt != null && txt['peerId'] != null) {
      return utf8.decode(txt['peerId']!);
    }
    return displayName;
  }

  Future<void> _migrateAuthorizedPeerIds() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('authorizedPeerIdsMigrated') ?? false) return;

    final legacyNames = prefs.getStringList('authorizedDevices') ?? [];
    final peerIds = {...authorizedPeerIds};
    for (final legacyName in legacyNames) {
      final match = availablePeers.where((p) => p.displayName == legacyName);
      if (match.isNotEmpty) {
        peerIds.add(match.first.peerId);
      } else {
        peerIds.add(legacyName);
      }
    }
    authorizedPeerIds = peerIds.toList()..sort();
    await prefs.setStringList('authorizedPeerIds', authorizedPeerIds);
    await prefs.setBool('authorizedPeerIdsMigrated', true);
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('syncEnabled') ?? false;
    port = prefs.getInt('syncPort') ?? 5566;
    authorizedPeerIds = prefs.getStringList('authorizedPeerIds') ?? [];
    _deviceName = (prefs.getString('deviceName') ?? '').trim();
    _peerId = (prefs.getString('peerId') ?? prefs.getString('deviceId') ?? '').trim();
    if (_peerId.isEmpty) {
      _peerId = '${Platform.isIOS ? 'iOS' : 'Android'}-${const Uuid().v4().substring(0, 8)}';
      await prefs.setString('peerId', _peerId);
      await prefs.setString('deviceId', _peerId);
    }

    if (isEnabled) {
      start();
    }
  }

  Future<void> setSyncTarget(String peerId, {required bool enabled}) async {
    final updated = List<String>.from(authorizedPeerIds);
    if (enabled) {
      if (!updated.contains(peerId)) {
        updated.add(peerId);
      }
    } else {
      updated.remove(peerId);
    }
    updated.sort();
    authorizedPeerIds = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('authorizedPeerIds', authorizedPeerIds);
    await refreshBrowsing();
  }

  Future<void> updateDeviceName(String name) async {
    final newName = name.trim();
    if (newName.isEmpty || newName == displayName) return;

    _deviceName = newName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceName', newName);
    if (isEnabled) {
      await stop();
      await Future.delayed(const Duration(seconds: 1));
      await start();
    }
  }

  Future<void> start() async {
    appLog('Starting sync services...');
    // Start server first to ensure the port is available
    final serverStarted = await startServer();
    if (serverStarted) {
      await CollectorRepository.instance.markAllClipboardSynced();
      await startPublishing();
      await startBrowsing();
    } else {
      appLog('Skipping mDNS publishing because server failed to start', level: 'error');
    }
  }

  Future<void> stop() async {
    appLog('Stopping sync services...');
    if (_registration != null) {
      try {
        await unregister(_registration!);
      } catch (e) {
        appLog('Error unregistering: $e');
      }
      _registration = null;
    }
    if (_discovery != null) {
      try {
        await stopDiscovery(_discovery!);
      } catch (e) {
        appLog('Error stopping discovery: $e');
      }
      _discovery = null;
    }
    await _server?.close();
    _server = null;
    _discoveredPeers.clear();
    _devicesChangedController.add(availableDeviceNames);
    _peersChangedController.add(availablePeers);
  }

  // MARK: - mDNS Publishing
  Future<void> startPublishing() async {
    appLog('Publishing mDNS service: $displayName (peerId=$peerId) on port $port');
    try {
      _registration = await register(Service(
        name: displayName,
        type: _serviceType,
        port: port,
        txt: {'peerId': Uint8List.fromList(utf8.encode(peerId))},
      ));
      appLog('mDNS service published successfully');
    } catch (e) {
      appLog('Failed to publish mDNS service: $e', level: 'error');
    }
  }

  // MARK: - mDNS Browsing
  Future<void> startBrowsing() async {
    if (_discovery != null) return;
    appLog('Starting mDNS browsing for $_serviceType');
    try {
      _discovery = await startDiscovery(
        _serviceType,
        ipLookupType: IpLookupType.v4,
      );
      _discovery!.addListener(() async {
        _discoveredPeers.clear();
        final seenPeerIds = <String>{};
        for (final service in _discovery!.services) {
          final name = service.name;
          if (name == null || name.isEmpty || name == displayName) continue;
          final remotePeerId = _peerIdFromService(service, name);
          if (remotePeerId == peerId || seenPeerIds.contains(remotePeerId)) continue;
          seenPeerIds.add(remotePeerId);
          _discoveredPeers[remotePeerId] = DiscoveredPeer(
            peerId: remotePeerId,
            displayName: name,
            service: service,
          );
        }
        await _migrateAuthorizedPeerIds();
        _devicesChangedController.add(availableDeviceNames);
        _peersChangedController.add(availablePeers);
        appLog('Discovered peers updated (${availablePeers.length}): ${availablePeers.map((p) => "${p.displayName}:${p.peerId}").join(", ")}');
      });
    } catch (e) {
      appLog('Failed to start mDNS browsing: $e', level: 'error');
    }
  }

  Future<void> refreshBrowsing() async {
    if (!isEnabled) return;
    if (_discovery == null) {
      await startBrowsing();
    }
  }

  // MARK: - Server (TCP Socket)
  Future<bool> startServer() async {
    try {
      // Prioritize IPv4 for better compatibility on Android LAN
      appLog('Attempting to bind TCP server to IPv4 any (0.0.0.0) on port $port');
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
      _server!.listen(_handleConnection);
      
      appLog('SUCCESS: Sync TCP server listening on IPv4: ${_server!.address.address}:${_server!.port}');
      
      // Also try to bind to IPv6 if possible, but don't fail if it's already handled by IPv4 or port busy
      try {
        final v6Server = await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: true, shared: true);
        v6Server.listen(_handleConnection);
        if (kDebugMode) {
          appLog('SUCCESS: Sync TCP server also listening on IPv6: ${v6Server.address.address}:${v6Server.port}');
        }
      } catch (e) {
        if (kDebugMode) {
          appLog('Note: IPv6 bind skipped (already handled or port busy): $e');
        }
      }
      
      if (kDebugMode) {
        final interfaces = await NetworkInterface.list();
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            appLog('Local Network Interface: ${interface.name} (${addr.type.name}) - ${addr.address}');
          }
        }
      }
      return true;
    } catch (e) {
      appLog('CRITICAL: Failed to start server: $e', level: 'error');
      return false;
    }
  }

  Future<void> _handleConnection(Socket socket) async {
    appLog('New incoming connection from ${socket.remoteAddress.address}:${socket.remotePort}');

    final buffer = <int>[];
    int? expectedLength;

    try {
      await for (var data in socket) {
        buffer.addAll(data);

        while (true) {
          if (buffer.length >= 4 && expectedLength == null) {
            final firstFour = String.fromCharCodes(buffer.sublist(0, 4));
            if (firstFour == 'GET ' || firstFour == 'POST' || firstFour == 'HEAD') {
              appLog('Detected incoming HTTP request instead of TCP packet. Closing connection.', level: 'warn');
              socket.destroy();
              return;
            }
          }

          if (expectedLength == null) {
            if (buffer.length >= 4) {
              final lengthData = buffer.sublist(0, 4);
              final length = ByteData.sublistView(Uint8List.fromList(lengthData)).getUint32(0, Endian.big);

              if (length > 1024 * 1024) {
                appLog('Invalid packet length: $length (too large). Potential protocol mismatch.', level: 'error');
                socket.destroy();
                return;
              }

              expectedLength = length;
              buffer.removeRange(0, 4);
            } else {
              break;
            }
          }

          final messageLength = expectedLength;
          if (buffer.length >= messageLength) {
            final messageData = buffer.sublist(0, messageLength);
            buffer.removeRange(0, messageLength);

            try {
              final jsonString = utf8.decode(messageData);
              final json = jsonDecode(jsonString);
              final message = SyncMessage.fromJson(json);
              appLog('Parsed SyncMessage from ${message.deviceId}, type: ${message.type}');
              await _handleSyncMessage(message);
            } catch (e) {
              appLog('Error parsing sync message: $e', level: 'error');
            }

            expectedLength = null;
          } else {
            break;
          }
        }
      }
    } catch (e) {
      appLog('Socket error: $e', level: 'error');
    } finally {
      socket.destroy();
    }
  }

  Future<void> _handleSyncMessage(SyncMessage message) async {
    final isFileMessage =
        message.type == 'file/header' || message.type == 'file/chunk';
    final isClipboardMessage = message.type == 'text/plain';
    final isCollectorMessage = message.type == 'collector/event';
    if (!isFileMessage &&
        !isClipboardMessage &&
        !isCollectorMessage &&
        !authorizedPeerIds.contains(message.deviceId)) {
      appLog('Rejecting message from unauthorized peer: ${message.deviceId}', level: 'warning');
      return;
    }

    // Use compute for decryption of large content to avoid UI freeze
    String? decrypted;
    if (message.content.length > 1024 * 10) { // More than 10KB
      decrypted = await compute(_decryptStatic, message.content);
    } else {
      decrypted = _decrypt(message.content);
    }
    
    if (decrypted == null) {
      appLog('Failed to decrypt message from ${message.deviceId}, type: ${message.type}', level: 'error');
      return;
    }

    if (message.type == 'text/plain') {
      appLog('Received sync from ${message.deviceId}: ${decrypted.length > 20 ? '${decrypted.substring(0, 20)}...' : decrypted}');
      await ClipboardManager.instance.handleRemoteSync(decrypted, message.hash);
    } else if (message.type == 'file/header') {
      await _handleFileHeader(decrypted, message.deviceId);
    } else if (message.type == 'file/chunk') {
      await _handleFileChunk(decrypted, message.deviceId);
    } else if (message.type == 'notification/post') {
      NotificationManager.instance.handleRemoteNotification(decrypted, message.deviceId);
    } else if (message.type == 'notification/dismiss') {
      NotificationManager.instance.handleRemoteDismiss(decrypted);
    } else if (message.type == 'notification/clear_all') {
      NotificationManager.instance.clearAll();
    } else if (message.type == 'notification/config') {
      _handleNotificationConfig(decrypted);
    } else if (message.type == 'collector/event') {
      // Non-clipboard collector events are not handled on Android.
    }
  }

  void _handleNotificationConfig(String decrypted) {
    try {
      final json = jsonDecode(decrypted);
      final packages = (json['allowedPackages'] as List?)?.cast<String>() ?? [];
      NotificationManager.instance.updateAllowedPackages(packages);
    } catch (e) {
      appLog('Error handling notification config: $e', level: 'error');
    }
  }

  Future<void> broadcastNotificationMessage({
    required String type,
    required String content,
    required String hash,
  }) async {
    if (!isEnabled) return;

    appLog('Broadcasting notification message: $type');
    final encrypted = _encrypt(content);
    if (encrypted == null) return;

    final message = SyncMessage(
      deviceId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: type,
      content: encrypted,
      hash: hash,
    );

    final jsonData = jsonEncode(message.toJson());

    for (var peer in availablePeers) {
      if (authorizedPeerIds.contains(peer.peerId)) {
        appLog('Sending notification message to ${peer.displayName}...');
        await _sendSync(jsonData, peer.service);
      }
    }
  }

  Future<void> broadcastCollectorEvent({
    required String content,
    required String hash,
  }) async {
    if (!isEnabled) return;

    final encrypted = _encrypt(content);
    if (encrypted == null) return;

    final message = SyncMessage(
      deviceId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'collector/event',
      content: encrypted,
      hash: hash,
    );

    final jsonData = jsonEncode(message.toJson());
    var sentCount = 0;
    for (var peer in availablePeers) {
      if (authorizedPeerIds.contains(peer.peerId)) {
        appLog('Sending collector event to ${peer.displayName}...');
        await _sendSync(jsonData, peer.service);
        sentCount++;
      }
    }
    if (sentCount == 0 && kDebugMode) {
      appLog(
        'Collector event not sent: authorizedPeerIds=[${authorizedPeerIds.join(", ")}], discovered=[${availablePeers.map((p) => p.displayName).join(", ")}]',
      );
    }
  }

  Future<void> _handleFileHeader(String json, String sender) async {
    try {
      final header = FileHeader.fromJson(jsonDecode(json));
      appLog('Received FileHeader for ${header.fileName} (${header.fileSize} bytes) from $sender');

      final appDir = await StoragePaths.appStorageDirectory();
      final targetDirectory = Directory('${appDir.path}/Clipy');
      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }

      final uniqueFileName = await _getUniqueFileName(targetDirectory.path, header.fileName);
      final file = File(uniqueFileName);
      
      final sink = file.openWrite();
      _pendingFiles[header.fileId] = _PendingFile(
        header: header,
        senderName: sender,
        file: file,
        sink: sink,
      );
      
      appLog('File will be saved to: ${file.path}');
    } catch (e) {
      appLog('Error handling file header: $e', level: 'error');
    }
  }

  Future<String> _getUniqueFileName(String directoryPath, String originalFileName) async {
    final file = File('$directoryPath/$originalFileName');
    if (!await file.exists()) {
      return file.path;
    }
    
    // Add timestamp to avoid conflicts
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final lastDotIndex = originalFileName.lastIndexOf('.');
    if (lastDotIndex > 0 && lastDotIndex < originalFileName.length - 1) {
      // Has extension
      final nameWithoutExt = originalFileName.substring(0, lastDotIndex);
      final ext = originalFileName.substring(lastDotIndex);
      final newFileName = '$nameWithoutExt-$timestamp$ext';
      return '$directoryPath/$newFileName';
    } else {
      // No extension or dot at the end
      final newFileName = '$originalFileName-$timestamp';
      return '$directoryPath/$newFileName';
    }
  }

  Future<void> _handleFileChunk(String json, String sender) async {
    try {
      final chunk = FileChunk.fromJson(jsonDecode(json));
      final pending = _pendingFiles[chunk.fileId];
      
      if (pending == null) {
        appLog('Received chunk for unknown fileId: ${chunk.fileId}', level: 'error');
        return;
      }

      var data = base64Decode(chunk.data);

      // Handle decompression if needed
      if (chunk.isCompressed && chunk.originalSize != null) {
        try {
          final decompressed = CompressionUtils.decompressData(data);
          if (decompressed != null) {
            data = decompressed;
            appLog('Decompressed chunk ${chunk.chunkIndex} from ${base64Decode(chunk.data).length} to ${data.length} bytes');
          } else {
            appLog('Decompression failed for chunk ${chunk.chunkIndex}, using original data', level: 'warning');
            // Continue with original compressed data (treat as uncompressed)
          }
        } catch (e) {
          appLog('Decompression error: $e, using original data', level: 'warning');
          // Continue with original data
        }
      }
      
      pending.sink.add(data);
      pending.receivedBytes += data.length;

      // Broadcast progress with throttling (max once every 100ms per file)
      final now = DateTime.now();
      final lastUpdate = _lastProgressUpdate[chunk.fileId];
      if (chunk.isLast || lastUpdate == null || now.difference(lastUpdate).inMilliseconds > 100) {
        _lastProgressUpdate[chunk.fileId] = now;
        _fileProgressController.add(FileProgress(
          fileId: pending.header.fileId,
          fileName: pending.header.fileName,
          progress: pending.header.fileSize > 0 ? pending.receivedBytes / pending.header.fileSize : 1.0,
          receivedBytes: pending.receivedBytes,
          totalBytes: pending.header.fileSize,
          isCompleted: chunk.isLast,
        ));
      }

      if (chunk.isLast) {
        _lastProgressUpdate.remove(chunk.fileId);
        appLog('File transfer completed: ${pending.header.fileName}');
        await pending.sink.flush();
        await pending.sink.close();
        
        // Add to history
        await _addToFileHistory(
          fileName: pending.header.fileName,
          filePath: pending.file.path,
          fileSize: pending.header.fileSize,
          senderName: pending.senderName,
        );

        _pendingFiles.remove(chunk.fileId);
        _fileReceivedController.add(pending.header.fileName);
      }
    } catch (e) {
      appLog('Error handling file chunk: $e', level: 'error');
    }
  }

  Future<void> _addToFileHistory({
    required String fileName,
    required String filePath,
    required int fileSize,
    required String senderName,
  }) async {
    await FileTransferRepository.instance.insert(
      fileName: fileName,
      filePath: filePath,
      fileSize: fileSize,
      senderName: senderName,
    );
  }

  // MARK: - Encryption
  static const String _hardcodedSecret = "ClipySyncSecret2026";

  static encrypt.Key _getEncryptionKeyStatic() {
    final bytes = utf8.encode(_hardcodedSecret);
    final hash = sha256.convert(bytes);
    return encrypt.Key(hash.bytes as dynamic);
  }

  static String? _decryptStatic(String base64String) {
    try {
      final key = _getEncryptionKeyStatic();
      final data = base64Decode(base64String);
      
      // Try 12 bytes IV first (new format)
      if (data.length > 28) {
        try {
          final iv = encrypt.IV(data.sublist(0, 12));
          final encryptedBytes = data.sublist(12);
          final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
          return encrypter.decrypt(encrypt.Encrypted(encryptedBytes), iv: iv);
        } catch (e) {
          // Fallback to 16 bytes IV (old format)
          final iv = encrypt.IV(data.sublist(0, 16));
          final encryptedBytes = data.sublist(16);
          final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
          return encrypter.decrypt(encrypt.Encrypted(encryptedBytes), iv: iv);
        }
      } else if (data.length > 16) {
        // Must be old format
        final iv = encrypt.IV(data.sublist(0, 16));
        final encryptedBytes = data.sublist(16);
        final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
        return encrypter.decrypt(encrypt.Encrypted(encryptedBytes), iv: iv);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  encrypt.Key _getEncryptionKey() => _getEncryptionKeyStatic();

  String? _encrypt(String text) {
    try {
      final key = _getEncryptionKey();
      final iv = encrypt.IV.fromLength(12); // Use 12 bytes for GCM
      final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
      final encrypted = encrypter.encrypt(text, iv: iv);
      // Format: IV(12) + Ciphertext + Tag(16)
      // The 'encrypt' package for GCM includes the tag at the end of encrypted.bytes
      return base64Encode(iv.bytes + encrypted.bytes);
    } catch (e) {
      appLog('Encryption error: $e');
      return null;
    }
  }

  String? _decrypt(String base64String) => _decryptStatic(base64String);

  // MARK: - Sending
  Future<void> broadcastSync(String content, String hash) async {
    if (!isEnabled) return;

    appLog('Broadcasting sync to authorized devices...');
    final jsonData = _makeTextSyncPayload(content, hash);
    if (jsonData == null) return;

    var sentCount = 0;
    for (var peer in availablePeers) {
      if (authorizedPeerIds.contains(peer.peerId)) {
        appLog('Sending sync to ${peer.displayName} (peerId=${peer.peerId})...');
        await _sendSync(jsonData, peer.service);
        sentCount++;
      }
    }
    if (sentCount == 0) {
      appLog(
        'Sync not sent: authorizedPeerIds=[${authorizedPeerIds.join(", ")}], discovered=[${availablePeers.map((p) => "${p.displayName}:${p.peerId}").join(", ")}]',
        level: 'warning',
      );
    }
  }

  Future<void> sendText(String content, {required String targetDevice}) async {
    if (!isEnabled) return;

    final trimmed = content.trim();
    if (trimmed.isEmpty) return;

    final targets =
        availablePeers.where((p) => p.displayName == targetDevice).toList();
    if (targets.isEmpty) {
      appLog('Could not find endpoint for device: $targetDevice', level: 'error');
      return;
    }

    final hash = _contentHashForPlainText(content);
    final jsonData = _makeTextSyncPayload(content, hash);
    if (jsonData == null) return;

    appLog('Sending text to ${targets.first.displayName}...');
    await _sendSync(jsonData, targets.first.service);
  }

  String _contentHashForPlainText(String text) {
    final normalized = text
        .trim()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  String? _makeTextSyncPayload(String content, String hash) {
    final encrypted = _encrypt(content);
    if (encrypted == null) return null;

    final message = SyncMessage(
      deviceId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'text/plain',
      content: encrypted,
      hash: hash,
    );

    return jsonEncode(message.toJson());
  }

  Future<void> sendFile(File file, {required String targetDevice}) async {
    if (!isEnabled) return;
    final targets = availablePeers.where((p) => p.displayName == targetDevice).toList();
    if (targets.isEmpty) {
      appLog('Could not find endpoint for device: $targetDevice', level: 'error');
      return;
    }
    await _sendFile(
      file,
      service: targets.first.service,
      headerType: 'file/header',
      chunkType: 'file/chunk',
      addToFileHistory: true,
    );
  }

  Future<void> _sendFile(
    File file, {
    required Service service,
    required String headerType,
    required String chunkType,
    required bool addToFileHistory,
  }) async {
    try {
      if (!await file.exists()) {
        appLog('File does not exist: ${file.path}', level: 'error');
        return;
      }

      final fileId = const Uuid().v4();
      final fileName = file.uri.pathSegments.last;
      final fileSize = await file.length();
      final headerJson = jsonEncode({
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
      });

      final encryptedHeader = _encrypt(headerJson);
      if (encryptedHeader == null) return;
      final headerMessage = SyncMessage(
        deviceId: deviceId,
        timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
        type: headerType,
        content: encryptedHeader,
        hash: '',
      );
      await _sendSync(jsonEncode(headerMessage.toJson()), service);

      final shouldCompress = CompressionUtils.shouldCompressFile(file.path);
      const chunkSize = 128 * 1024;
      final raf = await file.open();
      try {
        var chunkIndex = 0;
        var bytesRead = 0;
        while (bytesRead < fileSize) {
          final rawData = await raf.read(chunkSize);
          if (rawData.isEmpty) break;

          bytesRead += rawData.length;
          var processedData = Uint8List.fromList(rawData);
          var isCompressed = false;
          int? originalSize;

          if (shouldCompress) {
            final compressed = CompressionUtils.compressData(processedData);
            if (compressed != null && compressed.length < processedData.length) {
              originalSize = processedData.length;
              processedData = compressed;
              isCompressed = true;
            }
          }

          final chunkJson = jsonEncode({
            'fileId': fileId,
            'chunkIndex': chunkIndex,
            'data': base64Encode(processedData),
            'isLast': bytesRead >= fileSize,
            'isCompressed': isCompressed,
            if (originalSize != null) 'originalSize': originalSize,
          });

          final encryptedChunk = _encrypt(chunkJson);
          if (encryptedChunk == null) break;
          final chunkMessage = SyncMessage(
            deviceId: deviceId,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
            type: chunkType,
            content: encryptedChunk,
            hash: '',
          );
          await _sendSync(jsonEncode(chunkMessage.toJson()), service);
          await Future.delayed(const Duration(milliseconds: 30));
          chunkIndex += 1;
        }
      } finally {
        await raf.close();
      }

      if (addToFileHistory) {
        await _addToFileHistory(
          fileName: fileName,
          filePath: file.path,
          fileSize: fileSize,
          senderName: 'Me (Sent to ${service.name ?? 'Unknown'})',
        );
      }
      appLog('File transfer completed for $fileName');
    } catch (e) {
      appLog('Failed to send file: $e', level: 'error');
    }
  }

  Future<void> _sendSync(String jsonData, Service service) async {
    try {
      var target = service;
      final needsResolve = (target.host == null || target.host!.isEmpty) &&
          (target.addresses == null || target.addresses!.isEmpty);
      if (needsResolve) {
        appLog('Resolving service ${service.name} before connect...');
        target = await resolve(service);
      }

      final port = target.port ?? this.port;
      Socket socket;

      if (target.addresses != null && target.addresses!.isNotEmpty) {
        final v4 = target.addresses!
            .where((a) => a.type == InternetAddressType.IPv4)
            .toList();
        final address = v4.isNotEmpty ? v4.first : target.addresses!.first;
        appLog('Connecting to ${service.name} at ${address.address}:$port');
        socket = await Socket.connect(
          address,
          port,
          timeout: const Duration(seconds: 5),
        );
      } else {
        final host = target.host;
        if (host == null || host.isEmpty) {
          appLog('No host/address for ${service.name}', level: 'error');
          return;
        }
        appLog('Connecting to ${service.name} at $host:$port');
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 5),
        );
      }

      final messageBytes = utf8.encode(jsonData);
      final length = messageBytes.length;

      final lengthHeader = ByteData(4)..setUint32(0, length, Endian.big);
      socket.add(lengthHeader.buffer.asUint8List());
      socket.add(messageBytes);

      await socket.flush();
      await socket.close();
      appLog('Sync sent successfully to ${service.name}');
    } catch (e) {
      appLog('Failed to send sync to ${service.name}: $e', level: 'error');
    }
  }
}
