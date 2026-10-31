import 'dart:io';
import 'dart:ui' as ui;

import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/device_widgets.dart';
import 'package:clipy_flutter/features/history/history_feed_controller.dart';
import 'package:clipy_flutter/features/history/remote_notifications_page.dart';
import 'package:clipy_flutter/features/history/windows_capture_result.dart';
import 'package:clipy_flutter/features/history/windows_quick_panel.dart';
import 'package:clipy_flutter/features/settings/windows_settings_page.dart';
import 'package:clipy_flutter/models.dart';
import 'package:clipy_flutter/sync_manager.dart';
import 'package:clipy_flutter/ui/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['CLIPY_VISUAL_FONT'] case final String path) {
      final data = ByteData.sublistView(await File(path).readAsBytes());
      for (final family in [
        'Ahem',
        'Roboto',
        '.SF Pro Text',
        '.SF Pro Display',
        'Segoe UI',
      ]) {
        await (FontLoader(family)..addFont(Future.value(data))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final kind in [
      'settings',
      'devices',
      'notifications',
      'quick-panel',
      'capture-result',
    ]) {
      testWidgets('Windows $kind ${brightness.name} offline visual fixture', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
        await AppLanguageController.instance.init();
        const tray = MethodChannel('com.clipyclone.clipy_android/tray');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(tray, (call) async {
              switch (call.method) {
                case 'getWindowsBehavior':
                  return {
                    'startup': false,
                    'closeExits': false,
                    'trayOpensMain': false,
                  };
                case 'getFirewallStatus':
                  return 1;
                case 'getHotkeys':
                  return {
                    'history': true,
                    'screenshot': true,
                    'historyModifiers': 6,
                    'historyKey': 86,
                    'screenshotModifiers': 6,
                    'screenshotKey': 65,
                  };
                default:
                  return null;
              }
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(tray, null),
        );
        final manager = SyncManager.instance;
        final oldClipboard = manager.clipboardSyncPeerIds;
        final oldNotifications = manager.notificationSyncPeerIds;
        final oldEnabled = manager.isEnabled;
        manager.isEnabled = false;
        manager.clipboardSyncPeerIds = ['offline-device'];
        manager.notificationSyncPeerIds = [];
        addTearDown(() {
          manager.clipboardSyncPeerIds = oldClipboard;
          manager.notificationSyncPeerIds = oldNotifications;
          manager.isEnabled = oldEnabled;
        });
        final entries = [
          HistoryEntry(
            item: HistoryItem(
              type: 'text',
              value: 'Fictional meeting notes for the design review.',
            ),
            date: DateTime(2026, 1, 2, 15, 41),
            contentHash: 'text',
          ),
          HistoryEntry(
            item: HistoryItem(type: 'text', value: 'https://example.com/clipy'),
            date: DateTime(2026, 1, 2, 15, 36),
            contentHash: 'link',
          ),
        ];
        final feed = HistoryFeedController(
          ({
            required offset,
            required limit,
            required query,
            required filter,
          }) async => offset > 0
              ? []
              : entries
                    .where(
                      (e) => e.item.value.toString().toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    )
                    .toList(),
        );
        addTearDown(feed.dispose);
        final notes = [
          NotificationEntry(
            id: '1',
            packageName: 'example.chat',
            appName: 'Chat',
            title: 'Design review',
            body: 'The fictional review starts at 3 PM.',
            postTime: 2000,
          ),
          NotificationEntry(
            id: '2',
            packageName: 'example.mail',
            appName: 'Mail',
            title: 'Project update',
            body: 'A sample message for this preview.',
            postTime: 1000,
          ),
        ];
        File? preview;
        if (kind == 'capture-result') {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 600, 360),
            Paint()..color = const Color(0xffdceafb),
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(35, 35, 530, 290),
              const Radius.circular(20),
            ),
            Paint()..color = const Color(0xff245fc4),
          );
          preview = File(
            '${Directory.systemTemp.path}/clipy-windows-visual-fixture.png',
          );
          final picture = recorder.endRecording();
          final image = await tester.runAsync(() => picture.toImage(600, 360));
          final key = FileImage(preview);
          PaintingBinding.instance.imageCache.putIfAbsent(
            key,
            () => OneFrameImageStreamCompleter(
              SynchronousFuture(ImageInfo(image: image!)),
            ),
          );
          addTearDown(() {
            PaintingBinding.instance.imageCache.evict(key);
            picture.dispose();
          });
        }
        final size = switch (kind) {
          'quick-panel' => const Size(400, 640),
          'capture-result' => const Size(360, 320),
          _ => const Size(1100, 700),
        };
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final Widget page = switch (kind) {
          'settings' => WindowsSettingsPage(
            onOpenLogs: () {},
            onOpenReceivedFiles: () {},
          ),
          'devices' => const _OfflineDevicesFixture(),
          'notifications' => RemoteNotificationsPage(
            windowsLayout: true,
            loader: ({required offset, required limit, required query}) async =>
                notes
                    .where(
                      (n) =>
                          n.title.toLowerCase().contains(query.toLowerCase()),
                    )
                    .skip(offset)
                    .take(limit)
                    .toList(),
          ),
          'quick-panel' => WindowsQuickPanel(
            controller: feed,
            copy: (_) async {},
            paste: () async => true,
            setPinned: (_) async {},
            onOpenFull: () {},
            onCapture: (_, _) {},
            onNavigate: (_) {},
            deviceCount: 2,
            screenshotShortcut: 'Ctrl + Shift + A',
          ),
          _ => WindowsCaptureResult(
            path: preview!.path,
            copied: true,
            onClose: () {},
            onSave: () {},
            onReveal: () {},
            onSend: () {},
          ),
        };
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ClipyTheme.windows(brightness),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(body: page),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (Platform.environment['CLIPY_VISUAL_DIR']
            case final String directory) {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final img = await boundary.toImage(pixelRatio: 1);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            await Directory(directory).create(recursive: true);
            await File(
              '$directory/windows-$kind-${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

/// Test-only shell around the real device list; never enumerates local interfaces.
class _OfflineDevicesFixture extends StatelessWidget {
  const _OfflineDevicesFixture();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        const Card(
          child: ListTile(
            leading: Icon(Icons.computer),
            title: Text('Fictional Windows PC'),
            subtitle: Text('Local network'),
            trailing: Switch(value: false, onChanged: null),
          ),
        ),
        const SizedBox(height: 16),
        const Expanded(child: SyncTargetDeviceList()),
      ],
    ),
  );
}
