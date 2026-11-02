import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps native window controls reachable when a route covers the main page.
PreferredSizeWidget platformAppBar(
  BuildContext context, {
  required Widget title,
  List<Widget> actions = const [],
}) {
  if (Theme.of(context).platform != TargetPlatform.windows) {
    return AppBar(title: title, actions: actions);
  }
  return WindowsTitleBar(
    leading: Navigator.canPop(context) ? const BackButton() : null,
    title: title,
    actions: actions,
  );
}

/// The main Windows window's only caption. Native Win32 retains its sizing
/// frame, move loop, maximize/restore and close-to-tray lifecycle.
class WindowsTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const WindowsTitleBar({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
  });

  final Widget title;
  final Widget? leading;
  final List<Widget> actions;
  static const _channel = MethodChannel('com.clipyclone.clipy_android/tray');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<bool>(method);
    } on PlatformException catch (_) {
      // The runner can reject actions during a window-mode transition.
    } on MissingPluginException catch (_) {
      // Allows this widget to be previewed outside the Windows runner.
    }
  }

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    Widget control(IconData icon, String label, String method) => SizedBox(
      width: 46,
      height: 48,
      child: IconButton(
        tooltip: label,
        iconSize: 17,
        style: IconButton.styleFrom(shape: const RoundedRectangleBorder()),
        onPressed: () => _invoke(method),
        icon: Icon(icon),
      ),
    );
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            if (leading != null) SizedBox(width: 48, child: leading),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                supportedDevices: const {PointerDeviceKind.mouse},
                onPanStart: (_) => _invoke('beginWindowDrag'),
                onDoubleTap: () => _invoke('toggleMaximize'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(alignment: Alignment.centerLeft, child: title),
                ),
              ),
            ),
            ...actions,
            control(
              Icons.remove,
              chinese ? '最小化' : 'Minimize',
              'minimizeWindow',
            ),
            control(
              Icons.crop_square,
              chinese ? '最大化 / 还原' : 'Maximize / restore',
              'toggleMaximize',
            ),
            control(
              Icons.close,
              chinese ? '关闭到托盘' : 'Close to tray',
              'closeWindow',
            ),
          ],
        ),
      ),
    );
  }
}
