import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// How far the screen's cutouts — a camera bubble, a notch — reach in from each
/// edge.
///
/// [SafeArea] answers a wider question than the player is asking. It counts the
/// status and navigation bars too, which a full-screen player has already
/// hidden, and it can only pad a whole subtree — so the scrims move with the
/// buttons and leave an unpainted band along the edge. What the chrome needs is
/// narrower and exact: the room the camera actually takes, on the edge it
/// actually sits on, so a button can be nudged just past it and everything else
/// left where it was.
///
/// Android reports each cutout's rectangle as a [DisplayFeature]; this turns
/// them into the inset each edge needs. Where nothing is reported — an older
/// device, another platform — it falls back to the padding the platform gives,
/// which is what [SafeArea] would have used.
abstract final class DisplayCutouts {
  /// Treats a rectangle within this many logical pixels of an edge as touching
  /// it. A hole-punch's bounds usually land exactly on the edge, but a rounded
  /// panel can report a pixel of slack.
  static const double _edgeTolerance = 2;

  /// The cutouts themselves, in the window's coordinates.
  ///
  /// This is what lets a row be moved only if the camera is actually on it —
  /// see [AvoidCutouts]. Where the platform enumerates nothing but still
  /// reports padding, the padding is turned back into bands along the edges it
  /// covers: less precise, but it degrades into the blunt behaviour instead of
  /// into none at all.
  static List<Rect> rects(BuildContext context) {
    final media = MediaQuery.of(context);
    final found = <Rect>[
      for (final feature in media.displayFeatures)
        if (feature.type == DisplayFeatureType.cutout) feature.bounds,
    ];
    if (found.isNotEmpty) return found;
    return _bandsOf(media.padding, media.size);
  }

  static List<Rect> _bandsOf(EdgeInsets padding, Size size) => <Rect>[
        if (padding.left > 0) Rect.fromLTWH(0, 0, padding.left, size.height),
        if (padding.top > 0) Rect.fromLTWH(0, 0, size.width, padding.top),
        if (padding.right > 0)
          Rect.fromLTWH(
            size.width - padding.right,
            0,
            padding.right,
            size.height,
          ),
      ];

  static EdgeInsets of(BuildContext context) {
    final media = MediaQuery.of(context);
    return resolve(
      size: media.size,
      features: media.displayFeatures,
      fallback: media.padding,
    );
  }

  /// The inset per edge, from the cutouts that touch that edge.
  ///
  /// A cutout in the middle of an edge still pushes the whole edge in: the
  /// chrome's rows span the width, and half a title sliding under the camera
  /// is exactly what this exists to prevent.
  static EdgeInsets resolve({
    required Size size,
    required Iterable<DisplayFeature> features,
    required EdgeInsets fallback,
  }) {
    var left = 0.0;
    var top = 0.0;
    var right = 0.0;
    var bottom = 0.0;

    for (final feature in features) {
      if (feature.type != DisplayFeatureType.cutout) continue;
      final bounds = feature.bounds;
      if (bounds.left <= _edgeTolerance) {
        left = math.max(left, bounds.right);
      }
      if (bounds.top <= _edgeTolerance) {
        top = math.max(top, bounds.bottom);
      }
      if (bounds.right >= size.width - _edgeTolerance) {
        right = math.max(right, size.width - bounds.left);
      }
      if (bounds.bottom >= size.height - _edgeTolerance) {
        bottom = math.max(bottom, size.height - bounds.top);
      }
    }

    final measured = EdgeInsets.fromLTRB(left, top, right, bottom);
    return measured == EdgeInsets.zero ? fallback : measured;
  }
}
