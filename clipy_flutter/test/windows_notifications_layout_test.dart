import 'dart:async';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/remote_notifications_page.dart';
import 'package:clipy_flutter/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipy_flutter/features/history/windows_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'code copy is independent, selection marks read, preferences persist',
    (tester) async {
      SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
      await AppLanguageController.instance.init();
      final all = [
        NotificationEntry(
          id: 'sms',
          packageName: 'sms',
          appName: 'Messages',
          title: 'Code message',
          body: 'Your verification code is 482915.',
          postTime: 2,
        ),
        NotificationEntry(
          id: 'chat',
          packageName: 'chat',
          appName: 'Chat',
          title: 'Chat message',
          body: 'Chat content',
          postTime: 1,
        ),
      ];
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteNotificationsPage(
              windowsLayout: true,
              loader:
                  ({required offset, required limit, required query}) async =>
                      all.skip(offset).take(limit).toList(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat message'));
      await tester.pumpAndSettle();
      expect(find.text('Unread 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('code-sms')));
      await tester.pumpAndSettle();
      expect(copied, '482915');
      expect(find.text('Chat content'), findsOneWidget);
      expect(find.text('Unread 1'), findsOneWidget);
      await tester.tap(find.text('Unread 1'));
      await tester.pumpAndSettle();
      expect(find.text('Code message'), findsOneWidget);
      expect(find.text('Chat · Chat content'), findsNothing);
      await tester.tap(find.text('Show Windows notifications'));
      await tester.pumpAndSettle();
      expect(await WindowsNotificationService.enabled(), true);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(const Size(540, 500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows notification selection and search show matching details',
    (tester) async {
      SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
      await AppLanguageController.instance.init();
      final all = [
        NotificationEntry(
          id: 'a',
          packageName: 'example.chat',
          appName: 'Chat',
          title: 'First',
          body: 'First body',
          postTime: 2000,
        ),
        NotificationEntry(
          id: 'b',
          packageName: 'example.mail',
          appName: 'Mail',
          title: 'Second',
          body: 'Second body',
          postTime: 1000,
        ),
      ];
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteNotificationsPage(
              windowsLayout: true,
              loader:
                  ({required offset, required limit, required query}) async =>
                      all
                          .where(
                            (e) => e.title.toLowerCase().contains(
                              query.toLowerCase(),
                            ),
                          )
                          .skip(offset)
                          .take(limit)
                          .toList(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('First body'), findsOneWidget);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(find.text('Second body'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'First');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('First body'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('a search made while loading discards the old page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'appLanguage': 'en'});
    await AppLanguageController.instance.init();
    final oldPage = Completer<List<NotificationEntry>>();
    NotificationEntry entry(String name) => NotificationEntry(
      id: name,
      packageName: 'app',
      appName: 'App',
      title: name,
      body: name,
      postTime: 1,
    );
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteNotificationsPage(
            windowsLayout: true,
            loader: ({required offset, required limit, required query}) =>
                query.isEmpty
                ? oldPage.future
                : Future.value([entry('New result')]),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 300));
    oldPage.complete([entry('Stale result')]);
    await tester.pumpAndSettle();
    expect(find.text('Stale result'), findsNothing);
    expect(find.text('New result'), findsWidgets);
  });
}
