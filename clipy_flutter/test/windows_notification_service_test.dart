import 'package:clipy_flutter/features/history/windows_notification_service.dart';
import 'package:clipy_flutter/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  NotificationEntry entry(String body) => NotificationEntry(
    id: 'test-id',
    packageName: 'example.sms',
    appName: 'Messages',
    title: 'Bank',
    body: body,
    postTime: 1,
    extras: {'clipyWindowsSourceName': 'Test phone'},
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsNotificationService.channel, null),
  );

  test('OTP extraction requires an explicit cue and copies only the token', () {
    expect(
      WindowsNotificationService.verificationCode(
        entry('验证码为 482915，5 分钟内有效。'),
      ),
      '482915',
    );
    expect(
      WindowsNotificationService.verificationCode(
        entry('Your verification code is 001234.'),
      ),
      '001234',
    );
    expect(
      WindowsNotificationService.verificationCode(
        entry('482915 is your security code.'),
      ),
      '482915',
    );
    expect(
      WindowsNotificationService.verificationCode(
        entry('Meeting 2026/10/30 at 15:00'),
      ),
      isNull,
    );
    expect(
      WindowsNotificationService.verificationCode(entry('Call 13800138000')),
      isNull,
    );
    expect(
      WindowsNotificationService.verificationCode(
        entry('验证码无法接收？拨打13800138000'),
      ),
      isNull,
    );
  });

  test(
    'banners are opt-in and channel receives the independent contract',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WindowsNotificationService.channel, (
            call,
          ) async {
            calls.add(call);
            return true;
          });
      expect(await WindowsNotificationService.show(entry('Hello')), false);
      expect(calls, isEmpty);
      await WindowsNotificationService.setEnabled(true);
      expect(await WindowsNotificationService.enabled(), true);
      expect(await WindowsNotificationService.show(entry('Hello')), true);
      expect(calls.single.method, 'showRemoteNotification');
      expect(calls.single.arguments, {
        'id': 'test-id',
        'appName': 'Messages',
        'title': 'Bank',
        'body': 'Hello',
        'sourceDevice': 'Test phone',
      });
      await WindowsNotificationService.setEnabled(false);
      expect(await WindowsNotificationService.show(entry('Another')), false);
      expect(calls.length, 1);
    },
  );

  test(
    'native failure never escapes the best-effort presentation boundary',
    () async {
      await WindowsNotificationService.setEnabled(true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WindowsNotificationService.channel, (
            _,
          ) async {
            throw PlatformException(code: 'not_available');
          });
      expect(await WindowsNotificationService.show(entry('Hello')), false);
    },
  );
}
