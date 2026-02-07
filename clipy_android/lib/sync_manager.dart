import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

enum SyncMessageType { historyItem, snippetFolders, ping }

class SyncManager extends ChangeNotifier {
  static final SyncManager instance = SyncManager._();
  SyncManager._();

  final String serviceType = '_clipy-sync._tcp';
  ServerSocket? _server;
  Discovery? _discovery;
  final List<Socket> _connections = [];
  bool _isSyncEnabled = false;
  String _deviceName = 'Android Device';

  bool get isSyncEnabled => _isSyncEnabled;
  String get deviceName => _deviceName;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isSyncEnabled = prefs.getBool('isSyncEnabled') ?? false;
    _deviceName = prefs.getString('syncDeviceName') ?? (Platform.isAndroid ? 'Android' : 'Device');
    
    if (_isSyncEnabled) {
      start();
    }
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
    await _startListening();
    await _startBrowsing();
  }

  void stop() {
    _server?.close();
    if (_discovery != null) {
      stopDiscovery(_discovery!);
    }
    for (var conn in _connections) {
      conn.destroy();
    }
    _connections.clear();
  }

  Future<void> _startListening() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      print('Listening on ${_server!.port}');

      await register(Service(
        name: _deviceName,
        type: serviceType,
        port: _server!.port,
      ));

      _server!.listen((socket) {
        _setupConnection(socket);
      });
    } catch (e) {
      print('Failed to start server: $e');
    }
  }

  Future<void> _startBrowsing() async {
    _discovery = await startDiscovery(serviceType);
    _discovery!.addListener(() {
      for (var service in _discovery!.services) {
        if (service.name != _deviceName) {
          _connectTo(service);
        }
      }
    });
  }

  void _connectTo(Service service) async {
    if (service.host == null || service.port == null) return;
    
    try {
      final socket = await Socket.connect(service.host, service.port!);
      _setupConnection(socket);
    } catch (e) {
      print('Connect error: $e');
    }
  }

  void _setupConnection(Socket socket) {
    _connections.add(socket);
    print('Connected to ${socket.remoteAddress}:${socket.remotePort}');

    // Send Ping
    _sendMessage(socket, {'ping': _deviceName});

    List<int> buffer = [];
    socket.listen((data) {
      buffer.addAll(data);
      _processBuffer(buffer);
    }, onDone: () {
      _connections.remove(socket);
      socket.destroy();
    }, onError: (e) {
      _connections.remove(socket);
      socket.destroy();
    });
  }

  void _processBuffer(List<int> buffer) {
    while (buffer.length >= 4) {
      final lengthData = Uint8List.fromList(buffer.sublist(0, 4));
      final length = ByteData.view(lengthData.buffer).getUint32(0, Endian.big);

      if (buffer.length >= 4 + length) {
        final payload = buffer.sublist(4, 4 + length);
        buffer.removeRange(0, 4 + length);
        _handleIncomingData(payload);
      } else {
        break;
      }
    }
  }

  void _handleIncomingData(List<int> payload) {
    try {
      final json = jsonDecode(utf8.decode(payload));
      if (json['historyItem'] != null) {
        final entry = HistoryEntry.fromJson(json['historyItem']);
        // Trigger callback to ClipboardManager
        onHistorySynced?.call(entry);
      } else if (json['snippetFolders'] != null) {
        final folders = (json['snippetFolders'] as List)
            .map((f) => SnippetFolder.fromJson(f))
            .toList();
        onSnippetsSynced?.call(folders);
      } else if (json['ping'] != null) {
        print('Received ping from ${json['ping']}');
      }
    } catch (e) {
      print('Handle data error: $e');
    }
  }

  void _sendMessage(Socket socket, Map<String, dynamic> message) {
    try {
      final data = utf8.encode(jsonEncode(message));
      final lengthHeader = Uint8List(4);
      ByteData.view(lengthHeader.buffer).setUint32(0, data.length, Endian.big);
      
      socket.add(lengthHeader);
      socket.add(data);
    } catch (e) {
      print('Send message error: $e');
    }
  }

  void broadcastHistory(HistoryEntry entry) {
    if (!_isSyncEnabled) return;
    for (var socket in _connections) {
      _sendMessage(socket, {'historyItem': entry.toJson()});
    }
  }

  void broadcastSnippets(List<SnippetFolder> folders) {
    if (!_isSyncEnabled) return;
    for (var socket in _connections) {
      _sendMessage(socket, {'snippetFolders': folders.map((f) => f.toJson()).toList()});
    }
  }

  void Function(HistoryEntry)? onHistorySynced;
  void Function(List<SnippetFolder>)? onSnippetsSynced;
}
