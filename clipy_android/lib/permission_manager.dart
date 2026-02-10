import 'dart:async';
import 'package:flutter/services.dart';

class PermissionManager {
  static const MethodChannel _channel = MethodChannel('com.clipyclone.clipy_android/permissions');

  static Future<bool> requestStoragePermission() async {
    try {
      final result = await _channel.invokeMethod('requestStoragePermission');
      return result as bool;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> checkStoragePermission() async {
    try {
      final result = await _channel.invokeMethod('checkStoragePermission');
      return result as bool;
    } catch (e) {
      return false;
    }
  }
}