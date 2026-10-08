import 'package:flutter/material.dart';

/// L'image du film, rétrécie dans un coin quand une carte de fin la remplace.
///
/// The video shrinks into a corner while the end-of-season card is up, so the
/// credits stay watchable — the card never hides what is still playing.
/// Scaling instead of resizing keeps the media_kit texture at one size, which
/// avoids a reallocation hitch mid-animation.
class PlayerVideoStage extends StatelessWidget {
  const PlayerVideoStage({super.key, required this.scale, required this.child});

  /// How much of the screen the video keeps: 1 at full size.
  final double scale;
  final Widget child;

  static const Duration _duration = Duration(milliseconds: 320);

  /// Corner radius of the shrunk video, pre-divided by the scale so it looks
  /// like 16pt on screen. Zero at full size, where rounding would just crop.
  double get _cornerRadius => scale < 1 ? 16 / scale : 0;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedScale(
        scale: scale,
        alignment: Alignment.centerLeft,
        duration: _duration,
        curve: Curves.easeOutCubic,
        child: AnimatedPadding(
          padding: EdgeInsets.all(scale < 1 ? 26 : 0),
          duration: _duration,
          curve: Curves.easeOutCubic,
          // Radius and shadow are divided by the scale so they read
          // at their intended size once shrunk, instead of being
          // squashed along with the picture.
          child: AnimatedPhysicalModel(
            duration: _duration,
            curve: Curves.easeOutCubic,
            color: Colors.black,
            shadowColor: Colors.black,
            elevation: scale < 1 ? 24 / scale : 0,
            borderRadius: BorderRadius.circular(_cornerRadius),
            // Only while the card has actually shrunk the picture.
            // At full size the radius is 0, so this clips a
            // rectangle to itself — an antialiased full-screen clip
            // over every decoded frame, for nothing. It is free to
            // skip on a desktop GPU and it is not free on a stick.
            clipBehavior: scale < 1 ? Clip.antiAlias : Clip.none,
            animateColor: false,
            child: SizedBox.expand(child: child),
          ),
        ),
      ),
    );
  }
}
