import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold;

/// iOS navigation chrome. The owner retains tab state and page lifetimes.
class IosTabScaffold extends StatelessWidget {
  const IosTabScaffold({
    super.key,
    required this.body,
    required this.selectedIndex,
    required this.onSelected,
    required this.titles,
    this.trailing,
  }) : assert(titles.length == 4);

  final Widget body;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<String> titles;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/branding/clipy-logo.png',
                width: 26,
                height: 26,
                excludeFromSemantics: true,
              ),
              const SizedBox(width: 8),
              const Text('Clipy'),
            ],
          ),
          trailing: trailing,
        ),
        backgroundColor: CupertinoDynamicColor.resolve(
          CupertinoColors.systemGroupedBackground,
          context,
        ),
        child: SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              Expanded(child: body),
              CupertinoTabBar(
                currentIndex: selectedIndex,
                onTap: onSelected,
                items: [
                  BottomNavigationBarItem(
                    icon: const Icon(CupertinoIcons.doc_on_clipboard),
                    label: titles[0],
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(CupertinoIcons.desktopcomputer),
                    label: titles[1],
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(CupertinoIcons.bell),
                    label: titles[2],
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(CupertinoIcons.slider_horizontal_3),
                    label: titles[3],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
