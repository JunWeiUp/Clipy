import 'package:flutter/foundation.dart';

class LogManager extends ChangeNotifier {
  static final LogManager instance = LogManager._();
  LogManager._();

  final List<String> _logs = [];
  List<String> get logs => List.unmodifiable(_logs);

  void log(String message, {String level = 'info'}) {
    final timestamp = DateTime.now().toString().split('.')[0];
    final logMessage = '[$timestamp] [${level.toUpperCase()}] $message';
    _logs.add(logMessage);
    if (_logs.length > 1000) {
      _logs.removeAt(0);
    }
    debugPrint(logMessage); // Still print to console
    notifyListeners();
  }

  void clear() {
    _logs.clear();
    notifyListeners();
  }
}

// Global helper function for logging
void appLog(String message, {String level = 'info'}) {
  LogManager.instance.log(message, level: level);
}
