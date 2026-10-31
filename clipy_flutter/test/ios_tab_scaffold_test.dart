import 'package:clipy_flutter/ui/ios_tab_scaffold.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iOS tabs preserve owner-controlled selection and actions', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return IosTabScaffold(
              body: Text('Page $selected'),
              selectedIndex: selected,
              onSelected: (value) => setState(() => selected = value),
              titles: const ['History', 'Devices', 'Notifications', 'Settings'],
              trailing: const Text('Files'),
            );
          },
        ),
      ),
    );
    expect(find.text('Page 0'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.byType(CupertinoNavigationBar), findsOneWidget);
    await tester.tap(find.text('Devices'));
    await tester.pump();
    expect(find.text('Page 1'), findsOneWidget);
  });
}
