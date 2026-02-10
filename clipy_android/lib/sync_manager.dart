import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:nsd/nsd.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'log_manager.dart';
import 'clipboard_manager.dart';

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

class SyncManager {
  static final SyncManager instance = SyncManager._();
  SyncManager._();

  Registration? _registration;
  Discovery? _discovery;
  ServerSocket? _server;
  final List<Service> _discoveredServices = [];
  
  final _devicesChangedController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get onDevicesChanged => _devicesChangedController.stream;
  
  List<String> get availableDeviceNames =>
      _discoveredServices.map((s) => s.name ?? 'Unknown').toList()..sort();

  bool isEnabled = false;
  int port = 5566;
  List<String> authorizedDevices = [];
  
  String _deviceName = '';
  String get deviceId => _deviceName.isEmpty ? 'Android-${const Uuid().v4().substring(0, 8)}' : _deviceName;

  final String _serviceType = '_clipy-sync._tcp';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('syncEnabled') ?? false;
    port = prefs.getInt('syncPort') ?? 5566;
    authorizedDevices = prefs.getStringList('authorizedDevices') ?? [];
    _deviceName = prefs.getString('deviceName') ?? '';
    
    if (isEnabled) {
      start();
    }
  }

  Future<void> updateDeviceName(String name) async {
    _deviceName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceName', name);
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
  }

  // MARK: - mDNS Publishing
  Future<void> startPublishing() async {
    appLog('Publishing mDNS service: $deviceId on port $port');
    try {
      _registration = await register(Service(name: deviceId, type: _serviceType, port: port));
      appLog('mDNS service published successfully');
    } catch (e) {
      appLog('Failed to publish mDNS service: $e', level: 'error');
    }
  }

  // MARK: - mDNS Browsing
  Future<void> startBrowsing() async {
    appLog('Starting mDNS browsing for $_serviceType');
    try {
      _discovery = await startDiscovery(_serviceType);
      _discovery!.addListener(() {
        _discoveredServices.clear();
        _discoveredServices.addAll(_discovery!.services.where((s) => s.name != deviceId));
        _devicesChangedController.add(availableDeviceNames);
        appLog('Discovered devices updated: ${availableDeviceNames.join(', ')}');
      });
    } catch (e) {
      appLog('Failed to start mDNS browsing: $e', level: 'error');
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
        appLog('SUCCESS: Sync TCP server also listening on IPv6: ${v6Server.address.address}:${v6Server.port}');
      } catch (e) {
        appLog('Note: IPv6 bind skipped (already handled or port busy): $e');
      }
      
      // Log all local addresses for debugging
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          appLog('Local Network Interface: ${interface.name} (${addr.type.name}) - ${addr.address}');
        }
      }
      return true;
    } catch (e) {
      appLog('CRITICAL: Failed to start server: $e', level: 'error');
      return false;
    }
  }

  void _handleConnection(Socket socket) {
    appLog('New incoming connection from ${socket.remoteAddress.address}:${socket.remotePort}');
    
    List<int> buffer = [];
    int? expectedLength;

    socket.listen((data) {
      // Optional: Log hex for the first few bytes to debug protocol issues
      final hexData = data.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      appLog('Socket received ${data.length} bytes raw data. Hex(16): $hexData');
      
      buffer.addAll(data);
      
      while (true) {
        // Detect and filter out HTTP requests (GET, POST, etc.)
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
            // Read 4-byte length prefix (big-endian)
            final lengthData = buffer.sublist(0, 4);
            final length = ByteData.sublistView(Uint8List.fromList(lengthData)).getUint32(0, Endian.big);
            
            // Sanity check for length (e.g., max 1MB for clipboard sync)
            if (length > 1024 * 1024) {
              appLog('Invalid packet length: $length (too large). Potential protocol mismatch. Hex: ${lengthData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}', level: 'error');
              socket.destroy();
              return;
            }
            
            expectedLength = length;
            buffer.removeRange(0, 4);
            appLog('Read 4-byte length prefix: $expectedLength. Remaining buffer: ${buffer.length}');
          } else {
            break; // Wait for more data
          }
        }

        if (expectedLength != null) {
          if (buffer.length >= expectedLength!) {
            appLog('Buffer has enough data for message ($expectedLength bytes)');
            final messageData = buffer.sublist(0, expectedLength!);
            buffer.removeRange(0, expectedLength!);
            
            try {
              final jsonString = utf8.decode(messageData);
              final json = jsonDecode(jsonString);
              final message = SyncMessage.fromJson(json);
              appLog('Parsed SyncMessage from ${message.deviceId}, type: ${message.type}');
              _handleSyncMessage(message);
            } catch (e) {
              appLog('Error parsing sync message: $e', level: 'error');
            }
            
            expectedLength = null; // Reset for next message if any
          } else {
            break; // Wait for more data
          }
        }
      }
    }, onDone: () {
      appLog('Socket connection closed by remote');
      socket.destroy();
    }, onError: (e) {
      appLog('Socket error: $e');
      socket.destroy();
    });
  }

  Future<void> _handleSyncMessage(SyncMessage message) async {
    appLog('Checking authorization for device: ${message.deviceId}');
    if (!authorizedDevices.contains(message.deviceId)) {
      appLog('Sync rejected: Unauthorized device ${message.deviceId}. Authorized devices: $authorizedDevices');
      return;
    }

    appLog('Decrypting sync content from ${message.deviceId}...');
    final decrypted = _decrypt(message.content);
    if (decrypted != null) {
      appLog('Sync decrypted successfully, updating clipboard...');
      await ClipboardManager.instance.handleRemoteSync(decrypted, message.hash);
    } else {
      appLog('Sync decryption failed from ${message.deviceId}');
    }
  }

  // MARK: - Encryption
  final String hardcodedSecret = "ClipySyncSecret2026";

  encrypt.Key _getEncryptionKey() {
    final bytes = utf8.encode(hardcodedSecret);
    final hash = sha256.convert(bytes);
    return encrypt.Key(hash.bytes as dynamic);
  }

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

  String? _decrypt(String base64String) {
    try {
      final key = _getEncryptionKey();
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
      appLog('Decryption error: $e');
      return null;
    }
  }

  // MARK: - Sending
  Future<void> broadcastSync(String content, String hash) async {
    if (!isEnabled) return;

    appLog('Broadcasting sync to authorized devices...');
    final encrypted = _encrypt(content);
    if (encrypted == null) return;

    final message = SyncMessage(
      deviceId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'text/plain',
      content: encrypted,
      hash: hash,
    );

    final jsonData = jsonEncode(message.toJson());

    for (var service in _discoveredServices) {
      if (authorizedDevices.contains(service.name)) {
        appLog('Sending sync to ${service.name}...');
        await _sendSync(jsonData, service);
      }
    }
  }

  Future<void> _sendSync(String jsonData, Service service) async {
    try {
      final host = service.host ?? 'localhost';
      final port = service.port ?? 5566;
      appLog('Attempting TCP connection to $host:$port');
      
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      
      final messageBytes = utf8.encode(jsonData);
      final length = messageBytes.length;
      
      // Send 4-byte length prefix (big-endian)
      final lengthHeader = ByteData(4)..setUint32(0, length, Endian.big);
      socket.add(lengthHeader.buffer.asUint8List());
      
      // Send message data
      socket.add(messageBytes);
      
      await socket.flush();
      await socket.close();
      appLog('Sync sent successfully to ${service.name}');
    } catch (e) {
      appLog('Failed to send sync to ${service.name}: $e');
    }
  }
}
