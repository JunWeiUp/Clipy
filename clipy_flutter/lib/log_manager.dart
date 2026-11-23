import 'dart:async';
import 'package:flutter/foundation.dart';
import 'database/app_log_repository.dart';

class LogManager extends ChangeNotifier {
  static final LogManager instance = LogManager._();
  LogManager._();

  Timer? _notifyDebounce;

  Future<List<AppLogRecord>> fetchPage({
    required int offset,
    required int limit,
  }) {
    return AppLogRepository.instance.fetchPage(offset: offset, limit: limit);
  }

  Future<int> count() => AppLogRepository.instance.count();

  /// [console] mirrors the line to logcat/stdout in release builds too, for
  /// adb-only field diagnostics (session lifecycle). Keep it low-volume.
  void log(String message, {String level = 'info', bool console = false}) {
    final timestamp = DateTime.now().toString().split('.')[0];
    final logMessage = '[$timestamp] [${level.toUpperCase()}] $message';
    if (kDebugMode || console) {
      debugPrint('Clipy $logMessage');
    }
    unawaited(AppLogRepository.instance.insert(level: level, message: message));
    _scheduleNotify();
  }

  void _scheduleNotify() {
    _notifyDebounce?.cancel();
    _notifyDebounce = Timer(const Duration(milliseconds: 100), () {
      notifyListeners();
    });
  }

  Future<void> clear() async {
    await AppLogRepository.instance.clearAll();
    notifyListeners();
  }
}

void appLog(String message, {String level = 'info', bool console = false}) {
  LogManager.instance.log(message, level: level, console: console);
}
