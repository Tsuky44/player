import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Moves its child aside where a screen cutout falls on it — and only there.
///
/// The blunt way to dodge a camera bubble is [SafeArea]: pad the whole chrome
/// in from that edge. It works, and it moves everything — including the rows
/// the bubble was never near, which is the whole interface shifting to make
/// room for something that was in the way of one button. This moves a row only
/// if the bubble actually lands on it, and only by as much as it takes to clear
/// it.
///
/// **Why it measures instead of being told where it is.** A row's position is
/// settled by the layout it sits in — a column inside a bar pinned to the
/// bottom of the screen — and nothing knows it before that layout has run. So
/// the row is laid out, where it landed is read back on the way to the screen,
/// and if that says the inset should be different, the next frame carries it.
/// One extra frame, once: the rows here are single lines that ellipsize, so
/// their height does not change with their width and the answer does not move
/// again. The chrome fades in over ~200 ms, which is longer than the frame it
/// takes to settle.
class AvoidCutouts extends SingleChildRenderObjectWidget {
  const AvoidCutouts({super.key, required this.cutouts, required super.child});

  /// The cutout rectangles, in the window's coordinates — [DisplayCutouts].
  final List<Rect> cutouts;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderAvoidCutouts(cutouts);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAvoidCutouts renderObject,
  ) {
    renderObject.cutouts = cutouts;
  }
}

class RenderAvoidCutouts extends RenderShiftedBox {
  RenderAvoidCutouts(this._cutouts) : super(null);

  /// A cutout this close to the box's edge counts as reaching it. A hole-punch
  /// lands on the edge exactly; a rounded panel can report a pixel of slack.
  static const double _tolerance = 2;

  List<Rect> _cutouts;

  set cutouts(List<Rect> next) {
    if (listEquals(_cutouts, next)) return;
    _cutouts = next;
    markNeedsLayout();
  }

  /// What the last measurement asked for. The child is laid out inside it.
  EdgeInsets _inset = EdgeInsets.zero;

  bool _remeasureScheduled = false;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.deflate(_inset), parentUsesSize: true);
    // The box keeps the width it was offered whatever the inset — that is what
    // makes the measurement stable: the rectangle we test never moves because
    // of our own answer, so the answer cannot chase itself.
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : child.size.width + _inset.horizontal;
    size = constraints.constrain(
      Size(width, child.size.height + _inset.vertical),
    );
    (child.parentData! as BoxParentData).offset =
        Offset(_inset.left, _inset.top);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _measure();
  }

  /// Reads where this row actually landed and, if the inset it needs has
  /// changed, asks for one more layout.
  void _measure() {
    if (!attached || _remeasureScheduled) return;
    final wanted = _insetFor(localToGlobal(Offset.zero) & size);
    if (wanted == _inset) return;
    _inset = wanted;
    _remeasureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _remeasureScheduled = false;
      if (attached) markNeedsLayout();
    });
  }

  EdgeInsets _insetFor(Rect box) {
    var left = 0.0;
    var top = 0.0;
    var right = 0.0;
    for (final cutout in _cutouts) {
      // Only what lands on this row. A bubble halfway down the left edge is
      // nothing to the bar at the bottom of the screen, and this is where that
      // is decided.
      if (!cutout.overlaps(box)) continue;
      // And only from an edge it reaches. A cutout sitting in the middle of a
      // row cannot be dodged by moving the row sideways — there is nowhere to
      // move it to — so it is left alone rather than shoved somewhere worse.
      if (cutout.left <= box.left + _tolerance) {
        left = math.max(left, cutout.right - box.left);
      }
      if (cutout.right >= box.right - _tolerance) {
        right = math.max(right, box.right - cutout.left);
      }
      if (cutout.top <= box.top + _tolerance) {
        top = math.max(top, cutout.bottom - box.top);
      }
    }
    // A cutout wider than the row itself would leave nothing to lay out.
    final horizontal = left + right;
    if (horizontal >= box.width) return EdgeInsets.zero;
    return EdgeInsets.fromLTRB(left, top, right, 0);
  }
}
