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
abstract final class VideoFitRendering {
  const VideoFitRendering._();

  static BoxFit resolve(BoxFit chosen, {required bool handheld}) =>
      handheld && chosen == BoxFit.contain ? BoxFit.fitHeight : chosen;
}
