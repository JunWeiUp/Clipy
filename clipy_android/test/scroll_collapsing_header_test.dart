import 'package:clipy_android/ui/scroll_collapsing_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scroll hides intro, top restores it, keyboard alone does not', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    Future<void> mount({bool enabled = true}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScrollCollapsingHeader(
            enabled: enabled,
            header: const SizedBox(height: 100, child: Text('History intro')),
            child: Column(
              children: [
                const Text('Search and filters'),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: 100,
                    itemExtent: 60,
                    itemBuilder: (_, index) => Text('Row $index'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await mount();
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    expect(find.text('History intro'), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('History intro'), findsNothing);
    expect(find.text('Search and filters'), findsOneWidget);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('History intro'), findsOneWidget);
    await mount(enabled: false);
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('History intro'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final delta in [-180.0, 180.0]) {
    testWidgets('short history hides intro for vertical drag $delta', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollCollapsingHeader(
              enabled: true,
              header: const SizedBox(height: 100, child: Text('History intro')),
              child: Column(
                children: [
                  const Text('Search and filters'),
                  Expanded(
                    child: ListView(
                      controller: controller,
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 60, child: Text('Only row')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, 0);
      await tester.drag(find.byType(ListView), Offset(0, delta));
      await tester.pumpAndSettle();
      expect(find.text('History intro'), findsNothing);
      expect(find.text('Search and filters'), findsOneWidget);
      expect(find.text('Only row'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 120);
      await tester.pumpAndSettle();
      expect(find.text('History intro'), findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
