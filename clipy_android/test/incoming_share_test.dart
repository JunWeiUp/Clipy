import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/features/transfers/incoming_share.dart';
import 'package:clipy_android/features/transfers/shared_files_page.dart';
import 'package:clipy_android/sync_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('clipy/test/incoming-share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, Object?> batch(String id) => {
    'id': id,
    'error': '',
    'files': [
      {'path': '/tmp/$id/report.pdf', 'name': 'report.pdf', 'size': 128},
      {'path': '/tmp/$id/archive.zip', 'name': 'archive.zip', 'size': 256},
    ],
  };
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'cold inbox and repeated resume events present each batch once',
    () async {
      final pending = [batch('one'), batch('two')];
      final completed = <String>[];
      final presented = <String>[];
      final dismiss = Completer<void>();
      final firstPresented = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'next') {
          return pending.isEmpty ? null : pending.first;
        }
        if (call.method == 'complete') {
          completed.add((call.arguments as Map)['id'] as String);
          pending.removeAt(0);
        }
        return null;
      });
      final coordinator = IncomingShareCoordinator(
        channel: channel,
        onError: () => fail('Unexpected channel error'),
        present: (share) async {
          presented.add(share.id);
          if (share.id == 'one') {
            firstPresented.complete();
            await dismiss.future;
          }
        },
      );
      final drain = coordinator.drain();
      await firstPresented.future;
      await coordinator.drain();
      await coordinator.drain();
      expect(presented, ['one']);
      expect(completed, isEmpty);
      dismiss.complete();
      await drain;
      expect(presented, ['one', 'two']);
      expect(completed, ['one', 'two']);
      coordinator.dispose();
    },
  );

  test('disposing while a review is open retains native files', () async {
    final opened = Completer<void>();
    final closed = Completer<void>();
    var completions = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'complete') completions++;
      return call.method == 'next' ? batch('retained') : null;
    });
    final coordinator = IncomingShareCoordinator(
      channel: channel,
      onError: () => fail('Unexpected channel error'),
      present: (_) async {
        opened.complete();
        await closed.future;
      },
    );
    final drain = coordinator.drain();
    await opened.future;
    coordinator.dispose();
    closed.complete();
    await drain;
    expect(completions, 0);
  });

  test(
    'platform errors stop draining without destroying a pending batch',
    () async {
      var errors = 0;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'UNAVAILABLE'),
      );
      final coordinator = IncomingShareCoordinator(
        channel: channel,
        onError: () => errors++,
        present: (_) async => fail('Should not present invalid data'),
      );
      await coordinator.drain();
      expect(errors, 1);
      coordinator.dispose();
    },
  );

  testWidgets(
    'review lists mixed files and requires an explicit device selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
      await AppLanguageController.instance.init();
      SyncManager.instance.isEnabled = false;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: SharedFilesPage(share: IncomingShare.fromMap(batch('mixed'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('archive.zip'), findsOneWidget);
      expect(find.textContaining('No devices yet'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
