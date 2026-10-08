import 'package:flutter/services.dart';

import '../../log_manager.dart';

/// Native posting works without a visible Flutter page (Android headless sync).
/// Each platform owns durable notification taps and opens the final local path.
class TransferNotifications {
  static const channel = MethodChannel(
    'com.clipyclone.clipy_android/transfer_notifications',
  );

  static Future<void> initialize() async {
    try {
      await channel.invokeMethod<void>('initialize');
    } catch (e) {
      appLog('Transfer notification initialization unavailable: $e');
    }
  }

  static Future<void> received({
    required String path,
    required String name,
    required String sender,
    void Function(String)? logFailure,
  }) async {
    try {
      await channel.invokeMethod<void>('received', {
        'path': path,
        'name': name,
        'sender': sender,
      });
    } catch (e) {
      final message = 'Transfer notification unavailable: $e';
      if (logFailure != null) {
        logFailure(message);
      } else {
        appLog(message, level: 'warning');
      }
    }
  }
}
