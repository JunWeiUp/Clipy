import 'dart:async';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/remote_notifications_page.dart';
import 'package:clipy_flutter/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
