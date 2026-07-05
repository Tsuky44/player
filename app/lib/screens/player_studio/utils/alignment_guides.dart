import 'dart:ui';

/// Distance (px) at which a center-alignment guide line appears.
const double kAlignmentGuideThresholdPx = 10.0;

/// Snap only when centers are within this distance (px) — very precise.
const double kAlignmentSnapThresholdPx = 1.0;

/// A guide line shown when two widget visual centers align.
class StudioAlignmentGuide {
  const StudioAlignmentGuide({
    required this.isVertical,
    required this.positionPx,
  });

  final bool isVertical;
  final double positionPx;
}

/// Detects center-to-center alignment using real rendered widget bounds.
class AlignmentGuideEngine {
  AlignmentGuideEngine._();

  static ({
    List<StudioAlignmentGuide> guides,
    Offset snapDeltaPx,
  }) evaluate({
    required String draggedId,
    required Offset dragDelta,
    required Map<String, Rect> measuredRects,
    required Size canvas,
    double guideThresholdPx = kAlignmentGuideThresholdPx,
    double snapThresholdPx = kAlignmentSnapThresholdPx,
  }) {
    final draggedRect = measuredRects[draggedId];
    if (draggedRect == null) {
      return (guides: const [], snapDeltaPx: Offset.zero);
    }

    final proposed = draggedRect.shift(dragDelta);
    final draggedCenterX = proposed.center.dx;
    final draggedCenterY = proposed.center.dy;

    final guides = <StudioAlignmentGuide>[];
    var snapDx = 0.0;
    var snapDy = 0.0;

    final xTargets = <double>[canvas.width / 2];
    final yTargets = <double>[canvas.height / 2];

    for (final entry in measuredRects.entries) {
      if (entry.key == draggedId) continue;
      xTargets.add(entry.value.center.dx);
      yTargets.add(entry.value.center.dy);
    }

    final xMatch = _nearest(draggedCenterX, xTargets, guideThresholdPx);
    if (xMatch != null) {
      guides.add(StudioAlignmentGuide(isVertical: true, positionPx: xMatch));
      final dist = (draggedCenterX - xMatch).abs();
      if (dist <= snapThresholdPx) snapDx = xMatch - draggedCenterX;
    }

    final yMatch = _nearest(draggedCenterY, yTargets, guideThresholdPx);
    if (yMatch != null) {
      guides.add(StudioAlignmentGuide(isVertical: false, positionPx: yMatch));
      final dist = (draggedCenterY - yMatch).abs();
      if (dist <= snapThresholdPx) snapDy = yMatch - draggedCenterY;
    }

    return (guides: guides, snapDeltaPx: Offset(snapDx, snapDy));
  }

  static double? _nearest(double value, List<double> targets, double threshold) {
    double? best;
    var bestDist = threshold + 1;
    for (final target in targets) {
      final dist = (value - target).abs();
      if (dist <= threshold && dist < bestDist) {
        bestDist = dist;
        best = target;
      }
    }
    return best;
  }
}
