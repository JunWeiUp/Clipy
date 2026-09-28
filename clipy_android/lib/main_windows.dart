// Keep desktop SQLite initialization out of the Android/iOS entrypoint.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/bootstrap.dart';

/// Windows uses the shared Dart app with a desktop SQLite factory. Keep this
/// target separate from Android/iOS so their native builds do not package the
/// FFI SQLite library or run its native-assets download hook.
Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await bootstrapApplication();
}
