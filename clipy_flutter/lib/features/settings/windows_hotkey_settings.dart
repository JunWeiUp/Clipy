import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_localizations.dart';
import 'windows_hotkeys.dart';
import '../../ui/windows_controls.dart';

class WindowsHotkeySettings extends StatefulWidget {
  const WindowsHotkeySettings({super.key});
  @override
  State<WindowsHotkeySettings> createState() => _WindowsHotkeySettingsState();
}

class _WindowsHotkeySettingsState extends State<WindowsHotkeySettings> {
  final _focus = FocusNode();
  Map<String, Object?> _status = {};
  String? _recording;
  String? _message;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await WindowsHotkeys.read();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _message = context.l10n.operationFailed);
    }
  }

  String _label(String kind) {
    final m = _status['${kind}Modifiers'];
    final k = _status['${kind}Key'];
    if (m is! int || k is! int) return '—';
    return [
      if (m & 2 != 0) 'Ctrl',
      if (m & 1 != 0) 'Alt',
      if (m & 4 != 0) 'Shift',
      if (m & 8 != 0) 'Win',
      if (k >= 112 && k <= 123) 'F${k - 111}' else String.fromCharCode(k),
    ].join(' + ');
  }

  Future<void> _record(KeyEvent event) async {
    if (event is! KeyDownEvent || _recording == null || _saving) return;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _recording = null;
        _message = null;
      });
      return;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifiers =
        (keyboard.isAltPressed ? 1 : 0) |
        (keyboard.isControlPressed ? 2 : 0) |
        (keyboard.isShiftPressed ? 4 : 0) |
        (keyboard.isMetaPressed ? 8 : 0);
    final label = event.logicalKey.keyLabel.toUpperCase();
    int? key;
    if (RegExp(r'^[A-Z0-9]$').hasMatch(label)) key = label.codeUnitAt(0);
    if (RegExp(r'^F([1-9]|1[0-2])$').hasMatch(label)) {
      key = 111 + int.parse(label.substring(1));
    }
    if (key == null) return;
    if (modifiers == 0 || (modifiers & 8 != 0 && key == 86)) {
      setState(() => _message = context.l10n.invalidShortcut);
      return;
    }
    final kind = _recording!;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final saved = await WindowsHotkeys.save(kind, modifiers, key);
      if (!mounted) return;
      setState(() {
        _message = saved ? null : context.l10n.shortcutConflict;
        _recording = null;
      });
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = context.l10n.operationFailed;
          _recording = null;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return KeyboardListener(
      focusNode: _focus,
      onKeyEvent: _record,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final kind in ['history', 'screenshot'])
            WindowsSettingRow(
              icon: kind == 'history' ? Icons.keyboard : Icons.crop_free,
              title: kind == 'history' ? l10n.history : l10n.screenshot,
              subtitle: _recording == kind
                  ? l10n.pressShortcut
                  : _status[kind] == true
                  ? l10n.shortcutActive
                  : l10n.shortcutUnavailable,
              control: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: WindowsKeyCaps(_label(kind))),
                  IconButton(
                    tooltip: l10n.editShortcut,
                    onPressed: _saving
                        ? null
                        : () {
                            setState(() {
                              _recording = kind;
                              _message = null;
                            });
                            _focus.requestFocus();
                          },
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                ],
              ),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
