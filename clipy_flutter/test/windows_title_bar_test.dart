import 'package:clipy_flutter/ui/windows_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'pushed Windows routes retain Back, page actions and native controls',
    (tester) async {
      const channel = MethodChannel('com.clipyclone.clipy_android/tray');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      var refreshed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: platformAppBar(context, title: const Text('Main')),
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      appBar: platformAppBar(
                        context,
                        title: const Text('Details'),
                        actions: [
                          IconButton(
                            tooltip: 'Refresh',
                            onPressed: () {
                              refreshed = true;
                            },
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('Open details'),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(BackButton), findsNothing);
      await tester.tap(find.text('Open details'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byTooltip('Refresh'));
      expect(refreshed, isTrue);
      for (final label in ['Minimize', 'Maximize / restore', 'Close to tray']) {
        await tester.tap(find.byTooltip(label));
      }
      expect(calls, ['minimizeWindow', 'toggleMaximize', 'closeWindow']);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Main'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    },
  );

  testWidgets('non-Windows routes keep Material app bars', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: platformAppBar(context, title: const Text('Details')),
          ),
        ),
      ),
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(WindowsTitleBar), findsNothing);
  });
}
