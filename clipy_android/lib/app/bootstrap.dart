import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_android/clipboard_manager.dart';
import 'package:clipy_android/sync_manager.dart';
import 'package:clipy_android/notification_manager.dart';
import 'package:clipy_android/notification_health_monitor.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/database/app_database.dart';
import 'package:clipy_android/app/app.dart';
import 'package:clipy_android/ui/app_theme.dart';

/// Whether core managers finished bootstrap in this isolate.
bool _coreBootstrapped = false;

/// Completes when SyncManager.init (and friends) finish — FGS may call
/// ensureSyncStarted while bootstrap is still in flight.
Completer<void> _coreBootstrapComplete = Completer<void>();

Future<void> _bootstrapCore() async {
  if (_coreBootstrapped) {
    await _coreBootstrapComplete.future;
    return;
  }
  _coreBootstrapped = true;

  try {
    await AppDatabase.instance.database;
  } catch (e) {
    debugPrint('AppDatabase init error: $e');
  }

  try {
    await ClipboardManager.instance.init();
  } catch (e) {
    debugPrint('ClipboardManager init error: $e');
  }

  try {
    await SyncManager.instance.init();
  } catch (e) {
    debugPrint('SyncManager init error: $e');
  }

  try {
    await NotificationManager.instance.init();
  } catch (e) {
    debugPrint('NotificationManager init error: $e');
  }

  try {
    await NotificationHealthMonitor.instance.startIfNeeded();
  } catch (e) {
    debugPrint('NotificationHealthMonitor init error: $e');
  }

  if (!_coreBootstrapComplete.isCompleted) {
    _coreBootstrapComplete.complete();
  }
}

/// Single entrypoint for the Application-warmed engine (FGS / boot autostart)
/// and for Activity-created engines (sync off).
///
/// A custom entrypoint name is NOT usable here: engines started with a
/// non-default entrypoint never register first-party fonts, and every icon
/// renders as a notdef box (verified with an offscreen raster probe). So this
/// default `main` serves both modes. It mounts a trivial root immediately —
/// runApp must not be deferred — and the full UI ([MyApp]) is only mounted by
/// [_attachUi] when the user actually opens the app, keeping a background-only
/// process free of the widget tree (MaterialApp + IndexedStack tabs + history
/// pages ≈ several MB).
Future<void> bootstrapApplication() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerSyncControlChannel();
  runApp(const SizedBox.shrink());
  await _bootstrapCore();
}

bool _uiAttached = false;

/// Start (or resume) the widget tree. Idempotent so repeated `ui.attach`
/// nudges (Activity recreation, native retries) are harmless.
Future<void> _attachUi() async {
  if (_uiAttached) return;
  _uiAttached = true;

  try {
    await AppLanguageController.instance.init();
    await AppAppearance.instance.init();
  } catch (e) {
    debugPrint('AppLanguageController init error: $e');
  }

  runApp(const MyApp());

  // One-time: sync is enabled but notifications can't surface. Android 13+
  // denies POST_NOTIFICATIONS by default, which hides even the FGS persistent
  // notification — the user then can't tell autostart from a dead service.
  unawaited(_maybeRequestNotificationPermissionOnce());
}

/// Native nudges (FGS sticky rebuild, watchdog, Activity ui.attach) can
/// arrive before bootstrap finishes; registering the handler first lets each
/// handler await completion.
void _registerSyncControlChannel() {
  const MethodChannel(
    'com.clipyclone.clipy_android/sync_control',
  ).setMethodCallHandler((call) async {
    if (call.method == 'ensureSyncStarted') {
      try {
        await _coreBootstrapComplete.future;
        await SyncManager.instance.ensureStartedIfEnabled();
      } catch (e) {
        debugPrint('ensureSyncStarted error: $e');
      }
      return true;
    }
    if (call.method == 'syncTick') {
      // Return next delay ms for FGS adaptive scheduling (busy 30s / idle 90s).
      // Bounded by a hard timeout so a stalled bootstrap or a hung onSyncTick
      // can never wedge the FGS tick chain — we return busyMs and the Kotlin
      // watchdog (SYNC_TICK_WATCHDOG_MS) is the outer backstop regardless.
      const busyMs = 30000;
      try {
        await _coreBootstrapComplete.future.timeout(
          const Duration(seconds: 10),
        );
        final nextMs = await SyncManager.instance.onSyncTick().timeout(
          const Duration(seconds: 20),
        );
        await NotificationManager.instance.drainNativePendingPosts().timeout(
          const Duration(seconds: 10),
        );
        return nextMs;
      } catch (e) {
        debugPrint('syncTick error: $e');
        return busyMs;
      }
    }
    if (call.method == 'drainNotificationInbox') {
      try {
        await _coreBootstrapComplete.future;
        await NotificationManager.instance.drainNativePendingPosts();
      } catch (e) {
        debugPrint('drainNotificationInbox error: $e');
      }
      return true;
    }
    if (call.method == 'ui.attach') {
      // Activity attached to the headless engine — start the UI. Bound wait
      // so a stalled bootstrap still shows the app after 10s.
      try {
        await _coreBootstrapComplete.future.timeout(
          const Duration(seconds: 10),
        );
      } catch (_) {}
      await _attachUi();
      return true;
    }
    return null;
  });
}

Future<void> _maybeRequestNotificationPermissionOnce() async {
  if (!Platform.isAndroid) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('syncEnabled') != true) return;
    if (prefs.getBool('clipy.notifPermAutoRequested') == true) return;
    // MainActivity registers its method-channel handlers during engine
    // attach; give the first frame a moment.
    await Future<void>.delayed(const Duration(seconds: 2));
    final enabled = await NotificationManager.instance
        .areNotificationsEnabled();
    if (enabled) return;
    // Only stamp after a successful check so a failed probe retries next
    // launch.
    await prefs.setBool('clipy.notifPermAutoRequested', true);
    await NotificationManager.instance.requestNotificationPermission();
  } catch (e) {
    debugPrint('notification permission auto-request error: $e');
  }
}
