import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models.dart';

/// Windows-only presentation adapter. No timer, queue or retained notification
/// content; NotificationManager calls it after durable receipt and ACK.
class WindowsNotificationService {
  static const channel = MethodChannel(
    'com.clipyclone.clipy/windows_notifications',
  );
  static const preferenceKey = 'windowsNotificationBanners';

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(preferenceKey) ?? false;

  static Future<void> setEnabled(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      preferenceKey,
      value,
    )) {
      throw StateError('Notification preference could not be saved');
    }
  }

  /// Native returns whether submission succeeded, not whether OS focus/quiet
  /// settings allowed it to appear. Native handles click => notifications page.
  static Future<bool> show(NotificationEntry entry) async {
    try {
      if (!await enabled()) return false;
      return await channel.invokeMethod<bool>('showRemoteNotification', {
            'id': entry.id,
            'appName': entry.appName,
            'title': entry.title,
            'body': [
              entry.subtitle,
              entry.body,
            ].whereType<String>().where((s) => s.isNotEmpty).join('\n'),
            'sourceDevice': entry.extras['clipyWindowsSourceName'] ?? '',
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Only consider a short numeric token near an explicit OTP cue. A phone
  /// number, amount or ordinary calendar date must not become a copy-code chip.
  static String? verificationCode(NotificationEntry entry) {
    final text = '${entry.title}\n${entry.subtitle ?? ''}\n${entry.body}';
    final cue = RegExp(
      r'验证码|校验码|动态码|verification\s+code|security\s+code|one[- ]time\s+(?:code|password)|\bOTP\b',
      caseSensitive: false,
    );
    for (final match in cue.allMatches(text)) {
      final end = (match.end + 48).clamp(0, text.length);
      final after = text.substring(match.end, end);
      final token = RegExp(r'(?<![\d])\d{4,8}(?![\d])').firstMatch(after);
      if (token != null) return token.group(0);
      final start = (match.start - 20).clamp(0, text.length);
      final before = RegExp(
        r'(?<![\d])\d{4,8}(?![\d])',
      ).allMatches(text.substring(start, match.start));
      if (before.isNotEmpty) return before.last.group(0);
    }
    return null;
  }
}
