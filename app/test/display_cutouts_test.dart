import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/display_cutouts.dart';

/// A landscape phone, in logical pixels.
const Size screen = Size(914, 411);

DisplayFeature cutout(Rect bounds) => DisplayFeature(
      bounds: bounds,
      type: DisplayFeatureType.cutout,
      state: DisplayFeatureState.unknown,
    );

void main() {
  group('DisplayCutouts', () {
    test('a camera bubble on the left edge pushes that edge in, alone', () {
      // The phone held with the camera on the left: the chrome has to start
      // past the bubble, and only on that side — the buttons on the right have
      // nothing to dodge.
      final insets = DisplayCutouts.resolve(
        size: screen,
        features: [cutout(const Rect.fromLTRB(0, 160, 38, 250))],
        fallback: EdgeInsets.zero,
      );

      expect(insets.left, 38);
      expect(insets.right, 0);
      expect(insets.top, 0);
      expect(insets.bottom, 0);
    });

    test('the same bubble on the right edge pushes the right edge in', () {
      final insets = DisplayCutouts.resolve(
        size: screen,
        features: [cutout(Rect.fromLTRB(screen.width - 38, 160, screen.width, 250))],
        fallback: EdgeInsets.zero,
      );

      expect(insets.right, 38);
      expect(insets.left, 0);
    });

    test('a notch in the middle of the top edge still pushes the whole edge',
        () {
      // The chrome's rows span the width. Half a title sliding under the
      // camera is exactly what this exists to prevent, so the edge moves as
      // one rather than the row being cut around the bubble.
      final insets = DisplayCutouts.resolve(
        size: screen,
        features: [cutout(const Rect.fromLTRB(400, 0, 514, 34))],
        fallback: EdgeInsets.zero,
      );

      expect(insets.top, 34);
      expect(insets.left, 0);
      expect(insets.right, 0);
    });

    test('the deepest cutout on an edge wins', () {
      final insets = DisplayCutouts.resolve(
        size: screen,
        features: [
          cutout(const Rect.fromLTRB(0, 100, 24, 140)),
          cutout(const Rect.fromLTRB(0, 200, 44, 260)),
        ],
        fallback: EdgeInsets.zero,
      );

      expect(insets.left, 44);
    });

    test('a fold is not a cutout', () {
      // Foldables report a hinge the same way. Nothing here is hidden by it,
      // and treating it as a camera would push the chrome to one half of the
      // screen.
      final insets = DisplayCutouts.resolve(
        size: screen,
        features: [
          const DisplayFeature(
            bounds: Rect.fromLTRB(0, 200, 914, 210),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
        fallback: EdgeInsets.zero,
      );

      expect(insets, EdgeInsets.zero);
    });

    test('a screen that reports no cutout falls back to the platform padding',
        () {
      // Older Android, and every other platform: nothing is enumerated, so the
      // answer is what SafeArea would have used.
      const fallback = EdgeInsets.only(left: 27);
      final insets = DisplayCutouts.resolve(
        size: screen,
        features: const [],
        fallback: fallback,
      );

      expect(insets, fallback);
    });
  });
}
