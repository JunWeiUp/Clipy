import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps tab elements alive, but lays out only the visible page. Intended for
/// bounded, full-size page bodies; keyboard insets must not resize hidden tabs.
class ActivePageStack extends MultiChildRenderObjectWidget {
  ActivePageStack({
    super.key,
    required this.index,
    required List<Widget> children,
  }) : assert(index >= 0 && index < children.length),
       super(
         children: [
           for (var i = 0; i < children.length; i++)
             ExcludeFocus(
               excluding: i != index,
               child: TickerMode(enabled: i == index, child: children[i]),
             ),
         ],
       );

  final int index;

  @override
  RenderIndexedStack createRenderObject(BuildContext context) =>
      _RenderActivePageStack(index: index);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderIndexedStack renderObject,
  ) {
    renderObject.index = index;
  }
}

class _RenderActivePageStack extends RenderIndexedStack {
  _RenderActivePageStack({required int index})
    : super(index: index, fit: StackFit.expand, alignment: Alignment.topLeft);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    assert(constraints.hasBoundedWidth && constraints.hasBoundedHeight);
    return constraints.biggest;
  }

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
    var child = firstChild;
    for (var i = 0; i < (index ?? 0) && child != null; i++) {
      child = childAfter(child);
    }
    if (child != null) {
      child.layout(BoxConstraints.tight(size), parentUsesSize: true);
      (child.parentData! as StackParentData).offset = Offset.zero;
    }
  }
}
