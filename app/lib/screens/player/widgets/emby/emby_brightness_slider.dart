import 'package:flutter/material.dart';

import 'emby_chrome_theme.dart';

/// The vertical brightness bar down the right edge of the player, the control
/// every phone video app puts on one of the two.
///
/// It is a bar rather than a [Slider] on purpose: a Slider's thumb is a target
/// to find before the gesture can start, and the hand adjusting the brightness
/// is usually the hand holding the phone.
///
/// **What it listens to is much bigger than what it draws.** The bar itself is
/// 8 px of track, because a thick control over a film is clutter; the area it
/// catches a finger in is a column [_catchWidth] wide and taller than the
/// track at both ends. Nothing in that area is painted, so the picture keeps
/// its room and the finger stops having to aim.
///
/// **And it moves from where the level already is.** Landing on the column
/// changes nothing; the level follows the finger from wherever it was, the way
/// the same gesture works in every other player. Jumping to the touch made the
/// first contact a mistake to correct rather than the start of an adjustment —
/// and it is what made a wide catch area impossible, since every stray touch
/// would have thrown the brightness somewhere.
class EmbyBrightnessSlider extends StatefulWidget {
  /// 0.0 -> 1.0.
  final double value;

  final ValueChanged<double> onChanged;

  /// Signals the start and end of a drag, so the chrome can stay up for the
  /// whole of it instead of fading out from under the finger.
  final ValueChanged<bool>? onDraggingChanged;

  final EmbyChromeMetrics metrics;

  const EmbyBrightnessSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.metrics,
    this.onDraggingChanged,
  });

  @override
  State<EmbyBrightnessSlider> createState() => _EmbyBrightnessSliderState();
}

class _EmbyBrightnessSliderState extends State<EmbyBrightnessSlider> {
  /// The drawn track: thick enough to read its own fill from arm's length — a
  /// hairline over a moving picture shows a level nobody can see — and no
  /// thicker, because it sits over the film.
  static const double _trackWidth = 8;
  static const double _trackWidthDragging = 12;

  /// The visible column the track is centred in.
  static const double _barWidth = 52;

  /// The invisible column the finger is caught in — about a thumb's width of
  /// picture beside the bar. Vertically it takes the whole band the chrome
  /// hands over, which is every pixel between the two bars and not one more:
  /// the buttons below are hit-tested before this and would have taken the
  /// touches anyway, silently, which is exactly how the lower half of the bar
  /// came to stop answering.
  static const double _catchWidth = 116;

  /// Between the track and the icon that labels it.
  static const double _iconGap = 8;

  /// The shortest track worth drawing. Below it the band gets no bar at all —
  /// a short window, the Studio's preview box — rather than a stub nobody
  /// could aim a level with.
  static const double _minTrack = 56;

  /// How far the finger travels before this is an adjustment rather than a
  /// touch. Small — the gesture is unambiguous, nothing else here answers to a
  /// vertical drag — but not zero, or resting a thumb would move the level.
  static const double _slop = 6;

  /// The unfilled part of the track is dark, not a pale white.
  ///
  /// This bar floats over the film with no scrim under it. A white-on-white
  /// track disappears into a bright frame exactly when the user is looking at
  /// it. Dark trough, white fill, and a shadow around both: the level reads on
  /// any frame the film can produce.
  static const Color _trough = Color(0x73000000);

  bool _dragging = false;

  /// Height of the track as laid out. A drag of that length covers the whole
  /// range, so the fill keeps up with the finger one for one.
  double _trackHeight = 1;

  /// Where the finger went down, and the level it found there.
  double? _startY;
  double? _startValue;

  void _setDragging(bool value) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
    widget.onDraggingChanged?.call(value);
  }

  void _onDown(PointerDownEvent event) {
    // Nothing is emitted here on purpose: a touch is not yet an adjustment.
    _startY = event.position.dy;
    _startValue = widget.value.clamp(0.0, 1.0);
  }

  void _onMove(PointerMoveEvent event) {
    final startY = _startY;
    final startValue = _startValue;
    if (startY == null || startValue == null || _trackHeight <= 0) return;

    // Up is brighter, which is the direction the bar itself grows.
    final travelled = startY - event.position.dy;

    if (!_dragging) {
      if (travelled.abs() < _slop) return;
      // Re-anchored on the pixel the drag actually started from, so the level
      // does not jump by the slop the moment it is recognised.
      _startY = event.position.dy;
      _setDragging(true);
      return;
    }

    widget.onChanged(
      (startValue + travelled / _trackHeight).clamp(0.0, 1.0),
    );
  }

  void _onEnd(PointerEvent event) {
    _startY = null;
    _startValue = null;
    _setDragging(false);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final value = widget.value.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The band between the two bars, which the chrome measured rather than
        // guessed at.
        final band =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 260.0;

        // The icon says the bar is a brightness and not a volume, so it is
        // kept wherever both fit. Where they do not — a 1080p phone held
        // sideways leaves barely 80 px between the two bars — the bar keeps
        // the band and the icon goes: a bar without its label still works, and
        // no bar at all does not.
        var withIcon = true;
        var forTrack = band - (_iconGap + m.iconSize);
        if (forTrack < _minTrack) {
          withIcon = false;
          forTrack = band;
        }
        if (forTrack < _minTrack) return const SizedBox.shrink();

        // Most of what is left, not all of it: a track filling the band
        // exactly would sit against the bars at both ends.
        final trackHeight = (forTrack * 0.9).clamp(_minTrack, 150.0);
        _trackHeight = trackHeight;

        // Raw pointers, not a drag recognizer.
        //
        // A recognizer has to win the gesture arena before it is told anything,
        // and it only asks once the finger has travelled the touch slop — about
        // 18 px — in a direction it agrees with. A finger that starts off at a
        // slight angle lost the gesture to the taps over the picture
        // underneath, which is what made the control answer only sometimes.
        //
        // A [Listener] takes part in no arena. Translucent rather than opaque:
        // this area is far wider than the bar, and everything it does not use —
        // a tap, a pinch — has to go on through to the picture as if it were
        // not there.
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onEnd,
          onPointerCancel: _onEnd,
          // Everything the control draws lives inside the catch area, icon
          // included — nothing is laid out after it, so the invisible part
          // cannot push the visible part anywhere.
          child: SizedBox(
            width: _catchWidth,
            height: band,
            child: Column(
              // Centred in the band, and the band is caught whole: above the
              // track and below the icon there is nothing drawn and everything
              // is still listening.
              mainAxisAlignment: MainAxisAlignment.center,
              // The catch column is wider than the bar and hangs off its left
              // side, so it is the right edges that line up.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: _barWidth,
                  height: trackHeight,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOut,
                      width: _dragging ? _trackWidthDragging : _trackWidth,
                      height: trackHeight,
                      // Clipped, so the fill inside keeps the track's own
                      // rounded ends instead of squaring them off.
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: _trough,
                        borderRadius:
                            BorderRadius.circular(_trackWidthDragging),
                        // The bar sits over the picture, not over a scrim, so
                        // without this it vanishes on a bright frame.
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x8A000000),
                            blurRadius: 10,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      // The fill grows from the bottom, matching the direction
                      // of the gesture that produces it.
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          // Never quite nothing: at zero the bar would read as
                          // broken rather than as dark.
                          heightFactor: value.clamp(0.02, 1.0),
                          widthFactor: 1,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: EmbyChromeTheme.progressPlayed,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (withIcon) const SizedBox(height: _iconGap),
                // Says what the bar is for, aligned with it rather than with
                // the catch area around it. Below rather than above, so it
                // stays clear of the finger for the whole of an upward drag.
                if (withIcon)
                  SizedBox(
                    width: _barWidth,
                    child: Center(
                      child: Icon(
                        value < 0.35
                            ? Icons.brightness_low_rounded
                            : value < 0.75
                                ? Icons.brightness_medium_rounded
                                : Icons.brightness_high_rounded,
                        size: m.iconSize,
                        color: EmbyChromeTheme.icon,
                        shadows: const [
                          Shadow(color: Color(0x99000000), blurRadius: 8),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
