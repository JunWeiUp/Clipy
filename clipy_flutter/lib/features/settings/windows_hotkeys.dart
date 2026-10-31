import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The native runner owns registration; preferences remember successful changes.
class WindowsHotkeys {
  static const channel = MethodChannel('com.clipyclone.clipy_android/tray');
  static Future<void>? _restoring;
  static Future<void> initialize() => _restoring ??= _restore();

  static Future<Map<String, Object?>> _readNative() async =>
      await channel.invokeMapMethod<String, Object?>('getHotkeys') ?? {};

  static (int, int)? _parse(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final modifiers = int.tryParse(parts[0]);
    final key = int.tryParse(parts[1]);
    if (modifiers == null ||
        key == null ||
        modifiers < 1 ||
        modifiers > 15 ||
        !((key >= 48 && key <= 57) ||
            (key >= 65 && key <= 90) ||
            (key >= 112 && key <= 123)) ||
        (modifiers & 8 != 0 && key == 86)) {
      return null;
    }
    return (modifiers, key);
  }

  static Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final native = await _readNative();
      final history = _parse(prefs.getString('windows.hotkey.history'));
      final screenshot = _parse(prefs.getString('windows.hotkey.screenshot'));
      if (history == null && screenshot == null) return;
      final hm = history?.$1 ?? native['historyModifiers'];
      final hk = history?.$2 ?? native['historyKey'];
      final sm = screenshot?.$1 ?? native['screenshotModifiers'];
      final sk = screenshot?.$2 ?? native['screenshotKey'];
      if (hm is int &&
          hk is int &&
          sm is int &&
          sk is int &&
          (hm != sm || hk != sk)) {
        await channel.invokeMethod<void>('restoreHotkeys', {
          'historyModifiers': hm,
          'historyKey': hk,
          'screenshotModifiers': sm,
          'screenshotKey': sk,
        });
      }
    } catch (_) {
      // Preserve saved values and keep the native defaults when restoration fails.
    }
  }

  /// Display text such as `Ctrl + Shift + A`, or null when not configured.
  static String? label(Map<String, Object?> status, String kind) {
    final m = status['${kind}Modifiers'];
    final k = status['${kind}Key'];
    if (m is! int || k is! int) return null;
    return [
      if (m & 2 != 0) 'Ctrl',
      if (m & 1 != 0) 'Alt',
      if (m & 4 != 0) 'Shift',
      if (m & 8 != 0) 'Win',
      if (k >= 112 && k <= 123) 'F${k - 111}' else String.fromCharCode(k),
    ].join(' + ');
  }

  static Future<Map<String, Object?>> read() async {
    await initialize();
    return _readNative();
  }

  static Future<bool> save(String kind, int modifiers, int key) async {
    await initialize();
    final old = await _readNative();
    final previousModifiers = old['${kind}Modifiers'];
    final previousKey = old['${kind}Key'];
    final registered =
        await channel.invokeMethod<bool>('setHotkey', {
          'kind': kind,
          'modifiers': modifiers,
          'key': key,
        }) ??
        false;
    if (!registered) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('windows.hotkey.$kind', '$modifiers:$key')) {
        throw StateError('Could not save shortcut');
      }
      return true;
    } catch (_) {
      if (previousModifiers is int && previousKey is int) {
        await channel.invokeMethod<bool>('setHotkey', {
          'kind': kind,
          'modifiers': previousModifiers,
          'key': previousKey,
        });
      }
      rethrow;
    }
  }
}
