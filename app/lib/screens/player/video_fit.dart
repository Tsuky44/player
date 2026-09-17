import 'package:flutter/widgets.dart';

/// What the chosen framing is actually drawn as.
///
/// The player offers two: "original" and "adaptive". What the user means by
/// them does not change from one screen to the next — but what "original"
/// should *look* like does.
///
/// On a television, original means letterboxed: a scope film has black bars
/// above and below it, and that is what a scope film looks like. On a phone
/// held sideways it means something else. The screen is 20:9 at best, almost
/// every film is wider than it, and so "original" arrived as bars across the
/// top and bottom of a screen that is already small — the framing paid for in
/// the one place where the picture is scarce. There, original fills the height
/// and lets the sides run past the edge.
///
/// For anything *narrower* than the screen — a 16:9 episode, an old 4:3 film —
/// the two are the same thing, so the setting still reads as one idea rather
/// than two: nothing is cropped that would not have been cropped anyway.
///
/// A tablet is held in a hand too, but it is not a phone. Its screen is 4:3 or
/// close to it, so filling the height of a 16:9 episode threw away a quarter of
/// the picture on each side — "original" looked like a zoom. There the
/// letterbox is back, as on a television.
abstract final class VideoFitRendering {
  const VideoFitRendering._();

  /// Below this shortest side (logical pixels) a handheld screen is a phone.
  static const double tabletShortestSide = 600;

  static BoxFit resolve(
    BoxFit chosen, {
    required bool handheld,
    required Size screen,
  }) {
    final phone = handheld && screen.shortestSide < tabletShortestSide;
    return phone && chosen == BoxFit.contain ? BoxFit.fitHeight : chosen;
  }
}
