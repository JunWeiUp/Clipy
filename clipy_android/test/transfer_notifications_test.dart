import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/features/transfers/transfer_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () =>
        messenger.setMockMethodCallHandler(TransferNotifications.channel, null),
  );

  test(
    'permission denied or missing host never fails a completed transfer',
    () async {
      for (final error in [
        PlatformException(code: 'denied'),
        MissingPluginException(),
      ]) {
        messenger.setMockMethodCallHandler(
          TransferNotifications.channel,
          (_) async => throw error,
        );
        await expectLater(
          TransferNotifications.received(
            path: '/received/report (2).pdf',
            name: 'report (2).pdf',
            sender: 'Test peer',
            logFailure: debugPrint,
          ),
          completes,
        );
      }
    },
  );

  test('notification targets the final deduplicated destination', () async {
    MethodCall? posted;
    messenger.setMockMethodCallHandler(TransferNotifications.channel, (
      call,
    ) async {
      posted = call;
      return null;
    });
    await TransferNotifications.received(
      path: '/received/report (2).pdf',
      name: 'report (2).pdf',
      sender: 'Test peer',
      logFailure: debugPrint,
    );
    expect(posted?.arguments['path'], '/received/report (2).pdf');
    expect(posted?.method, 'received');
  });
}
