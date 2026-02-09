import 'package:flutter/widgets.dart';
import 'sync_manager.dart';

@pragma('vm:entry-point')
Future<void> syncBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SyncManager.instance.init();
}
