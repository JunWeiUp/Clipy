import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fluent's 40×20 track, with a larger focusable pointer/keyboard target.
class WindowsToggle extends StatefulWidget {
  const WindowsToggle({
    super.key,
    required this.value,
    required this.label,
    this.onChanged,
  });
  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;
  @override
  State<WindowsToggle> createState() => _WindowsToggleState();
}

class _WindowsToggleState extends State<WindowsToggle> {
  late final _focusNode = FocusNode(canRequestFocus: widget.onChanged != null);
  @override
  void didUpdateWidget(WindowsToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusNode.canRequestFocus = widget.onChanged != null;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool _focused = false;
  bool _hovered = false;
  void _activate() => widget.onChanged?.call(!widget.value);
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.onChanged != null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 120);
    return Semantics(
      label: widget.label,
      toggled: widget.value,
      enabled: enabled,
      onTap: enabled ? _activate : null,
      child: FocusableActionDetector(
        focusNode: _focusNode,
        enabled: enabled,
        includeFocusSemantics: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? _activate : null,
          child: Container(
            width: 48,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _focused ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
            alignment: Alignment.center,
            child: Opacity(
              opacity: enabled ? 1 : .45,
              child: AnimatedContainer(
                duration: duration,
                width: 40,
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: widget.value
                      ? colors.primary
                      : (_hovered
                            ? colors.onSurface.withValues(alpha: .06)
                            : Colors.transparent),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: widget.value
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
                child: AnimatedAlign(
                  duration: duration,
                  alignment: widget.value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.value
                          ? colors.onPrimary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings stay readable with large text: controls move below the label.
class WindowsSettingRow extends StatelessWidget {
  const WindowsSettingRow({
    super.key,
    required this.title,
    required this.control,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget control;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stack =
                constraints.maxWidth < 520 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: stack
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            label,
                            const SizedBox(height: 10),
                            control,
                          ],
                        )
                      : label,
                ),
                if (!stack) ...[const SizedBox(width: 20), control],
              ],
            );
          },
        ),
      ),
    );
  }
}

class WindowsKeyCaps extends StatelessWidget {
  const WindowsKeyCaps(this.shortcut, {super.key});
  final String shortcut;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: shortcut,
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final keyName in shortcut.split(' + '))
              Container(
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Text(
                  keyName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
