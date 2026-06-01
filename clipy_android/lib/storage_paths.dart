import 'dart:io';
import 'package:flutter/services.dart';

class StoragePaths {
  static const _channel = MethodChannel('com.clipyclone.clipy_android/storage');

  static Future<Directory> appStorageDirectory() async {
    if (Platform.isAndroid) {
      final path = await _channel.invokeMethod<String>('getAppStorageDirectory');
      if (path != null && path.isNotEmpty) {
        final dir = Directory(path);
        await dir.create(recursive: true);
        return dir;
      }
    }

    final home = Platform.environment['HOME'];
    final dir = Directory(home != null ? '$home/.clipy_android' : '${Directory.systemTemp.path}/clipy_android');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory?> publicDownloadsDirectory() async {
    if (!Platform.isAndroid) return null;

    final path = await _channel.invokeMethod<String>('getDownloadsDirectory');
    if (path == null || path.isEmpty) return null;
    return Directory(path);
  }
}
