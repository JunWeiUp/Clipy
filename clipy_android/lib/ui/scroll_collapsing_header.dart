import 'package:flutter/material.dart';

/// Gives a page's intro space back to the list after scrolling away from top.
/// Search and filters belong to [child] and remain available when it collapses.
class ScrollCollapsingHeader extends StatefulWidget {
  const ScrollCollapsingHeader({
    super.key,
    required this.enabled,
    required this.header,
    required this.child,
  });

  final bool enabled;
  final Widget header;
  final Widget child;

  @override
  State<ScrollCollapsingHeader> createState() => _ScrollCollapsingHeaderState();
}

class _ScrollCollapsingHeaderState extends State<ScrollCollapsingHeader> {
  bool _collapsed = false;

  @override
  void didUpdateWidget(ScrollCollapsingHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _collapsed = false;
  }

  bool _onScroll(ScrollNotification notification) {
    if (!widget.enabled ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    // Ignore viewport changes (including keyboard resizing). Only scrolling
    // and its settling at the top may change header visibility.
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final offset = notification.metrics.pixels;
    final collapsed = offset > 48 ? true : (offset <= 0 ? false : _collapsed);
    if (_collapsed != collapsed) setState(() => _collapsed = collapsed);
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              alignment: Alignment.topCenter,
              child: widget.enabled && _collapsed
                  ? const SizedBox(width: double.infinity)
                  : widget.header,
            ),
            Expanded(child: widget.child),
          ],
        ),
      );
}
