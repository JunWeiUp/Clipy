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
  double _shortListDrag = 0;

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
    // Short lists still report drag overscroll with AlwaysScrollable physics.
    // They cannot reach a 48px scroll offset, so measure the user's gesture.
    // Ignore programmatic viewport changes and keep the header collapsed when
    // its animation enlarges the short list's viewport.
    if (notification is ScrollStartNotification) {
      _shortListDrag = 0;
      return false;
    }
    if (notification.metrics.maxScrollExtent <= 48) {
      double? dragDelta;
      if (notification is ScrollUpdateNotification) {
        dragDelta = notification.dragDetails?.primaryDelta;
      } else if (notification is OverscrollNotification) {
        dragDelta = notification.dragDetails?.primaryDelta;
      }
      if (dragDelta != null) {
        _shortListDrag += dragDelta.abs();
        if (!_collapsed && _shortListDrag >= 24) {
          setState(() => _collapsed = true);
        }
      }
      return false;
    }
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
