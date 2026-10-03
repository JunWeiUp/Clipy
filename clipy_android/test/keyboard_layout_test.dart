import 'package:clipy_android/models.dart';
import 'package:clipy_android/ui/active_page_stack.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keyboard resizing lays out only the selected page', (
    tester,
  ) async {
    final layouts = [0, 0, 0, 0];
    final children = [
      for (var i = 0; i < layouts.length; i++)
        LayoutBuilder(
          builder: (_, _) {
            layouts[i]++;
            return Text('Page $i', textDirection: TextDirection.ltr);
          },
        ),
    ];
    Future<void> mount(int index, double height) => tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 320,
          height: height,
          child: ActivePageStack(index: index, children: children),
        ),
      ),
    );

    await mount(0, 600);
    expect(layouts, [1, 0, 0, 0]);
    for (var i = 1; i < 4; i++) {
      await mount(i, 600);
    }
    expect(layouts, [1, 1, 1, 1]);
    // Model successive keyboard-animation frames after visiting every tab.
    for (final height in [550.0, 500.0, 450.0, 400.0, 350.0]) {
      await mount(3, height);
    }
    expect(layouts, [1, 1, 1, 6]);
    await mount(0, 350);
    expect(layouts, [2, 1, 1, 6]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tab switching keeps drafts and excludes hidden input focus', (
    tester,
  ) async {
    final first = GlobalKey();
    final second = GlobalKey();
    Future<void> mount(int index) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivePageStack(
            index: index,
            children: [
              TextField(key: first),
              TextField(key: second),
            ],
          ),
        ),
      ),
    );
    await mount(0);
    await tester.enterText(find.byKey(first), 'Keep this draft');
    final state = tester.state(find.byKey(first));
    await mount(1);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.enterText(find.byKey(second), 'Second draft');
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pump();
    tester.view.resetViewInsets();
    await mount(0);
    expect(tester.state(find.byKey(first)), same(state));
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(first),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, 'Keep this draft');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden pages keep scroll position and leave the semantics tree',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final pages = [
        ListView.builder(
          controller: controller,
          itemCount: 100,
          itemExtent: 60,
          itemBuilder: (_, index) => Text('History row $index'),
        ),
        const Center(child: Text('Visible settings')),
      ];
      Future<void> mount(int index) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivePageStack(index: index, children: pages),
          ),
        ),
      );
      await mount(0);
      controller.jumpTo(600);
      await tester.pump();
      await mount(1);
      String semanticsTree() => tester
          .binding
          .renderViews
          .first
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!
          .toStringDeep();
      expect(semanticsTree(), contains('Visible settings'));
      expect(semanticsTree(), isNot(contains('History row')));
      final stack = tester.renderObject<RenderIndexedStack>(
        find.byType(ActivePageStack),
      );
      final visibleChildren = <RenderObject>[];
      stack.visitChildrenForSemantics(visibleChildren.add);
      expect(visibleChildren, hasLength(1));
      expect(visibleChildren.single, same(stack.lastChild));
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pump();
      expect(controller.offset, 600);
      await mount(0);
      expect(controller.offset, 600);
      visibleChildren.clear();
      stack.visitChildrenForSemantics(visibleChildren.add);
      expect(visibleChildren.single, same(stack.firstChild));
      expect(semanticsTree(), isNot(contains('Visible settings')));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'history summaries bound long text and preserve the original content',
    () {
      final content = 'Article\n${List.filled(100000, 'abcdef').join()}';
      final item = HistoryItem(type: 'text', value: content);
      expect(item.title.length, lessThanOrEqualTo(601));
      expect(item.title, startsWith('Article '));
      expect(item.title, endsWith('…'));
      expect(item.value, same(content));
      expect(item.toJson()['text'], content);
      expect(
        HistoryItem(type: 'text', value: '  hello\nworld  ').title,
        'hello world',
      );
      final emoji = HistoryItem(
        type: 'text',
        value: '${List.filled(599, 'a').join()}😀tail',
      );
      expect(emoji.title, '${List.filled(599, 'a').join()}…');
    },
  );
}
